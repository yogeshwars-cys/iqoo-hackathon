"""Shared HTTP client and terminal formatting for the vault-* commands.

Deliberately stdlib-only. These commands are meant to be usable the moment
the repo is cloned, and `pip install requests` is a step between someone and
a working demo.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any, Dict

# Overridable so the commands can be pointed at a bridge on another port —
# port 8000 is popular and something else is often already on it. The tests
# rely on this too, since they run a real bridge on an ephemeral port.
BRIDGE_URL = os.environ.get("VAULT_BRIDGE_URL", "http://127.0.0.1:8000").rstrip("/")

# Retrieval is a quarter of a second; generation on a mid-range phone is
# seconds to tens of seconds; embedding a large file is one encoder pass per
# chunk. One timeout cannot serve all three.
TIMEOUT_STATUS = 5.0
TIMEOUT_QUERY = 30.0
TIMEOUT_ASK = 300.0
TIMEOUT_INDEX = 600.0

RULE = "─" * 68


class BridgeError(RuntimeError):
    """Anything that stopped us reaching the phone, already made readable."""


def _ensure_utf8() -> None:
    # Retrieved chunks contain whatever the corpus did, which on Windows
    # means characters the default console code page cannot encode.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass


_ensure_utf8()


def get(path: str, timeout: float = TIMEOUT_STATUS) -> Dict[str, Any]:
    try:
        request = urllib.request.Request(f"{BRIDGE_URL}{path}")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise BridgeError(_http_error(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise BridgeError(_unreachable(exc)) from exc


def post(path: str, payload: Dict[str, Any], timeout: float) -> Dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{BRIDGE_URL}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise BridgeError(_http_error(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise BridgeError(_unreachable(exc)) from exc


def _http_error(exc: urllib.error.HTTPError) -> str:
    detail = ""
    try:
        body = json.loads(exc.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        body = None

    if isinstance(body, dict):
        detail = body.get("error", "")
        # FastAPI's own validation failures use "detail", not "error", and
        # carry a list of per-field problems. Without this a bad --top-k
        # reported only "HTTP 422: Unprocessable Content", which tells the
        # user neither which argument was wrong nor what the valid range is.
        if not detail and "detail" in body:
            detail = _validation_detail(body["detail"])

    if exc.code == 503:
        return detail or (
            "No phone linked. Open the Vault Co-Processor app, go to the "
            "Bridge tab, and connect to this machine."
        )
    if exc.code == 504:
        return detail or "The phone did not answer in time."
    return f"HTTP {exc.code}: {detail or exc.reason}"


def _validation_detail(detail: Any) -> str:
    """Flattens FastAPI's 422 body into one line a human can act on."""
    if isinstance(detail, str):
        return detail
    if not isinstance(detail, list):
        return ""
    parts = []
    for item in detail:
        if not isinstance(item, dict):
            continue
        # loc is ("body", "top_k"); the tail is the field the caller named.
        location = item.get("loc") or []
        field = str(location[-1]) if location else "request"
        parts.append(f"{field}: {item.get('msg', 'invalid')}")
    return "; ".join(parts)


def _unreachable(exc: Exception) -> str:
    return (
        f"Cannot reach the bridge at {BRIDGE_URL} ({exc}).\n"
        f"Start it with:  python bridge_server.py"
    )


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def heading(text: str) -> None:
    print(RULE)
    print(f"  {text}")
    print(RULE)


def wrap(text: str, indent: str = "  ", width: int = 66,
         hanging: str | None = None) -> str:
    """Soft-wraps prose to a readable measure.

    Not textwrap.fill: that collapses newlines the model may have put there
    deliberately, and a capsule answer occasionally contains a list.

    `hanging` is the indent for continuation lines, so a bulleted caveat
    wraps under its own text rather than back under the bullet.
    """
    continuation = indent if hanging is None else hanging
    lines = []
    for paragraph in text.split("\n"):
        current = indent
        for word in paragraph.split():
            if len(current) + len(word) + 1 > width and current.strip():
                lines.append(current.rstrip())
                current = continuation
            current += word + " "
        lines.append(current.rstrip())
    return "\n".join(lines)


def fail(message: str) -> int:
    print(f"\n  {message}\n", file=sys.stderr)
    return 1
