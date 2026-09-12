"""An in-process bridge + phone, so the desktop half can be tested alone.

The real phone is an Android app holding two models. Nothing here needs one:
`bridge()` runs the actual FastAPI app on an ephemeral port and links a
WebSocket client that speaks the documented wire protocol, with a hook for
answering badly on purpose.

Ephemeral ports rather than 8000 because a developer running the real bridge
while the tests run should not have them fight over the socket.

Used by test_protocol.py. Needs fastapi/uvicorn/websockets — the bridge's own
dependencies from requirements.txt, nothing extra.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import socket
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, Optional


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


# The stock replies a well-behaved phone sends. Deliberately small — these
# tests are about the transport, not about retrieval quality.
#
# Responders take the whole inbound message, not just (action, data), because
# the interesting misbehaviours are about the envelope: replying with the
# wrong id, the wrong action name, or a frame that is not JSON at all. Those
# cannot be expressed if the harness owns the envelope.
def default_reply(message: Dict[str, Any]) -> Dict[str, Any]:
    action = message.get("action")
    data = message.get("data") or {}
    if action == "index":
        return {"file": data.get("filename"), "chunks_added": 1,
                "total_indexed": 1, "elapsed_ms": 5, "ms_per_chunk": 5.0}
    if action == "search":
        return {"query": data.get("query"), "results": [],
                "latency_ms": 1, "embed_ms": 1, "total_indexed": 1}
    if action == "ask":
        return {"capsule_version": "1.0", "query": data.get("query"),
                "answer": "an answer", "confidence": "high",
                "key_facts": [], "caveats": [], "sources": [], "context": [],
                "generation": {"ran": bool(data.get("generate", True))},
                "retrieval": {"latency_ms": 1, "embed_ms": 1,
                              "chunks_scanned": 1}}
    return {"error": f"Unsupported action: {action}"}


TELEMETRY = {
    "backend": "XNNPACK", "embedding_dim": 384, "total_indexed": 1,
    "served_queries": 0, "served_indexes": 0,
    "llm": {"state": "ready", "model": "gemma2-2b-it-cpu-int4.task",
            "backend": "cpu", "load_ms": 100},
    "compute": {"cpu_percent": 10.0, "cpu_kind": "measured",
                "gpu_percent": 2.0, "gpu_kind": "measured",
                "npu_percent": None, "npu_kind": "unavailable",
                "inference_duty_percent": 0.0,
                "device": {"manufacturer": "test", "model": "TEST1"},
                "thermal": {"status": 0, "label": "none",
                            "throttling": False}},
}


class Bridge:
    """A running bridge server plus, optionally, a linked phone."""

    def __init__(self, port: int, server: Any, thread: threading.Thread):
        self.port = port
        self.url = f"http://127.0.0.1:{port}"
        self.ws_url = f"ws://127.0.0.1:{port}/ws/phone"
        self._server = server
        self._thread = thread
        self._phones: list[Phone] = []

    def get(self, path: str, timeout: float = 5.0) -> Dict[str, Any]:
        with urllib.request.urlopen(self.url + path, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    def post(self, path: str, payload: Dict[str, Any],
             timeout: float = 30.0) -> tuple[int, Any]:
        """Returns (status, body). HTTP errors come back, they do not raise —
        the status code is usually the thing under test."""
        request = urllib.request.Request(
            self.url + path, data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            try:
                return exc.code, json.loads(raw)
            except json.JSONDecodeError:
                return exc.code, raw

    def post_expecting_no_answer(self, path: str, payload: Dict[str, Any],
                                 timeout: float = 3.0) -> None:
        """For cases where the phone is supposed to leave the caller hanging.

        The point of those tests is never the hung request — it is that the
        link is still usable afterwards — so the client-side timeout is
        swallowed here rather than repeated in every test.
        """
        try:
            self.post(path, payload, timeout=timeout)
        except Exception:  # noqa: BLE001 - a timeout is the expected outcome
            pass

    def phone(self, responder: Optional[Callable] = None,
              send_telemetry: bool = True) -> "Phone":
        p = Phone(self.ws_url, responder or default_reply, send_telemetry)
        p.start()
        self._phones.append(p)
        return p

    def wait_linked(self, linked: bool = True, timeout: float = 10.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if self.get("/api/status")["phone_connected"] is linked:
                    return True
            except Exception:  # noqa: BLE001 - server may still be binding
                pass
            time.sleep(0.05)
        return False

    def close(self) -> None:
        for p in self._phones:
            p.stop()
        self._server.should_exit = True
        self._thread.join(timeout=10)


class Phone:
    """A WebSocket client speaking the phone side of the protocol.

    `responder` is called with the whole inbound message and returns one of:

      dict  -> wrapped as a normal {"id": …, "action": "result"} reply
      str   -> put on the wire verbatim, envelope and all; this is how the
               malformed-frame, wrong-id and wrong-action cases are written
      None  -> send nothing, leaving the caller to time out
    """

    def __init__(self, ws_url: str, responder: Callable,
                 send_telemetry: bool = True):
        self.ws_url = ws_url
        self.responder = responder
        self.send_telemetry = send_telemetry
        self.received: list[Dict[str, Any]] = []
        self.link_error: Optional[BaseException] = None
        self.closed_code: Optional[int] = None
        self.closed_reason: Optional[str] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()
        self._stop_event: Optional[asyncio.Event] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self._ready.wait(timeout=10)

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._stop_event = asyncio.Event()
        try:
            self._loop.run_until_complete(self._main())
        except BaseException as exc:  # noqa: BLE001 - recorded, not raised
            self.link_error = exc
            # `rcvd` is the close frame the server actually sent. Prefer it:
            # ConnectionClosed.code/.reason are deprecated in websockets 13.1
            # and reading them first emits a warning on every run.
            rcvd = getattr(exc, "rcvd", None)
            if rcvd is not None:
                self.closed_code = rcvd.code
                self.closed_reason = rcvd.reason
            else:
                self.closed_code = getattr(exc, "code", None)
                self.closed_reason = getattr(exc, "reason", None)
        finally:
            self._ready.set()
            self._drain()

    def _drain(self) -> None:
        """Retires the loop quietly.

        Stopping a loop from another thread while a WebSocket is still open
        leaves the library's keepalive task pending, and closing the loop then
        prints a wall of 'Task was destroyed'/'Event loop is closed' noise
        that buries the actual test results. Cancel, let the cancellations
        settle, then close.
        """
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        with contextlib.suppress(Exception):
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(
                    asyncio.gather(*pending, return_exceptions=True))
            loop.run_until_complete(loop.shutdown_asyncgens())
        with contextlib.suppress(Exception):
            loop.close()

    async def _main(self) -> None:
        import websockets

        # max_size=None so a test can deliberately send an oversized frame
        # without the client library closing the link first.
        async with websockets.connect(self.ws_url, max_size=None) as ws:
            if self.send_telemetry:
                await ws.send(json.dumps({"action": "telemetry",
                                          "data": TELEMETRY}))
            self._ready.set()

            receiver = asyncio.create_task(self._receive(ws))
            stopper = asyncio.create_task(self._stop_event.wait())
            done, pending = await asyncio.wait(
                {receiver, stopper}, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                if task is receiver:
                    task.result()      # re-raise a genuine link failure

    async def _receive(self, ws) -> None:
        async for raw in ws:
            message = json.loads(raw)
            self.received.append(message)
            reply = self.responder(message)
            if reply is None:
                continue              # answer nothing; caller should time out
            if isinstance(reply, str):
                await ws.send(reply)           # raw, possibly invalid, frame
            else:
                await ws.send(json.dumps({"id": message.get("id"),
                                          "action": "result",
                                          "data": reply}))

    def stop(self) -> None:
        loop, event = self._loop, self._stop_event
        if loop is not None and event is not None and not loop.is_closed():
            with contextlib.suppress(RuntimeError):
                loop.call_soon_threadsafe(event.set)
        if self._thread:
            self._thread.join(timeout=5)


def bridge() -> Bridge:
    """Starts the real bridge_server app on a free port, in this process."""
    import uvicorn
    import bridge_server

    # Module-level singleton: a previous test's phone must not leak into this
    # one. Cheaper and more honest than trying to reload the module.
    bridge_server.phone = bridge_server.PhoneLink()

    port = free_port()
    config = uvicorn.Config(bridge_server.app, host="127.0.0.1", port=port,
                            log_level="error")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    deadline = time.time() + 15
    while not getattr(server, "started", False):
        if time.time() > deadline:
            raise RuntimeError("bridge server did not start")
        time.sleep(0.05)

    return Bridge(port, server, thread)
