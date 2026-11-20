"use strict";

/**
 * Harness views: Agents (boss → child tree), Timeline, and the detail panel.
 *
 * Only active when the server was started with --harness: if /api/activity
 * answers 404 this file does nothing and the page stays the plain board.
 *
 * Every string shown here comes from files other agents wrote (inbox
 * reports, record fields, task titles), so it is all untrusted: markup is
 * built with escapeHtml() and nothing is ever turned into a link except
 * internal `#/...` selections.
 *
 * Routing lives in the hash: `#/board`, `#/agents`, `#/timeline`, each with
 * an optional `?sel=agent:NAME` or `?sel=task:PATH` for the detail panel.
 */
(() => {
  const TB = window.TaskBoard;
  if (!TB) return;
  const esc = TB.escapeHtml;

  const VIEWS = ["board", "agents", "timeline"];
  /** Ended agents older than this are hidden unless the toggle says otherwise. */
  const ENDED_WINDOW_MS = 24 * 3600 * 1000;
  /** How often relative times are redrawn. */
  const CLOCK_MS = 30000;
  /** Inbox kinds that need someone to act. Mirrors ATTENTION_KINDS in activity.py. */
  const ATTENTION = new Set(["question", "blocked", "stalled"]);
  const LIVE = new Set(["idle", "working", "done"]);
  /** Events listed for one agent in the detail panel. */
  const DETAIL_EVENTS = 30;
  const NO_BOSS = "(no boss / unknown)";

  const el = {
    tabs: document.getElementById("tabs"),
    badge: document.getElementById("unreadBadge"),
    herdr: document.getElementById("herdrStatus"),
    agents: document.getElementById("agents"),
    timeline: document.getElementById("timeline"),
    board: document.getElementById("board"),
    empty: document.getElementById("empty"),
    detail: document.getElementById("detail"),
    detailBody: document.getElementById("detailBody"),
    detailClose: document.getElementById("detailClose"),
    agentQ: document.getElementById("agentQ"),
    agentRepo: document.getElementById("agentRepo"),
    liveOnly: document.getElementById("liveOnly"),
    allEnded: document.getElementById("allEnded"),
    timeQ: document.getElementById("timeQ"),
    timeBoss: document.getElementById("timeBoss"),
    timeRepo: document.getElementById("timeRepo"),
    timeKinds: document.getElementById("timeKinds"),
  };

  let act = null;
  let etag = null;
  const collapsed = new Set();

  /* -- data ----------------------------------------------------------- */

  /** Returns true on new data, false on 304; null when the harness is off. */
  async function fetchActivity() {
    const headers = etag ? { "If-None-Match": etag } : {};
    const res = await fetch("/api/activity", { headers, cache: "no-store" });
    if (res.status === 404) return null;
    if (res.status === 304) return false;
    if (!res.ok) throw new Error("HTTP " + res.status);
    etag = res.headers.get("ETag");
    act = await res.json();
    return true;
  }

  async function refreshActivity() {
    try {
      if (await fetchActivity()) renderAll();
    } catch (err) {
      el.herdr.hidden = false;
      el.herdr.textContent = "activity: disconnected";
      el.herdr.className = "status down";
    }
  }

  const agentsByName = () => new Map((act ? act.agents : []).map((a) => [a.name, a]));
  const cardsByPath = () => new Map(((TB.data && TB.data.cards) || []).map((c) => [c.path, c]));

  /** herdr-agent.sh `safe_name`: an agent's inbox directory name. */
  const safeName = (name) => {
    const s = String(name).replace(/[^A-Za-z0-9._-]/g, "_");
    return s.startsWith(".") ? "_" + s : s;
  };

  /* -- routing -------------------------------------------------------- */

  function parseHash() {
    const raw = location.hash.replace(/^#\/?/, "");
    const [view, query] = raw.split("?");
    const params = new URLSearchParams(query || "");
    return { view: VIEWS.includes(view) ? view : "board", sel: params.get("sel") };
  }

  function go(view, sel) {
    const hash = "#/" + view + (sel ? "?sel=" + encodeURIComponent(sel) : "");
    if (location.hash !== hash) location.hash = hash;
    else applyRoute();
  }

  function applyRoute() {
    const { view, sel } = parseHash();
    for (const node of document.querySelectorAll(".view")) node.hidden = node.dataset.view !== view;
    for (const node of document.querySelectorAll(".controls")) node.hidden = node.dataset.for !== view;
    for (const link of el.tabs.querySelectorAll("a")) {
      link.classList.toggle("active", link.dataset.view === view);
    }
    if (view !== "board") el.empty.hidden = true;
    else TB.render();
    renderView(view);
    renderDetail(sel);
  }

  /* -- time ----------------------------------------------------------- */

  function agoText(iso, now) {
    const t = TB.timeOf(iso);
    return Number.isNaN(t) ? "" : TB.formatSpan(now - t) + " ago";
  }

  function clockText(iso) {
    const t = TB.timeOf(iso);
    if (Number.isNaN(t)) return iso || "";
    const d = new Date(t);
    const pad = (n) => String(n).padStart(2, "0");
    return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  const ago = (iso, now) =>
    iso ? `<span class="ago" data-ago="${esc(iso)}">${esc(agoText(iso, now))}</span>` : "";

  /** Lock expiry is judged here (updated + ttl vs now), never on the server. */
  function expiryText(lock, now) {
    if (lock.updatedEpoch == null || lock.ttlSeconds == null) return { text: "no ttl", expired: false };
    const left = (lock.updatedEpoch + lock.ttlSeconds) * 1000 - now;
    return left > 0
      ? { text: `expires in ${TB.formatSpan(left)}`, expired: false }
      : { text: `expired ${TB.formatSpan(-left)} ago`, expired: true };
  }

  function tick() {
    if (document.hidden || !act) return;
    const now = Date.now();
    for (const node of document.querySelectorAll("[data-ago]")) {
      node.textContent = agoText(node.dataset.ago, now);
    }
    for (const node of document.querySelectorAll("[data-lock]")) {
      const lock = act.locks.find((l) => l.key === node.dataset.lock);
      if (!lock) continue;
      const { text, expired } = expiryText(lock, now);
      node.textContent = text;
      node.classList.toggle("expired", expired);
    }
  }

  /* -- shared pieces -------------------------------------------------- */

  const selLink = (sel, label, cls = "") =>
    `<a href="#" class="sel ${cls}" data-sel="${esc(sel)}">${esc(label)}</a>`;

  function badges(counts, title) {
    return Object.entries(counts || {})
      .sort(([a], [b]) => a.localeCompare(b))
      .map(
        ([kind, n]) =>
          `<span class="badge k-${esc(kind)}${ATTENTION.has(kind) ? " attention" : ""}" ` +
          `title="${esc(`${title}: ${n} ${kind}`)}">${esc(kind)} ${n}</span>`
      )
      .join("");
  }

  function syncSelect(select, values) {
    const wanted = JSON.stringify(values);
    if (select.dataset.values === wanted) return;
    select.dataset.values = wanted;
    const current = select.value;
    const first = select.options[0].textContent;
    select.innerHTML =
      `<option value="">${esc(first)}</option>` +
      values.map((v) => `<option value="${esc(v)}">${esc(v)}</option>`).join("");
    if (values.includes(current)) select.value = current;
  }

  /* -- header --------------------------------------------------------- */

  function renderHeader() {
    const c = act.counts;
    el.badge.hidden = !c.unread;
    el.badge.textContent = c.attention ? `${c.unread} · ${c.attention}!` : String(c.unread);
    el.badge.classList.toggle("attention", c.attention > 0);
    el.badge.title = `${c.unread} unread inbox item(s), ${c.attention} need attention`;

    el.herdr.hidden = false;
    if (act.herdr.ok) {
      el.herdr.textContent = `herdr · ${c.live} live`;
      el.herdr.className = "status live";
      el.herdr.title = "herdr agent list";
    } else {
      el.herdr.textContent = `herdr: unavailable (${act.herdr.error || "?"})`;
      el.herdr.className = "status down";
      el.herdr.title = "Agents are drawn from the records only; liveness is unknown.";
    }
    const broken = Object.entries(act.sources).filter(([, s]) => !s.ok);
    if (broken.length) {
      el.herdr.title += "\n" + broken.map(([n, s]) => `${n}: ${s.error}`).join("\n");
    }
  }

  /* -- agents --------------------------------------------------------- */

  function agentFilters() {
    return {
      q: el.agentQ.value.trim().toLowerCase(),
      repo: el.agentRepo.value,
      liveOnly: el.liveOnly.checked,
      allEnded: el.allEnded.checked,
    };
  }

  function agentVisible(agent, f, now) {
    if (f.liveOnly && !LIVE.has(agent.status)) return false;
    if (!f.allEnded && agent.status === "ended") {
      const t = TB.timeOf(agent.created);
      if (!Number.isNaN(t) && now - t > ENDED_WINDOW_MS) return false;
    }
    if (f.repo && agent.repo !== f.repo) return false;
    if (!f.q) return true;
    const hay = `${agent.name} ${agent.kind || ""} ${agent.model || ""} ${agent.repo || ""} ${agent.parent || ""}`;
    return hay.toLowerCase().includes(f.q);
  }

  function agentRow(agent, depth, hasChildren, now, selected) {
    const open = !collapsed.has(agent.name);
    const lockCount = agent.lockKeys.length;
    const inboxTo = Object.values(agent.unreadTo || {}).reduce((a, b) => a + b, 0);
    return (
      `<div class="arow st-${esc(agent.status)}${selected ? " selected" : ""}" ` +
      `data-sel="agent:${esc(agent.name)}" style="--depth:${depth}">` +
      (hasChildren
        ? `<button class="twisty" data-toggle="${esc(agent.name)}" aria-expanded="${open}">${open ? "▾" : "▸"}</button>`
        : `<span class="twisty"></span>`) +
      `<span class="pill st-${esc(agent.status)}">${esc(agent.status)}</span>` +
      `<span class="name">${esc(agent.name)}</span>` +
      (agent.kind ? `<span class="tag">${esc(agent.kind)}</span>` : "") +
      (agent.model ? `<span class="tag model">${esc(agent.model)}</span>` : "") +
      (agent.repo ? `<span class="repo">${esc(agent.repo)}</span>` : "") +
      (agent.recordStale ? `<span class="tag stale" title="record belongs to an earlier session">old record</span>` : "") +
      badges(agent.unreadFrom, "unread from this agent") +
      (inboxTo ? `<span class="badge inbox" title="unread in this agent's inbox">inbox ${inboxTo}</span>` : "") +
      (lockCount ? `<span class="badge b-lock" title="locks held">lock ${lockCount}</span>` : "") +
      `<span class="spacer"></span>` +
      ago(agent.created, now) +
      `</div>`
    );
  }

  function renderAgents() {
    const f = agentFilters();
    const now = Date.now();
    const sel = parseHash().sel;
    const byName = agentsByName();
    syncSelect(el.agentRepo, [...new Set(act.agents.map((a) => a.repo).filter(Boolean))].sort());

    const children = new Map();
    const roots = [];
    const orphans = [];
    for (const agent of act.agents) {
      if (agent.parent && agent.parent !== agent.name) {
        if (!children.has(agent.parent)) children.set(agent.parent, []);
        children.get(agent.parent).push(agent);
      }
    }
    for (const agent of act.agents) {
      if (agent.parent) continue; // drawn under its boss (or the boss's placeholder)
      if (children.has(agent.name)) roots.push(agent);
      else orphans.push(agent);
    }
    // Bosses that have no record and no live session: a placeholder node.
    const phantoms = [...children.keys()].filter((name) => !byName.has(name)).sort();

    // Visibility: a node is drawn when it or any descendant passes the filter.
    const shownCache = new Map();
    const shown = (agent, trail = new Set()) => {
      if (shownCache.has(agent.name)) return shownCache.get(agent.name);
      if (trail.has(agent.name)) return false; // a cycle in the records
      trail.add(agent.name);
      const result =
        agentVisible(agent, f, now) || (children.get(agent.name) || []).some((c) => shown(c, trail));
      shownCache.set(agent.name, result);
      return result;
    };

    const html = [];
    const drawn = new Set();
    const draw = (agent, depth) => {
      if (drawn.has(agent.name) || !shown(agent)) return;
      drawn.add(agent.name);
      const kids = (children.get(agent.name) || []).filter((c) => shown(c));
      html.push(agentRow(agent, depth, kids.length > 0, now, sel === `agent:${agent.name}`));
      if (collapsed.has(agent.name)) return;
      for (const kid of kids) draw(kid, depth + 1);
    };
    const group = (title, members, toggleKey) => {
      const visible = members.filter((m) => shown(m));
      if (!visible.length) return;
      const open = !collapsed.has(toggleKey);
      html.push(
        `<div class="agroup">` +
          `<button class="twisty" data-toggle="${esc(toggleKey)}" aria-expanded="${open}">${open ? "▾" : "▸"}</button>` +
          `<span class="name">${esc(title)}</span><span class="n">${visible.length}</span>` +
          `</div>`
      );
      if (open) for (const m of visible) draw(m, 1);
    };

    for (const root of roots) draw(root, 0);
    for (const name of phantoms) group(`${name} (no record)`, children.get(name), `boss:${name}`);
    group(NO_BOSS, orphans, "boss:");

    el.agents.innerHTML = html.length
      ? html.join("")
      : `<div class="empty"><p>No agents match the current filters.</p></div>`;
  }

  /* -- timeline ------------------------------------------------------- */

  function category(event) {
    if (event.kind === "inbox") return ATTENTION.has(event.sub) ? "attention" : "report";
    if (event.kind === "worktree") return "delegate";
    return event.kind;
  }

  function renderTimeline() {
    const now = Date.now();
    const sel = parseHash().sel;
    const kinds = new Set(
      [...el.timeKinds.querySelectorAll("input:checked")].map((input) => input.value)
    );
    syncSelect(el.timeBoss, [...new Set(act.timeline.map((e) => e.boss).filter(Boolean))].sort());
    syncSelect(el.timeRepo, [...new Set(act.timeline.map((e) => e.repo).filter(Boolean))].sort());
    const boss = el.timeBoss.value;
    const repo = el.timeRepo.value;
    const q = el.timeQ.value.trim().toLowerCase();

    const rows = [];
    for (const e of act.timeline) {
      const cat = category(e);
      if (!kinds.has(cat)) continue;
      if (boss && e.boss !== boss) continue;
      if (repo && e.repo !== repo) continue;
      if (q && !`${e.agent || ""} ${e.boss || ""} ${e.repo || ""} ${e.text} ${e.sub || ""}`.toLowerCase().includes(q)) continue;
      rows.push(
        `<div class="trow c-${esc(cat)}${e.select && e.select === sel ? " selected" : ""}"` +
          (e.select ? ` data-sel="${esc(e.select)}"` : "") +
          ` title="${esc(e.at)}">` +
          `<span class="time">${esc(clockText(e.at))}</span>` +
          `<span class="pill c-${esc(cat)}">${esc(e.kind)}${e.sub ? " · " + esc(e.sub) : ""}</span>` +
          `<span class="who">${esc(e.agent || "")}${e.boss ? ` <span class="muted">← ${esc(e.boss)}</span>` : ""}</span>` +
          (e.repo ? `<span class="repo">${esc(e.repo)}</span>` : "") +
          `<span class="text">${esc(e.text)}</span>` +
          ago(e.at, now) +
          `</div>`
      );
    }
    el.timeline.innerHTML = rows.length
      ? rows.join("")
      : `<div class="empty"><p>No events in the last 24 h match the current filters.</p></div>`;
  }

  /* -- detail panel --------------------------------------------------- */

  function fieldTable(entries) {
    const rows = entries
      .filter(([, v]) => v !== null && v !== undefined && v !== "")
      .map(([k, v]) => `<tr><th>${esc(k)}</th><td>${v}</td></tr>`);
    return rows.length ? `<table class="fields">${rows.join("")}</table>` : "";
  }

  function inboxList(items) {
    if (!items.length) return `<p class="muted">none</p>`;
    const now = Date.now();
    return items
      .map(
        (item) =>
          `<div class="msg k-${esc(item.kind)}${item.read ? " read" : ""}" title="${esc(item.path)}">` +
          `<div class="mh"><span class="badge k-${esc(item.kind)}${ATTENTION.has(item.kind) ? " attention" : ""}">${esc(item.kind)}</span>` +
          `<span>${esc(item.from)} → ${esc(item.to || item.bossDir)}</span>` +
          `<span class="time">${esc(clockText(item.at))}</span>${ago(item.at, now)}</div>` +
          `<div class="mp">${esc(item.preview)}</div>` +
          `</div>`
      )
      .join("");
  }

  function lockList(locks) {
    if (!locks.length) return `<p class="muted">none</p>`;
    const now = Date.now();
    return locks
      .map((lock) => {
        const { text, expired } = expiryText(lock, now);
        return (
          `<div class="lock" title="${esc(lock.path)}">` +
          `<div><b>${esc(lock.key)}</b> <span class="exp${expired ? " expired" : ""}" data-lock="${esc(lock.key)}">${esc(text)}</span></div>` +
          `<div class="muted">${esc(lock.runner || "?")} · owner ${esc(lock.owner || "?")} · pid ${esc(lock.pid || "?")} · since ${esc(clockText(lock.started))}</div>` +
          (lock.taskFile ? `<div class="muted">${selLink(`task:${lock.taskFile}`, lock.taskFile)}</div>` : "") +
          `</div>`
        );
      })
      .join("");
  }

  function taskCards(paths) {
    const cards = cardsByPath();
    const found = paths.map((p) => cards.get(p)).filter(Boolean);
    return found.length ? found.map(TB.cardHtml).join("") : `<p class="muted">none</p>`;
  }

  function section(title, body) {
    return `<section><h3>${esc(title)}</h3>${body}</section>`;
  }

  function agentDetail(name) {
    const byName = agentsByName();
    const agent = byName.get(name);
    if (!agent) return `<h2>${esc(name)}</h2><p class="muted">No such agent in the current records.</p>`;
    const now = Date.now();
    const kids = act.agents.filter((a) => a.parent === name);
    const inboxDir = safeName(name);
    const toMe = act.inbox.filter((i) => i.bossDir === inboxDir);
    const fromMe = act.inbox.filter((i) => i.from === name && i.bossDir !== inboxDir);
    const locks = act.locks.filter((l) => agent.lockKeys.includes(l.key));
    const worktrees = act.worktrees.filter((w) => agent.worktreePaths.includes(w.path));
    const events = act.timeline.filter((e) => e.agent === name).slice(0, DETAIL_EVENTS);
    const record = agent.record;

    const head =
      `<h2><span class="pill st-${esc(agent.status)}">${esc(agent.status)}</span> ${esc(agent.name)}</h2>` +
      (agent.recordStale
        ? `<p class="warn">The record file belongs to an earlier session with the same name (pane ${esc(record && record.pane)}); live data is shown.</p>`
        : "") +
      fieldTable([
        ["kind", esc(agent.kind)],
        ["model", esc(agent.model)],
        ["boss", agent.parent ? selLink(`agent:${agent.parent}`, agent.parent) + ` <span class="muted">(${esc(agent.parentVia)})</span>` : ""],
        ["pane", esc(agent.pane)],
        ["cwd", esc(agent.cwd)],
        ["created", agent.created ? `${esc(agent.created)} ${ago(agent.created, now)}` : ""],
        ["children", kids.map((k) => selLink(`agent:${k.name}`, k.name)).join(", ")],
      ]);

    const recordBody = record
      ? fieldTable([["file", esc(record.path)], ...Object.entries(record.fields).map(([k, v]) => [k, esc(v)])])
      : `<p class="muted">No record file (a session not started by herdr-agent.sh).</p>`;

    return (
      head +
      section("Tasks", taskCards(agent.taskPaths)) +
      section(`Inbox of ${name} (${toMe.filter((i) => !i.read).length} unread)`, inboxList(toMe)) +
      section(`Sent by ${name}`, inboxList(fromMe)) +
      section("Locks held", lockList(locks)) +
      section(
        "Worktrees",
        worktrees.length
          ? worktrees.map((w) => `<div title="${esc(w.recordPath)}">${esc(w.branch || "?")}<div class="muted">${esc(w.path)}</div></div>`).join("")
          : `<p class="muted">none</p>`
      ) +
      section(
        "Recent events",
        events.length
          ? events.map((e) => `<div class="ev"><span class="time">${esc(clockText(e.at))}</span> <span class="pill c-${esc(category(e))}">${esc(e.kind)}${e.sub ? " · " + esc(e.sub) : ""}</span> ${esc(e.text)}</div>`).join("")
          : `<p class="muted">none in the last 24 h</p>`
      ) +
      section("Record", recordBody)
    );
  }

  function taskDetail(path) {
    const card = cardsByPath().get(path);
    const agents = act.agents.filter((a) => a.taskPaths.includes(path));
    const locks = act.locks.filter((l) => l.taskFile === path);
    const events = act.timeline.filter((e) => e.select === `task:${path}`);
    return (
      `<h2>${esc(card ? card.id : path)}</h2>` +
      (card ? TB.cardHtml(card) : `<p class="muted">Task file not on the board: ${esc(path)}</p>`) +
      section(
        "Agents",
        agents.length
          ? agents.map((a) => `<div>${selLink(`agent:${a.name}`, a.name)} <span class="pill st-${esc(a.status)}">${esc(a.status)}</span> ${esc(a.model || "")}</div>`).join("")
          : `<p class="muted">none linked (by worktree branch or lock)</p>`
      ) +
      section("Locks", lockList(locks)) +
      section(
        "Phases (last 24 h)",
        events.length
          ? events.map((e) => `<div class="ev"><span class="time">${esc(clockText(e.at))}</span> ${esc(e.text)}</div>`).join("")
          : `<p class="muted">none</p>`
      )
    );
  }

  function renderDetail(sel) {
    if (!sel || !act) {
      el.detail.hidden = true;
      return;
    }
    el.detail.hidden = false;
    if (sel.startsWith("agent:")) el.detailBody.innerHTML = agentDetail(sel.slice(6));
    else if (sel.startsWith("task:")) el.detailBody.innerHTML = taskDetail(sel.slice(5));
    else el.detail.hidden = true;
  }

  /* -- orchestration -------------------------------------------------- */

  function renderView(view) {
    if (!act) return;
    if (view === "agents") renderAgents();
    else if (view === "timeline") renderTimeline();
  }

  function renderAll() {
    renderHeader();
    const { view, sel } = parseHash();
    renderView(view);
    renderDetail(sel);
  }

  function onClick(event) {
    if (event.target.closest("a[href]:not(.sel)")) return; // PR / Linear links
    const toggle = event.target.closest("[data-toggle]");
    if (toggle) {
      const key = toggle.dataset.toggle;
      if (collapsed.has(key)) collapsed.delete(key);
      else collapsed.add(key);
      renderView(parseHash().view);
      return;
    }
    const target = event.target.closest("[data-sel], .card[data-path]");
    if (!target) return;
    event.preventDefault();
    const sel = target.dataset.sel || `task:${target.dataset.path}`;
    go(parseHash().view, sel);
  }

  async function start() {
    let first;
    try {
      first = await fetchActivity();
    } catch (err) {
      first = false;
    }
    if (first === null) return; // --harness is off: the plain board
    el.tabs.hidden = false;
    document.body.classList.add("harness");
    TB.hooks.activity = refreshActivity;
    TB.hooks.rendered = () => {
      const { view, sel } = parseHash();
      if (view === "board" || (sel && sel.startsWith("task:"))) renderDetail(sel);
    };
    for (const root of [el.agents, el.timeline, el.board, el.detailBody]) {
      root.addEventListener("click", onClick);
    }
    el.detailClose.addEventListener("click", () => go(parseHash().view, null));
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && parseHash().sel) go(parseHash().view, null);
    });
    for (const node of [el.agentQ, el.agentRepo, el.liveOnly, el.allEnded]) {
      node.addEventListener("input", () => act && renderAgents());
    }
    for (const node of [el.timeQ, el.timeBoss, el.timeRepo, el.timeKinds]) {
      node.addEventListener("input", () => act && renderTimeline());
    }
    window.addEventListener("hashchange", applyRoute);
    setInterval(tick, CLOCK_MS);
    document.addEventListener("visibilitychange", tick);
    if (act) renderHeader();
    applyRoute();
  }

  start();
})();
