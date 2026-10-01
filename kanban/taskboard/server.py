"""HTTP server for the board.

Standard library only. `ThreadingHTTPServer` is bound to the loopback
interface: Python's docs warn that `http.server` "is not recommended for
production" because "it only implements basic security checks", but that
warning is about hostile input (no header validation, symlink following), not
throughput. A read-only, single-user board on 127.0.0.1 has no untrusted
client, and `ThreadingHTTPServer` is specifically the class documented to cope
with "web browsers pre-opening sockets" -- exactly what a page plus an SSE
stream does.

Change delivery is two-stage:

  /events     an SSE stream carrying only a version token
  /api/board  the real payload, revalidated with ETag / If-None-Match

Keeping the stream tiny matters because SSE over HTTP/1.1 is capped at 6
concurrent connections per origin (Chrome crbug.com/275955 and Firefox
bugzil.la/906896 both closed this "Won't fix"), so every held connection is
scarce. The client falls back to plain polling if the stream cannot be
established.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .model import Board
from .scanner import Scanner

STATIC_DIR = Path(__file__).parent / "static"

#: How often the background thread stats the task folders.
DEFAULT_POLL_SECONDS = 1.0
#: Idle gap after which the SSE stream emits a comment so proxies and dead
#: sockets are detected. MDN documents `:`-prefixed lines as ignored comments.
SSE_KEEPALIVE_SECONDS = 15.0
#: Reconnection delay advertised to EventSource, in milliseconds.
SSE_RETRY_MS = 2000

_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
}


class BoardState:
    """Holds the current board and wakes SSE listeners when it changes."""

    def __init__(self, scanner: Scanner, poll_seconds: float = DEFAULT_POLL_SECONDS) -> None:
        self._scanner = scanner
        self._poll_seconds = poll_seconds
        self._condition = threading.Condition()
        self._version = 0
        # Fingerprint BEFORE scanning. The cold scan takes ~1.1 s on a large
        # corpus, and agents write these files continuously; fingerprinting
        # afterwards would record the post-write state for a file the scan
        # missed, so refresh() would see no movement and that file would never
        # be reparsed for the life of the process.
        self._fingerprint = scanner.fingerprint()
        self._board: Board = scanner.scan()
        self._payload, self._key = self._render(self._board)
        self._stop = threading.Event()

    @staticmethod
    def _render(board: Board) -> tuple[bytes, str]:
        """Serialize a board once, returning (payload, content key).

        The content key drops `scannedAt` and `scanMs`, which change on every
        scan and would otherwise bump the ETag when the board is identical.
        Serializing twice cost ~24 ms per refresh on a 1,000-card board.
        """
        document = board.to_json()
        volatile = {key: document.pop(key, None) for key in ("scannedAt", "scanMs")}
        content_key = hashlib.blake2b(
            json.dumps(document, ensure_ascii=False, sort_keys=True).encode("utf-8"),
            digest_size=16,
        ).hexdigest()
        document.update(volatile)
        return json.dumps(document, ensure_ascii=False).encode("utf-8"), content_key

    @property
    def version(self) -> int:
        with self._condition:
            return self._version

    @property
    def board(self) -> Board:
        with self._condition:
            return self._board

    def snapshot(self) -> tuple[int, bytes]:
        with self._condition:
            return self._version, self._payload

    def refresh(self, force: bool = False) -> bool:
        """Rescan if the on-disk fingerprint moved. Returns True when changed."""
        fingerprint = self._scanner.fingerprint()
        if not force and fingerprint == self._fingerprint:
            return False
        board = self._scanner.scan()
        # Only after a successful scan. Advancing the fingerprint first would
        # lose the change permanently if scan() raised, since the poll loop
        # swallows the exception and the next sweep would see no movement.
        self._fingerprint = fingerprint
        payload, key = self._render(board)
        with self._condition:
            if key == self._key and not force:
                # The files moved but the board did not: keep the ETag stable
                # so connected clients are not woken for nothing.
                self._board = board
                return False
            self._board = board
            self._payload = payload
            self._key = key
            self._version += 1
            self._condition.notify_all()
        return True

    def wait_for_change(self, last_seen: int, timeout: float) -> int:
        """Block until the version passes `last_seen`, or until timeout."""
        with self._condition:
            if self._version > last_seen:
                return self._version
            self._condition.wait(timeout)
            return self._version

    def start(self) -> None:
        thread = threading.Thread(target=self._loop, name="taskboard-poll", daemon=True)
        thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._condition:
            self._condition.notify_all()

    def _loop(self) -> None:
        while not self._stop.wait(self._poll_seconds):
            try:
                self.refresh()
            except Exception:  # noqa: BLE001 - a scan failure must not kill the poller
                continue


class BoardRequestHandler(BaseHTTPRequestHandler):
    """Routes for the board. Read-only: only GET and HEAD are served."""

    server_version = "taskboard"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    state: BoardState  # injected via the handler subclass

    def log_message(self, fmt: str, *args: object) -> None:
        if self.server.verbose:  # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    # -- routing ---------------------------------------------------------

    def _host_allowed(self) -> bool:
        """Reject requests whose Host is not loopback.

        The board serves absolute filesystem paths, branch names and task
        titles with no authentication. CORS stops a cross-origin page from
        *reading* a response, but DNS rebinding sidesteps that entirely: a
        hostile page can point its own domain at 127.0.0.1 and then it is
        same-origin. Pinning Host to loopback closes that.
        """
        host = self.headers.get("Host", "")
        name = host.rsplit(":", 1)[0].strip("[]") if host else ""
        return name in ("127.0.0.1", "localhost", "::1", "")

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._host_allowed():
            self.send_error(HTTPStatus.FORBIDDEN, "Invalid Host header")
            return
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._serve_static("index.html")
        elif path in ("/app.js", "/style.css"):
            self._serve_static(path.lstrip("/"))
        elif path == "/api/board":
            self._serve_board()
        elif path == "/events":
            self._serve_events()
        elif path == "/healthz":
            self._send_bytes(b'{"ok":true}', "application/json")
        else:
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.do_GET()

    # -- handlers --------------------------------------------------------

    def _serve_static(self, name: str) -> None:
        target = (STATIC_DIR / name).resolve()
        # Defence in depth: never serve outside the bundled static directory.
        if not target.is_file() or STATIC_DIR.resolve() not in target.parents:
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return
        content_type = _CONTENT_TYPES.get(target.suffix, "application/octet-stream")
        self._send_bytes(target.read_bytes(), content_type, cache="no-cache")

    def _serve_board(self) -> None:
        version, payload = self.state.snapshot()
        etag = f'"v{version}"'
        if self.headers.get("If-None-Match") == etag:
            # Per MDN, a 304 carries no body and repeats only validators.
            self.send_response(HTTPStatus.NOT_MODIFIED)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            return
        self._send_bytes(payload, "application/json; charset=utf-8", etag=etag)

    def _serve_events(self) -> None:
        # An unbounded stream carries neither Content-Length nor a chunked
        # encoding, so the connection cannot be reused afterwards.
        self.close_connection = True
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        # Disable proxy buffering if anything sits in front of us.
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        if self.command == "HEAD":
            # A HEAD must not carry a body. Entering the loop would both
            # desynchronise the connection and park a handler thread until the
            # next keepalive write fails -- `curl -I` or a prefetcher is enough
            # to accumulate them, and ThreadingHTTPServer has no thread cap.
            return

        last_seen = -1
        try:
            self.wfile.write(f"retry: {SSE_RETRY_MS}\n\n".encode())
            self.wfile.flush()
            while True:
                version = self.state.wait_for_change(last_seen, SSE_KEEPALIVE_SECONDS)
                if version > last_seen:
                    last_seen = version
                    self.wfile.write(f"event: change\ndata: {version}\n\n".encode())
                else:
                    # A comment line keeps the socket warm and lets us notice
                    # a disconnected client via the write failing.
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    # -- helpers ---------------------------------------------------------

    def _send_bytes(
        self,
        body: bytes,
        content_type: str,
        *,
        etag: str | None = None,
        cache: str = "no-cache",
    ) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        if etag:
            self.send_header("ETag", etag)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                return


class BoardServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], state: BoardState, verbose: bool) -> None:
        self.verbose = verbose
        self.state = state
        handler = type("BoundHandler", (BoardRequestHandler,), {"state": state})
        super().__init__(address, handler)


def serve(
    roots: tuple[str, ...],
    host: str = "127.0.0.1",
    port: int = 8787,
    recursive: bool = False,
    poll_seconds: float = DEFAULT_POLL_SECONDS,
    verbose: bool = False,
) -> BoardServer:
    """Build and start the board server. Returns the running server."""
    scanner = Scanner(roots=roots, recursive=recursive)
    state = BoardState(scanner, poll_seconds=poll_seconds)
    state.start()
    server = BoardServer((host, port), state, verbose)
    return server


def run(
    roots: tuple[str, ...],
    host: str = "127.0.0.1",
    port: int = 8787,
    recursive: bool = False,
    poll_seconds: float = DEFAULT_POLL_SECONDS,
    verbose: bool = False,
) -> None:
    """Run the board server until interrupted."""
    server = serve(roots, host, port, recursive, poll_seconds, verbose)
    board = server.state.board
    print(f"taskboard  http://{host}:{server.server_address[1]}")
    print(f"  folders : {len(board.roots)}")
    print(f"  tasks   : {len(board.cards)}  (first scan {board.scan_ms:.0f} ms)")
    if board.errors:
        for message in board.errors:
            print(f"  warning : {message}")
    print("  Ctrl-C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.shutdown()
        server.server_close()


__all__ = ["BoardState", "BoardServer", "serve", "run", "time"]
