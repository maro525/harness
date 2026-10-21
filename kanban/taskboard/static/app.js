"use strict";

/**
 * Board client.
 *
 * Updates arrive as a two-stage signal: an SSE stream carries only a version
 * token, and the payload itself is fetched with If-None-Match so an unchanged
 * board costs a bare 304. SSE over HTTP/1.1 is limited to 6 connections per
 * origin, so if the stream cannot be kept up -- most likely because the board
 * is open in many tabs -- the client degrades to plain polling rather than
 * silently going stale.
 */

const PHASE_LABEL = {
  planning: "Planning",
  implementing: "Implementing",
  review: "Review",
  deploy: "Deploy",
  done: "Done",
  unknown: "Unknown",
};

/** Cards rendered per column before a "show more" button takes over. */
const PAGE_SIZE = 40;
/** Fallback poll interval once SSE is judged unavailable. */
const POLL_MS = 3000;
/** Consecutive SSE failures tolerated before switching to polling. */
const SSE_FAIL_LIMIT = 3;
/** How often elapsed / remaining times on waiting questions are redrawn. */
const CLOCK_MS = 30000;
/**
 * Only Linear comment URLs become links. The ask logs are untrusted data, and
 * escaping alone would still let a `javascript:` URL through as an href.
 */
const LINEAR_URL = /^https:\/\/linear\.app\//;

const el = {
  board: document.getElementById("board"),
  empty: document.getElementById("empty"),
  q: document.getElementById("q"),
  project: document.getElementById("project"),
  tier: document.getElementById("tier"),
  staleOnly: document.getElementById("staleOnly"),
  askOnly: document.getElementById("askOnly"),
  status: document.getElementById("status"),
};

let data = null;
let etag = null;
let shown = Object.create(null);
let sseFailures = 0;
let pollTimer = null;

const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));

function setStatus(text, kind) {
  el.status.textContent = text;
  el.status.className = "status" + (kind ? " " + kind : "");
}

/* -- data ------------------------------------------------------------- */

async function fetchBoard() {
  const headers = etag ? { "If-None-Match": etag } : {};
  const res = await fetch("/api/board", { headers, cache: "no-store" });
  if (res.status === 304) return false;
  if (!res.ok) throw new Error("HTTP " + res.status);
  etag = res.headers.get("ETag");
  data = await res.json();
  return true;
}

async function refresh() {
  try {
    if (await fetchBoard()) render();
    if (!pollTimer) setStatus(liveLabel(), "live");
  } catch (err) {
    setStatus("disconnected", "down");
  }
}

function liveLabel() {
  if (!data) return "…";
  const stale = data.staleCount ? ` · ${data.staleCount} stale` : "";
  const waiting = data.waitingCount ? ` · ${data.waitingCount} waiting` : "";
  return `${data.cards.length} tasks · ${data.scanMs} ms${stale}${waiting}`;
}

/* -- filtering -------------------------------------------------------- */

function currentFilters() {
  return {
    q: el.q.value.trim().toLowerCase(),
    project: el.project.value,
    tier: el.tier.value,
    staleOnly: el.staleOnly.checked,
    askOnly: el.askOnly.checked,
  };
}

function matches(card, f) {
  if (f.project && card.project !== f.project) return false;
  if (f.tier && card.tier !== f.tier) return false;
  if (f.staleOnly && !card.staleStatus) return false;
  if (f.askOnly && !card.question) return false;
  if (!f.q) return true;
  const summary = (card.question && card.question.summary) || "";
  const hay = `${card.id} ${card.title} ${card.branch || ""} ${card.project} ${card.statusRaw || ""} ${summary}`;
  return hay.toLowerCase().includes(f.q);
}

/* -- waiting questions ------------------------------------------------ */

/** Milliseconds since the epoch, or NaN for a missing / unparsable time. */
const timeOf = (iso) => (iso ? Date.parse(iso) : NaN);

function formatSpan(ms) {
  const minutes = Math.max(0, Math.floor(ms / 60000));
  if (minutes < 1) return "<1m";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

function elapsedText(postedAt, now) {
  const t = timeOf(postedAt);
  return Number.isNaN(t) ? "posted ?" : `asked ${formatSpan(now - t)} ago`;
}

function deadlineText(deadline, now) {
  const t = timeOf(deadline);
  if (Number.isNaN(t)) return "no deadline";
  return t > now ? `${formatSpan(t - now)} left` : `overdue ${formatSpan(now - t)}`;
}

/** A question still marked waiting after its deadline: shown, never hidden. */
function isOverdue(question, now) {
  const t = timeOf(question && question.deadline);
  return !Number.isNaN(t) && t <= now;
}

function questionHtml(q, now) {
  const link = q.commentUrl && LINEAR_URL.test(q.commentUrl)
    ? `<a href="${escapeHtml(q.commentUrl)}" target="_blank" rel="noreferrer">Linear</a>`
    : "";
  const tip = [
    `phase: ${q.phase}${q.round > 1 ? ` (round ${q.round})` : ""}`,
    q.postedAt ? `posted: ${q.postedAt}` : null,
    q.deadline ? `deadline: ${q.deadline}` : null,
    q.path,
  ]
    .filter(Boolean)
    .join("\n");
  return (
    `<div class="q" title="${escapeHtml(tip)}">` +
    `<div class="qs">${escapeHtml(q.summary || "(question text not found)")}</div>` +
    `<div class="qm">` +
    `<span data-since="${escapeHtml(q.postedAt || "")}">${escapeHtml(elapsedText(q.postedAt, now))}</span>` +
    `<span data-deadline="${escapeHtml(q.deadline || "")}">${escapeHtml(deadlineText(q.deadline, now))}</span>` +
    link +
    `</div>` +
    `</div>`
  );
}

/** Redraw elapsed / remaining times in place; no refetch, no re-render. */
function tickClocks() {
  if (document.hidden) return;
  const now = Date.now();
  for (const node of el.board.querySelectorAll("[data-since]")) {
    node.textContent = elapsedText(node.dataset.since, now);
  }
  for (const node of el.board.querySelectorAll("[data-deadline]")) {
    node.textContent = deadlineText(node.dataset.deadline, now);
    const card = node.closest(".card");
    const t = timeOf(node.dataset.deadline);
    if (card) card.classList.toggle("overdue", !Number.isNaN(t) && t <= now);
  }
}

/* -- rendering -------------------------------------------------------- */

function cardHtml(card) {
  const now = Date.now();
  const q = card.question;
  const classes = ["card"];
  if (q) classes.push("asking");
  if (q && isOverdue(q, now)) classes.push("overdue");
  if (card.staleStatus) classes.push("stale");
  if (card.parseError) classes.push("err");

  const tags = [];
  if (q) tags.push(`<span class="tag ask">waiting</span>`);
  tags.push(`<span class="tag id">${escapeHtml(card.id)}</span>`);
  if (card.tier) tags.push(`<span class="tag tier">${escapeHtml(card.tier)}</span>`);
  tags.push(`<span class="tag">${escapeHtml(card.project)}</span>`);
  if (card.staleStatus) {
    tags.push(
      `<span class="tag stale" title="status: ${escapeHtml(card.statusRaw)} — but the file shows ${escapeHtml(card.evidencePhase)}">stale</span>`
    );
  }
  // Escaping alone would still emit a `javascript:` URL verbatim. The server's
  // PR regex only matches http(s) today, so this is defence in depth against
  // that regex being widened or another URL field being added later.
  if (card.prUrl && /^https?:\/\//i.test(card.prUrl)) {
    tags.push(
      `<span class="tag pr"><a href="${escapeHtml(card.prUrl)}" target="_blank" rel="noreferrer">PR</a></span>`
    );
  }
  if (card.parseError) tags.push(`<span class="tag">parse error</span>`);

  const tip = [
    card.path,
    card.statusRaw ? `status: ${card.statusRaw}` : "status: (none)",
    card.evidencePhase ? `evidence: ${card.evidencePhase}` : "evidence: (none)",
    card.branch ? `branch: ${card.branch}` : null,
    card.parseError,
  ]
    .filter(Boolean)
    .join("\n");

  return (
    `<div class="${classes.join(" ")}" title="${escapeHtml(tip)}">` +
    `<div class="t">${escapeHtml(card.title)}</div>` +
    `<div class="m">${tags.join("")}</div>` +
    (q ? questionHtml(q, now) : "") +
    `</div>`
  );
}

function render() {
  if (!data) return;
  syncSelect(el.project, data.projects);
  syncSelect(el.tier, data.tiers);

  const f = currentFilters();
  const buckets = Object.create(null);
  for (const name of data.columns) buckets[name] = [];
  let total = 0;
  for (const card of data.cards) {
    if (!matches(card, f)) continue;
    (buckets[card.phase] || (buckets[card.phase] = [])).push(card);
    total++;
  }
  // Waiting questions first within each column; the sort is stable, so the
  // server's most-recently-modified order holds inside each group.
  for (const name of Object.keys(buckets)) {
    buckets[name].sort((a, b) => Number(!!b.question) - Number(!!a.question));
  }

  const html = [];
  for (const name of data.columns) {
    const list = buckets[name] || [];
    // Keep `unknown` out of the way unless it actually has something in it.
    if (name === "unknown" && list.length === 0) continue;
    const limit = shown[name] || PAGE_SIZE;
    const slice = list.slice(0, limit);
    html.push(
      `<section class="column" data-col="${name}">` +
        `<h2>${PHASE_LABEL[name] || name}<span class="n">${list.length}</span></h2>` +
        slice.map(cardHtml).join("") +
        (list.length > slice.length
          ? `<button class="more" data-col="${name}">show ${list.length - slice.length} more</button>`
          : "") +
      `</section>`
    );
  }

  // One write: building the whole board as a string and assigning once is
  // markedly faster than creating ~1,400 nodes individually.
  el.board.innerHTML = html.join("");
  el.empty.hidden = total > 0;
  if (!pollTimer) setStatus(liveLabel(), "live");
}

function syncSelect(select, values) {
  const wanted = JSON.stringify(values);
  if (select.dataset.values === wanted) return;
  select.dataset.values = wanted;
  const current = select.value;
  const first = select.options[0].textContent;
  select.innerHTML =
    `<option value="">${first}</option>` +
    values.map((v) => `<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join("");
  if (values.includes(current)) select.value = current;
}

/* -- live updates ----------------------------------------------------- */

function startPolling() {
  if (pollTimer) return;
  setStatus("polling", "poll");
  pollTimer = setInterval(refresh, POLL_MS);
}

function connect() {
  let source;
  try {
    source = new EventSource("/events");
  } catch (err) {
    startPolling();
    return;
  }
  source.addEventListener("open", () => {
    sseFailures = 0;
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    setStatus(liveLabel(), "live");
  });
  source.addEventListener("change", refresh);
  source.addEventListener("error", () => {
    sseFailures++;
    setStatus("reconnecting…", "down");
    if (sseFailures >= SSE_FAIL_LIMIT) {
      // Most likely the 6-connections-per-origin cap: give up on the stream.
      source.close();
      startPolling();
    }
  });
}

/* -- wiring ----------------------------------------------------------- */

let debounce;
for (const node of [el.q, el.project, el.tier, el.staleOnly, el.askOnly]) {
  node.addEventListener("input", () => {
    clearTimeout(debounce);
    debounce = setTimeout(() => {
      shown = Object.create(null);
      render();
    }, 80);
  });
}

el.board.addEventListener("click", (event) => {
  const button = event.target.closest("button.more");
  if (!button) return;
  const name = button.dataset.col;
  shown[name] = (shown[name] || PAGE_SIZE) + PAGE_SIZE;
  render();
});

setInterval(tickClocks, CLOCK_MS);
document.addEventListener("visibilitychange", tickClocks);

refresh().then(connect);
