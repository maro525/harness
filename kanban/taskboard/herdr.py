"""Live session list from `herdr agent list`, polled on its own thread.

The CLI is the only source that says which sessions are alive right now; the
record files outlive their sessions until `herdr-cleanup.sh` removes them. It
is also the one source that can hang (a stuck Herdr server) or be missing
entirely, so:

- each call runs with a hard timeout in its own process group, and the whole
  group is killed on timeout so no helper is left behind;
- one loop calls it serially, so a slow call never stacks up behind another;
- a failed call does not keep the previous list as "current": liveness becomes
  unknown, and the reason is reported.
"""

from __future__ import annotations

import contextlib
import json
import os
import signal
import subprocess
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass

DEFAULT_COMMAND: tuple[str, ...] = ("herdr", "agent", "list")
DEFAULT_TIMEOUT = 2.0
DEFAULT_POLL_SECONDS = 3.0
#: Longest error message kept from a failing call.
_ERROR_CHARS = 200


@dataclass(frozen=True, slots=True)
class LiveAgent:
    """One entry of `herdr agent list`. Herdr names are unique per server."""

    name: str
    kind: str | None
    status: str | None
    cwd: str | None
    pane_id: str | None
    tab_id: str | None
    workspace_id: str | None
    title: str | None

    def to_json(self) -> dict[str, object]:
        return {
            "name": self.name,
            "kind": self.kind,
            "status": self.status,
            "cwd": self.cwd,
            "paneId": self.pane_id,
            "tabId": self.tab_id,
            "workspaceId": self.workspace_id,
            "title": self.title,
        }


@dataclass(frozen=True, slots=True)
class LiveResult:
    """Outcome of one call. `ok=False` means liveness is unknown, not "none"."""

    ok: bool
    agents: tuple[LiveAgent, ...] = ()
    error: str | None = None


DISABLED = LiveResult(ok=False, error="disabled (--no-herdr)")
PENDING = LiveResult(ok=False, error="not polled yet")


def _text(value: object) -> str | None:
    if value is None or isinstance(value, (dict, list)):
        return None
    return str(value) or None


def parse_agent_list(text: str) -> LiveResult:
    """Parse the CLI's JSON; anything unexpected is a failed result."""
    try:
        document = json.loads(text)
    except ValueError:
        return LiveResult(ok=False, error="invalid JSON from herdr")
    result = document.get("result") if isinstance(document, dict) else None
    entries = result.get("agents") if isinstance(result, dict) else None
    if not isinstance(entries, list):
        return LiveResult(ok=False, error="unexpected herdr output")
    agents: list[LiveAgent] = []
    for entry in entries:
        if not isinstance(entry, dict) or not _text(entry.get("name")):
            continue
        agents.append(
            LiveAgent(
                name=str(entry["name"]),
                kind=_text(entry.get("agent")),
                status=_text(entry.get("agent_status")),
                cwd=_text(entry.get("cwd")),
                pane_id=_text(entry.get("pane_id")),
                tab_id=_text(entry.get("tab_id")),
                workspace_id=_text(entry.get("workspace_id")),
                title=_text(entry.get("terminal_title_stripped")),
            )
        )
    return LiveResult(ok=True, agents=tuple(sorted(agents, key=lambda a: a.name)))


def _kill_group(process: subprocess.Popen[bytes]) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=1)


def fetch_live_agents(
    command: Sequence[str] = DEFAULT_COMMAND,
    timeout: float = DEFAULT_TIMEOUT,
    on_spawn: Callable[[subprocess.Popen[bytes] | None], None] | None = None,
) -> LiveResult:
    """Run the CLI once. Never raises; never leaves a process behind.

    `on_spawn` sees the running process (and `None` once it is reaped), so a
    caller that stops mid-call can kill the group itself.
    """
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError:
        return LiveResult(ok=False, error=f"{command[0]}: not found")
    except OSError as exc:
        return LiveResult(ok=False, error=f"{command[0]}: {exc.strerror or exc}")
    if on_spawn is not None:
        on_spawn(process)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        return LiveResult(ok=False, error=f"timed out after {timeout:g}s")
    finally:
        if on_spawn is not None:
            on_spawn(None)
    if process.returncode != 0:
        detail = stderr.decode("utf-8", "replace").strip()[:_ERROR_CHARS]
        return LiveResult(ok=False, error=f"exit {process.returncode}: {detail}".rstrip(": "))
    return parse_agent_list(stdout.decode("utf-8", "replace"))


class HerdrPoller:
    """Calls the CLI every `interval` seconds and reports changed results."""

    def __init__(
        self,
        on_change: Callable[[], None],
        command: Sequence[str] = DEFAULT_COMMAND,
        interval: float = DEFAULT_POLL_SECONDS,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        self._on_change = on_change
        self._command = tuple(command)
        self._interval = interval
        self._timeout = timeout
        self._lock = threading.Lock()
        self._result = PENDING
        self._stop = threading.Event()
        self._process: subprocess.Popen[bytes] | None = None

    @property
    def result(self) -> LiveResult:
        with self._lock:
            return self._result

    def poll_once(self) -> bool:
        """One call; True when the result differs from the previous one."""
        if self._stop.is_set():
            return False
        result = fetch_live_agents(self._command, self._timeout, self._track)
        if self._stop.is_set():
            return False
        with self._lock:
            changed = result != self._result
            self._result = result
        if changed:
            self._on_change()
        return changed

    def start(self) -> None:
        threading.Thread(target=self._loop, name="taskboard-herdr", daemon=True).start()

    def stop(self) -> None:
        """Stop the loop and kill a call that is still running."""
        self._stop.set()
        with self._lock:
            process = self._process
        if process is not None:
            _kill_group(process)

    def _track(self, process: subprocess.Popen[bytes] | None) -> None:
        with self._lock:
            self._process = process
        if process is not None and self._stop.is_set():
            # stop() ran between spawn and registration.
            _kill_group(process)

    def _loop(self) -> None:
        while not self._stop.is_set():
            # The poller must outlive any failure.
            with contextlib.suppress(Exception):
                self.poll_once()
            self._stop.wait(self._interval)
