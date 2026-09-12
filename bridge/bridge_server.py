"""
iQOO Air-Gapped AI Co-Processor — desktop bridge.

The laptop listens; the phone dials in and does the work. This process holds
exactly one phone connection and turns HTTP requests from local tools (an
IDE, the MCP server, query.py) into WebSocket round-trips to the device.

WHY THE LAPTOP IS THE LISTENER

A phone is a bad server: Android reaps background sockets, the IP changes
with every DHCP lease, and most shared Wi-Fi has client isolation that drops
peer-to-peer traffic outright. A laptop on the same subnet is a stable
listener. It also keeps the trust story straight — nothing can reach the
vault unless the phone chose to dial out first, and there is no listening
port on the device for anything to find.

WIRE PROTOCOL

    desktop -> phone   {"id": "q_…", "action": "search"|"ask"|"index"|"ping",
                        "data": {…}}
    phone -> desktop   {"id": "q_…", "action": "result", "data": {…}}
    phone -> desktop   {"action": "telemetry", "data": {…}}   (unsolicited)

Note the ordering constraint in _phone_socket: `action` is checked before
`id`, so a reply must not use the action name "telemetry" or it is swallowed
as a status frame and the caller times out with no error anywhere. The Dart
client sends "result" for this reason.

Run:
    pip install -r requirements.txt
    python bridge_server.py
"""

from __future__ import annotations

import asyncio
import json
import socket
import time
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

app = FastAPI(title="iQOO AI Co-Processor Bridge", version="2.0")

# How long to wait for the phone before giving up. Indexing a large document
# means one embedding pass per chunk at roughly 230 ms each on a mid-range
# device, so the index timeout is generous where the query timeout is not.
QUERY_TIMEOUT_SECONDS = 20.0
INDEX_TIMEOUT_SECONDS = 180.0

# Generation is a different order of magnitude again. Gemma 2B int4 on a
# mid-range phone writes a capsule in roughly 5-40 s depending on backend and
# context length, and a cold first call after load is slower still. A timeout
# that fits retrieval would abort every single capsule.
ASK_TIMEOUT_SECONDS = 300.0

# The largest frame we will put on the wire toward the phone.
#
# This is not our limit, it is the receiver's. 1 MiB is the default
# `max_size` in the `websockets` library and the same order as OkHttp's and
# dart:io's defaults, and a client that hits it does not just drop the frame
# — it closes the connection with status 1009, which strands every other
# request in flight and forces the phone app to reconnect. Losing the whole
# link because one document was fat is a terrible trade, so we check the
# serialised frame here and fail that one request instead.
#
# Checked after serialisation on purpose: JSON escaping inflates non-ASCII
# badly (a CJK character is 3 UTF-8 bytes but 6 as \uXXXX, an emoji 4 bytes
# but 12 as a surrogate pair), so the source file's size is not a usable
# proxy for the frame's size.
MAX_FRAME_BYTES = 1024 * 1024


class PayloadTooLarge(Exception):
    """The serialised request frame would exceed what the phone will accept."""


class PhoneLink:
    """The single connected device, and the queries in flight to it."""

    def __init__(self) -> None:
        self.websocket: Optional[WebSocket] = None
        self.device_info: Dict[str, Any] = {}
        self.pending: Dict[str, asyncio.Future] = {}
        self.connected_at: Optional[float] = None
        self.request_counter = 0

    @property
    def is_connected(self) -> bool:
        return self.websocket is not None

    async def attach(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self.websocket = websocket
        self.connected_at = time.time()

    def detach(self) -> None:
        self.websocket = None
        self.device_info = {}
        self.connected_at = None
        # Fail every in-flight request rather than leaving callers hanging
        # until their own timeout. A dropped link is knowable immediately;
        # making an HTTP client wait 20 s to discover it is just rude.
        for future in self.pending.values():
            if not future.done():
                future.set_exception(
                    ConnectionError("Phone disconnected mid-request")
                )
        self.pending.clear()

    async def request(
        self,
        action: str,
        data: Dict[str, Any],
        timeout: float,
    ) -> Dict[str, Any]:
        if not self.websocket:
            raise ConnectionError("No phone connected to the bridge.")

        self.request_counter += 1
        query_id = f"q_{int(time.time() * 1000)}_{self.request_counter}"

        frame = json.dumps({"id": query_id, "action": action, "data": data})
        frame_bytes = len(frame.encode("utf-8"))
        if frame_bytes > MAX_FRAME_BYTES:
            raise PayloadTooLarge(
                f"Request frame is {frame_bytes / 1048576:.2f} MB, over the "
                f"{MAX_FRAME_BYTES // 1048576} MB the phone will accept. "
                f"Split the document and send it in pieces."
            )

        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self.pending[query_id] = future

        try:
            await self.websocket.send_text(frame)
            return await asyncio.wait_for(future, timeout=timeout)
        finally:
            self.pending.pop(query_id, None)


phone = PhoneLink()


@app.websocket("/ws/phone")
async def _phone_socket(websocket: WebSocket) -> None:
    if phone.is_connected:
        # One device at a time. Silently replacing the existing link would
        # strand whatever is in flight on it.
        #
        # Accept before closing, even though we are about to hang up: closing
        # an un-accepted WebSocket makes the ASGI server reject the handshake
        # with a bare HTTP 403 and the close code and reason are discarded, so
        # the second phone is told nothing about why. Accepting first costs one
        # round trip and lets 4409 and its reason actually arrive.
        await websocket.accept()
        await websocket.close(code=4409, reason="A phone is already linked.")
        print("[bridge] refused a second phone; one is already linked")
        return

    await phone.attach(websocket)
    print(f"[bridge] phone linked from {websocket.client.host}")
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError as exc:
                # One corrupt frame is not a reason to tear down a working
                # link and strand every other request on it. Drop the frame,
                # say so, keep going.
                print(f"[bridge] ignoring unparseable frame ({exc})")
                continue
            if not isinstance(message, dict):
                print(f"[bridge] ignoring non-object frame: {type(message).__name__}")
                continue

            action = message.get("action")
            message_id = message.get("id")

            # Order matters: see the module docstring.
            if action == "telemetry":
                # The documented footgun: a reply that reuses the action name
                # "telemetry" is swallowed here and the caller times out with
                # nothing logged anywhere. It costs one dict lookup to notice
                # that this "status frame" is answering a live request, and a
                # silent 20 s timeout is a genuinely awful thing to debug.
                if message_id in phone.pending:
                    print(f"[bridge] WARNING: frame {message_id} replied with "
                          f'action="telemetry"; a reply must use '
                          f'action="result" or it is read as a status frame')
                data = message.get("data")
                if isinstance(data, dict):
                    phone.device_info = data
                continue

            future = phone.pending.get(message_id)
            if future and not future.done():
                future.set_result(message.get("data", {}))
            elif message_id is not None:
                # Late reply after a timeout, or a phone-side id bug. Either
                # way the caller is already gone; log it so it is findable.
                print(f"[bridge] reply for unknown/expired id {message_id!r}")
    except WebSocketDisconnect:
        print("[bridge] phone disconnected")
    except Exception as exc:  # noqa: BLE001 - any failure means the link is gone
        print(f"[bridge] link error: {exc}")
    finally:
        phone.detach()


class QueryRequest(BaseModel):
    query: str
    top_k: int = Field(default=3, ge=1, le=20)


class AskRequest(BaseModel):
    query: str
    top_k: int = Field(default=5, ge=1, le=20)

    # Lets a caller take the fast path deliberately. Retrieval is ~250 ms;
    # generation is seconds. A script looping over many questions usually
    # wants the former.
    generate: bool = True


class IndexRequest(BaseModel):
    filename: str
    content: str


def _offline() -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={
            "error": "No phone linked. Open the Vault Co-Processor app, go to "
                     "the Bridge tab, and connect to this machine."
        },
    )


def _too_large(exc: PayloadTooLarge) -> JSONResponse:
    return JSONResponse(status_code=413, content={"error": str(exc)})


def _stamped(response: Any, started: float) -> Any:
    """Adds the roundtrip timing, tolerating a phone that did not send a dict.

    The phone is supposed to reply with a JSON object, but a buggy or
    half-ported client can send a list, a bare string or null, and
    `response["..."] = ...` on any of those is an unhandled TypeError — i.e.
    a 500 with a stack trace in the log and nothing useful for the caller.
    A malformed reply is the device's problem to report, not ours to crash
    on, so wrap anything that is not an object and let the caller see it.
    """
    latency = round((time.perf_counter() - started) * 1000, 2)
    if isinstance(response, dict):
        response["roundtrip_latency_ms"] = latency
        return response
    return {
        "error": "Phone sent a malformed reply (expected a JSON object, got "
                 f"{type(response).__name__}).",
        "raw_reply": response,
        "roundtrip_latency_ms": latency,
    }


@app.get("/api/status")
async def get_status() -> Dict[str, Any]:
    return {
        "status": "online",
        "phone_connected": phone.is_connected,
        "connected_for_seconds": (
            round(time.time() - phone.connected_at, 1)
            if phone.connected_at
            else None
        ),
        "phone_device_info": phone.device_info,
        "bridge_addresses": _lan_addresses(),
    }


@app.get("/api/telemetry")
async def get_telemetry() -> Dict[str, Any]:
    """Live compute telemetry from the phone's most recent status frame.

    Served from the cached frame rather than round-tripping to the device:
    the phone pushes one every two seconds unprompted, so this is at most
    that stale and costs the device nothing to answer.
    """
    if not phone.is_connected:
        return {"error": "No phone linked."}
    info = phone.device_info
    return {
        "backend": info.get("backend"),
        "total_indexed": info.get("total_indexed"),
        "compute": info.get("compute", {}),
        "served_queries": info.get("served_queries"),
        "served_indexes": info.get("served_indexes"),
    }


@app.post("/api/query")
async def query_phone(request: QueryRequest):
    if not phone.is_connected:
        return _offline()

    started = time.perf_counter()
    try:
        response = await phone.request(
            "search",
            {"query": request.query, "top_k": request.top_k},
            timeout=QUERY_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        return JSONResponse(
            status_code=504,
            content={"error": f"Phone did not answer within "
                              f"{QUERY_TIMEOUT_SECONDS}s."},
        )
    except ConnectionError as exc:
        return JSONResponse(status_code=503, content={"error": str(exc)})
    except PayloadTooLarge as exc:
        return _too_large(exc)

    return _stamped(response, started)


@app.get("/api/llm")
async def get_llm_status() -> Dict[str, Any]:
    """Which models the phone currently has loaded."""
    if not phone.is_connected:
        return {"error": "No phone linked."}
    info = phone.device_info
    return {
        "encoder": {
            "model": "all-MiniLM-L6-v2",
            "backend": info.get("backend"),
            "dim": info.get("embedding_dim"),
            "loaded": True,
        },
        "reasoner": info.get("llm", {"state": "unknown"}),
        "capsule_prompt_version": info.get("capsule_prompt_version"),
    }


@app.post("/api/ask")
async def ask_phone(request: AskRequest):
    """Retrieval plus a generated context capsule.

    Separate from /api/query rather than a flag on it, because the two have
    timeouts an order of magnitude apart. /api/query stays the fast path and
    returns raw chunks; this returns the fixed-schema capsule.
    """
    if not phone.is_connected:
        return _offline()

    started = time.perf_counter()
    try:
        response = await phone.request(
            "ask",
            {
                "query": request.query,
                "top_k": request.top_k,
                "generate": request.generate,
            },
            timeout=ASK_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        return JSONResponse(
            status_code=504,
            content={
                "error": f"Phone did not return a capsule within "
                         f"{ASK_TIMEOUT_SECONDS}s. Generation on a loaded "
                         f"2B model can be slow on the CPU backend - try "
                         f"--no-generate to confirm retrieval still works."
            },
        )
    except ConnectionError as exc:
        return JSONResponse(status_code=503, content={"error": str(exc)})
    except PayloadTooLarge as exc:
        return _too_large(exc)

    return _stamped(response, started)


@app.post("/api/index")
async def index_document(request: IndexRequest):
    if not phone.is_connected:
        return _offline()

    started = time.perf_counter()
    try:
        response = await phone.request(
            "index",
            {"filename": request.filename, "content": request.content},
            timeout=INDEX_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        return JSONResponse(
            status_code=504,
            content={"error": f"Phone did not finish indexing within "
                              f"{INDEX_TIMEOUT_SECONDS}s."},
        )
    except ConnectionError as exc:
        return JSONResponse(status_code=503, content={"error": str(exc)})
    except PayloadTooLarge as exc:
        return _too_large(exc)

    return _stamped(response, started)


def _lan_addresses() -> list[str]:
    """Best-effort list of this machine's LAN IPs, for the phone to dial.

    Uses a UDP socket to a public address to discover which interface the
    kernel would route through. No packet is actually sent — connect() on a
    datagram socket only sets the peer — so this works with no network
    access and without touching the address it names.
    """
    found: list[str] = []
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))
        found.append(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass

    try:
        for info in socket.getaddrinfo(socket.gethostname(), None,
                                       socket.AF_INET):
            address = info[4][0]
            if not address.startswith("127.") and address not in found:
                found.append(address)
    except OSError:
        pass
    return found


# Static hosting is optional. The upstream version mounted this
# unconditionally at "/", which 500s the whole app if the directory is
# missing; here it is skipped when absent.
_static_dir = Path(__file__).parent / "static"
if _static_dir.is_dir():
    app.mount("/", StaticFiles(directory=str(_static_dir), html=True),
              name="static")


if __name__ == "__main__":
    import uvicorn

    addresses = _lan_addresses()
    print("=" * 62)
    print("  iQOO Co-Processor Bridge")
    print("=" * 62)
    if addresses:
        print("  Enter one of these in the phone app's Bridge tab:")
        for address in addresses:
            print(f"      {address}    (port 8000)")
    else:
        print("  No LAN address found — check this machine is on Wi-Fi.")
    print("=" * 62)

    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
