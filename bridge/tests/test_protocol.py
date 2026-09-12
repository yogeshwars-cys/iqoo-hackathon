"""Wire-protocol tests: a real bridge_server, a fake phone, no device.

These are the regressions that only show up once something is actually on the
socket — a phone that replies with the wrong shape, hangs up mid-request,
speaks garbage, or connects twice. Each one was reproduced against the real
server before the fix went in.

Run either way:
    pytest tests/test_protocol.py
    python tests/test_protocol.py
"""

from __future__ import annotations

import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from fake_phone import Phone, TELEMETRY, bridge, default_reply  # noqa: E402


# ---------------------------------------------------------------------------
# Baseline: the happy path still works.
# ---------------------------------------------------------------------------

def test_query_ask_and_index_round_trip():
    b = bridge()
    try:
        b.phone()
        assert b.wait_linked(), "phone never linked"

        status, body = b.post("/api/query", {"query": "hello", "top_k": 3})
        assert status == 200, body
        assert body["query"] == "hello"
        assert "roundtrip_latency_ms" in body

        status, body = b.post("/api/ask", {"query": "hi", "top_k": 5,
                                           "generate": True})
        assert status == 200, body
        assert body["answer"] == "an answer"

        status, body = b.post("/api/index", {"filename": "a.txt",
                                             "content": "text"})
        assert status == 200, body
        assert body["chunks_added"] == 1
    finally:
        b.close()


def test_status_and_telemetry_reflect_the_phone():
    b = bridge()
    try:
        b.phone()
        assert b.wait_linked()
        status = b.get("/api/status")
        assert status["phone_connected"] is True
        assert status["phone_device_info"]["backend"] == "XNNPACK"
        assert b.get("/api/telemetry")["backend"] == "XNNPACK"
        assert b.get("/api/llm")["reasoner"]["state"] == "ready"
    finally:
        b.close()


def test_endpoints_report_503_with_no_phone():
    b = bridge()
    try:
        for path, payload in (("/api/query", {"query": "x"}),
                              ("/api/ask", {"query": "x"}),
                              ("/api/index", {"filename": "a", "content": "b"})):
            status, body = b.post(path, payload)
            assert status == 503, f"{path} gave {status}"
            assert "No phone linked" in body["error"]
    finally:
        b.close()


# ---------------------------------------------------------------------------
# A phone that replies with the wrong shape used to produce HTTP 500 and a
# TypeError in the log: `response["roundtrip_latency_ms"] = ...` on a list.
# ---------------------------------------------------------------------------

def test_non_object_reply_is_reported_not_a_500():
    for bad in (None, [1, 2, 3], "a string"):
        b = bridge()
        try:
            # Built as a raw frame so "data": null is expressible at all —
            # returning None from a responder means "stay silent".
            def responder(message, _b=bad):
                return json.dumps({"id": message.get("id"),
                                   "action": "result", "data": _b})

            b.phone(responder=responder)
            assert b.wait_linked()
            status, body = b.post("/api/query", {"query": "x", "top_k": 3})
            assert status != 500, f"{bad!r} still produces a 500"
            assert "malformed reply" in body["error"], body
            assert body["raw_reply"] == bad
        finally:
            b.close()


# ---------------------------------------------------------------------------
# One unparseable frame used to raise out of the receive loop, run the
# `finally: phone.detach()` and tear the whole link down — stranding every
# other request in flight and forcing the app to reconnect.
# ---------------------------------------------------------------------------

def test_malformed_frame_does_not_kill_the_link():
    b = bridge()
    try:
        state = {"first": True}

        def responder(message):
            if state["first"]:
                state["first"] = False
                return "{not valid json at all"      # raw frame, verbatim
            return default_reply(message)

        b.phone(responder=responder)
        assert b.wait_linked()

        # The first request gets no usable reply and times out client-side;
        # what matters is that the link is still up afterwards.
        b.post_expecting_no_answer("/api/query", {"query": "doomed",
                                                  "top_k": 3})
        assert b.get("/api/status")["phone_connected"] is True, \
            "a single bad frame dropped the phone"

        status, body = b.post("/api/query", {"query": "after", "top_k": 3})
        assert status == 200 and body["query"] == "after", \
            "link unusable after a malformed frame"
    finally:
        b.close()


def test_non_object_frame_does_not_kill_the_link():
    b = bridge()
    try:
        state = {"first": True}

        def responder(message):
            if state["first"]:
                state["first"] = False
                return "[1, 2, 3]"            # valid JSON, wrong top-level
            return default_reply(message)

        b.phone(responder=responder)
        assert b.wait_linked()
        b.post_expecting_no_answer("/api/query", {"query": "doomed",
                                                  "top_k": 3})
        assert b.get("/api/status")["phone_connected"] is True

        status, body = b.post("/api/query", {"query": "after", "top_k": 3})
        assert status == 200 and body["query"] == "after"
    finally:
        b.close()


# ---------------------------------------------------------------------------
# A document larger than the receiver's WebSocket limit made the phone close
# with status 1009, which killed the link rather than failing one request.
# ---------------------------------------------------------------------------

def test_oversized_document_is_refused_with_413_and_the_link_survives():
    import bridge_server

    b = bridge()
    try:
        b.phone()
        assert b.wait_linked()

        content = "x" * (bridge_server.MAX_FRAME_BYTES + 4096)
        status, body = b.post("/api/index", {"filename": "big.txt",
                                             "content": content})
        assert status == 413, f"expected 413, got {status}: {body}"
        assert "phone will accept" in body["error"]

        assert b.get("/api/status")["phone_connected"] is True, \
            "an oversized document dropped the phone"
        status, body = b.post("/api/index", {"filename": "small.txt",
                                             "content": "fine"})
        assert status == 200, "link unusable after an oversized document"
    finally:
        b.close()


def test_escaped_payload_over_the_limit_is_caught_after_serialisation():
    """1.2 MB of emoji is under any sane byte cap but ~3.6 MB on the wire."""
    b = bridge()
    try:
        b.phone()
        assert b.wait_linked()
        status, body = b.post("/api/index",
                              {"filename": "emoji.txt",
                               "content": "\U0001f512" * 300000})
        assert status == 413, f"expected 413, got {status}"
        assert b.get("/api/status")["phone_connected"] is True
    finally:
        b.close()


# ---------------------------------------------------------------------------
# Disconnects and concurrency.
# ---------------------------------------------------------------------------

def test_disconnect_mid_request_fails_fast_instead_of_waiting_for_timeout():
    b = bridge()
    try:
        phone = b.phone(responder=lambda message: None)   # never answers
        assert b.wait_linked()

        started = time.perf_counter()

        def drop():
            time.sleep(0.4)
            phone.stop()

        import threading
        threading.Thread(target=drop, daemon=True).start()

        status, body = b.post("/api/query", {"query": "x", "top_k": 3},
                              timeout=30)
        elapsed = time.perf_counter() - started

        assert status == 503, f"got {status}: {body}"
        assert "disconnect" in body["error"].lower()
        # QUERY_TIMEOUT_SECONDS is 20; a dropped link must not wait it out.
        assert elapsed < 10, f"took {elapsed:.1f}s to notice the drop"
    finally:
        b.close()


def test_a_second_phone_is_refused_with_a_reason_and_the_first_survives():
    b = bridge()
    try:
        b.phone()
        assert b.wait_linked()

        second = Phone(b.ws_url, default_reply)
        second.start()
        deadline = time.time() + 10
        while second.link_error is None and time.time() < deadline:
            time.sleep(0.05)

        assert second.link_error is not None, "a second phone was accepted"
        # Closing before accept() makes the server reject the handshake with a
        # bare HTTP 403 and the code and reason are lost, so the phone is told
        # nothing about why it was turned away.
        assert second.closed_code == 4409, \
            f"expected close code 4409, got {second.closed_code!r}"
        assert "already linked" in (second.closed_reason or "")

        assert b.get("/api/status")["phone_connected"] is True
        status, _ = b.post("/api/query", {"query": "x", "top_k": 3})
        assert status == 200, "first phone broken by a second connection"
    finally:
        b.close()


def test_concurrent_requests_do_not_cross_talk():
    """Replies are matched by id; four in flight must not swap answers."""
    import threading

    b = bridge()
    try:
        b.phone()
        assert b.wait_linked()

        results = {}

        def worker(n):
            status, body = b.post("/api/ask", {"query": f"q{n}", "top_k": 3})
            results[n] = (status, body.get("query"))

        threads = [threading.Thread(target=worker, args=(i,))
                   for i in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30)

        assert len(results) == 4, f"only {len(results)} finished"
        for n, (status, echoed) in results.items():
            assert status == 200
            assert echoed == f"q{n}", f"request {n} got {echoed!r}"
    finally:
        b.close()


def test_reply_with_an_unknown_id_is_ignored_not_misrouted():
    """A stale or mis-stamped id must not be handed to whoever is waiting."""
    b = bridge()
    try:
        def responder(message):
            return json.dumps({"id": "q_not_a_real_id", "action": "result",
                               "data": {"answer": "wrong"}})

        b.phone(responder=responder)
        assert b.wait_linked()
        # The caller waits it out rather than receiving somebody else's answer.
        b.post_expecting_no_answer("/api/query", {"query": "x", "top_k": 3})
        assert b.get("/api/status")["phone_connected"] is True
    finally:
        b.close()


def test_reply_using_the_telemetry_action_is_not_delivered():
    """The documented ordering footgun: `action` is checked before `id`, so a
    reply named "telemetry" is swallowed as a status frame. The server now
    logs a warning when that happens; the caller still gets nothing, which is
    why the warning is the whole point."""
    b = bridge()
    try:
        def responder(message):
            return json.dumps({"id": message.get("id"), "action": "telemetry",
                               "data": {"answer": "swallowed"}})

        b.phone(responder=responder)
        assert b.wait_linked()
        b.post_expecting_no_answer("/api/query", {"query": "x", "top_k": 3})
        assert b.get("/api/status")["phone_connected"] is True
    finally:
        b.close()


def test_unicode_survives_the_round_trip():
    """Windows console code pages make this worth pinning explicitly."""
    b = bridge()
    try:
        seen = {}

        def responder(message):
            seen.update(message.get("data") or {})
            return default_reply(message)

        b.phone(responder=responder)
        assert b.wait_linked()

        text = "# Café résumé ☕\n日本語 Привет 🔒\n∑ ∫ π ≈ 3.14159\n"
        status, _ = b.post("/api/index", {"filename": "uni.md",
                                          "content": text})
        assert status == 200
        assert seen["content"] == text, "content was mangled in transit"

        status, body = b.post("/api/query", {"query": text, "top_k": 3})
        assert status == 200
        assert body["query"] == text
    finally:
        b.close()


def _main() -> int:
    tests = [(n, o) for n, o in sorted(globals().items())
             if n.startswith("test_") and callable(o)]
    failures = 0
    for name, func in tests:
        try:
            func()
            print(f"  PASS  {name}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  FAIL  {name}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_main())
