"""Unit tests for the desktop half. No bridge, no phone, no network.

Every test here pins a bug that was actually reachable from the command line;
the comment above each one says what the old behaviour was, because a test
whose failure mode you cannot picture gets deleted the first time it is
inconvenient.

Run either way:
    pytest tests/test_units.py
    python tests/test_units.py
"""

from __future__ import annotations

import io
import json
import pathlib
import sys
import urllib.error

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import bridge_server                                    # noqa: E402
from vault_cli import client, embed, query              # noqa: E402


# ---------------------------------------------------------------------------
# bridge_server._stamped — a phone that replies with something other than an
# object used to produce "TypeError: 'NoneType' object does not support item
# assignment" and a bare HTTP 500.
# ---------------------------------------------------------------------------

def test_stamped_adds_latency_to_a_normal_dict_reply():
    out = bridge_server._stamped({"answer": "x"}, 0.0)
    assert out["answer"] == "x"
    assert isinstance(out["roundtrip_latency_ms"], float)


def test_stamped_wraps_non_dict_replies_instead_of_raising():
    for bad in (None, [1, 2, 3], "a string", 7):
        out = bridge_server._stamped(bad, 0.0)
        assert isinstance(out, dict), f"{bad!r} did not produce a dict"
        assert "error" in out, f"{bad!r} produced no error message"
        assert out["raw_reply"] == bad
        assert "roundtrip_latency_ms" in out


# ---------------------------------------------------------------------------
# Frame size. A document over the receiver's WebSocket limit made the phone
# close the link with status 1009, killing every other request in flight.
# ---------------------------------------------------------------------------

def test_oversize_frame_raises_rather_than_being_sent():
    link = bridge_server.PhoneLink()

    class _Sock:
        sent = []

        async def send_text(self, text):
            self.sent.append(text)

    link.websocket = _Sock()

    import asyncio

    payload = {"filename": "big.txt",
               "content": "x" * (bridge_server.MAX_FRAME_BYTES + 1024)}
    try:
        asyncio.run(link.request("index", payload, timeout=1.0))
    except bridge_server.PayloadTooLarge as exc:
        assert "over the" in str(exc)
    else:
        raise AssertionError("oversized frame was not refused")

    assert link.websocket.sent == [], "oversized frame reached the socket"
    assert link.pending == {}, "a refused request left a pending future behind"


def test_frame_limit_is_measured_after_json_escaping():
    """An emoji is 4 bytes on disk and 12 once escaped, so a byte count of the
    source text is not a usable proxy for the frame size. This is why the
    check lives after json.dumps rather than on the file."""
    text = "\U0001f512" * 1000
    assert len(text.encode("utf-8")) == 4000
    assert len(json.dumps(text).encode("utf-8")) > 11000


# ---------------------------------------------------------------------------
# vault_cli.embed.read_stdin_text — sys.stdin decodes with the console code
# page on Windows, so piped UTF-8 silently became mojibake ("Café" ->
# "CafÃ©") and was embedded on the phone in that state.
# ---------------------------------------------------------------------------

class _FakeStdin:
    def __init__(self, raw: bytes):
        self.buffer = io.BytesIO(raw)


def _with_stdin(raw: bytes):
    original = sys.stdin
    sys.stdin = _FakeStdin(raw)
    try:
        return embed.read_stdin_text()
    finally:
        sys.stdin = original


def test_stdin_decodes_utf8_regardless_of_console_code_page():
    source = "# Café résumé naïve ☕\n日本語 Привет 🔒\n"
    assert _with_stdin(source.encode("utf-8")) == source


def test_stdin_strips_a_utf8_bom():
    assert _with_stdin("﻿hello".encode("utf-8")) == "hello"


def test_stdin_normalises_crlf_like_the_file_path_does():
    """Path.read_text() translates newlines, so stdin must too or the same
    document indexes as different text depending on how it was supplied."""
    assert _with_stdin(b"a\r\nb\rc\n") == "a\nb\nc\n"


def test_stdin_refuses_non_utf8_rather_than_embedding_replacement_chars():
    assert _with_stdin(b"\xff\xfe\x00binary\x00") is None


# ---------------------------------------------------------------------------
# client._http_error — a bad --top-k produced only "HTTP 422: Unprocessable
# Content", naming neither the argument nor the range.
# ---------------------------------------------------------------------------

def _http_error(code: int, body: dict) -> str:
    exc = urllib.error.HTTPError(
        "http://x/api/ask", code, "Unprocessable Content", {},
        io.BytesIO(json.dumps(body).encode("utf-8")))
    return client._http_error(exc)


def test_http_error_surfaces_fastapi_validation_detail():
    message = _http_error(422, {"detail": [
        {"loc": ["body", "top_k"],
         "msg": "Input should be greater than or equal to 1"}]})
    assert "top_k" in message
    assert "greater than or equal to 1" in message


def test_http_error_prefers_our_own_error_key():
    assert _http_error(413, {"error": "frame too big"}) == \
        "HTTP 413: frame too big"


def test_http_error_survives_a_non_json_body():
    exc = urllib.error.HTTPError("http://x", 500, "Internal Server Error", {},
                                 io.BytesIO(b"<html>nope</html>"))
    assert "500" in client._http_error(exc)


# ---------------------------------------------------------------------------
# query.render helpers — an explicitly null "answer" is not a missing key, so
# .get("answer", "") returned None and the command died with an
# AttributeError traceback instead of printing the rest of the capsule.
# ---------------------------------------------------------------------------

def test_text_coerces_null_to_the_fallback():
    assert query._text(None, "(none)") == "(none)"
    assert query._text("hi") == "hi"
    assert query._text(42) == "42"


def test_similarity_tolerates_a_missing_score():
    assert query._similarity(0.8123).strip() == "0.8123"
    assert "?" in query._similarity(None)


def test_render_survives_a_capsule_full_of_nulls():
    capsule = {"query": "q", "answer": None, "confidence": None,
               "key_facts": None, "caveats": None,
               "sources": [{"file": "a.md"}],   # no similarity
               "retrieval": {}, "generation": {}}
    buffer = io.StringIO()
    original = sys.stdout
    sys.stdout = buffer
    try:
        query.render(capsule, 12.0)       # must not raise
    finally:
        sys.stdout = original
    assert "a.md" in buffer.getvalue()


# ---------------------------------------------------------------------------
# embed.main exit codes. The old rule was `1 if failed and not sent else 0`,
# which reported success when every file was skipped and nothing was sent.
# ---------------------------------------------------------------------------

def _embed_with_stub(tmp_files, push_ok=True, argv_extra=()):
    """Runs embed.main against a stubbed push(), capturing stdout."""
    calls = []

    def fake_push(name, content):
        calls.append(name)
        return (push_ok, len(calls))

    original_push, embed.push = embed.push, fake_push
    buffer, original_out = io.StringIO(), sys.stdout
    sys.stdout = buffer
    try:
        code = embed.main([str(p) for p in tmp_files] + list(argv_extra))
    finally:
        embed.push = original_push
        sys.stdout = original_out
    return code, buffer.getvalue(), calls


def test_binary_only_run_exits_nonzero():
    tmp = _tmpdir()
    binary = tmp / "blob.bin"
    binary.write_bytes(bytes(range(256)) * 8)
    code, output, calls = _embed_with_stub([binary])
    assert calls == [], "a binary file was uploaded"
    assert code != 0, "skipping every file still reported success"
    assert "not UTF-8" in output


def test_empty_file_is_reported_and_exits_nonzero():
    tmp = _tmpdir()
    blank = tmp / "blank.txt"
    blank.write_text("   \n\t\n", encoding="utf-8")
    code, output, calls = _embed_with_stub([blank])
    assert calls == []
    assert code != 0
    assert "empty" in output, "an empty file was skipped in total silence"


def test_partial_failure_exits_nonzero():
    tmp = _tmpdir()
    good = tmp / "good.txt"
    good.write_text("some real content here", encoding="utf-8")
    code, _, calls = _embed_with_stub([good], push_ok=False)
    assert calls == ["good.txt"]
    assert code != 0


def test_successful_run_exits_zero():
    tmp = _tmpdir()
    good = tmp / "good.txt"
    good.write_text("some real content here", encoding="utf-8")
    code, _, calls = _embed_with_stub([good])
    assert calls == ["good.txt"]
    assert code == 0


def test_stdin_dry_run_sends_nothing():
    """--dry-run was ignored entirely on the --stdin path: the document was
    read, uploaded and embedded while the flag promised the opposite."""
    calls = []

    def fake_push(name, content):
        calls.append(name)
        return (True, 1)

    original_push, embed.push = embed.push, fake_push
    original_stdin, sys.stdin = sys.stdin, _FakeStdin(b"secret payload")
    buffer, original_out = io.StringIO(), sys.stdout
    sys.stdout = buffer
    try:
        code = embed.main(["--stdin", "--name", "s.txt", "--dry-run"])
    finally:
        embed.push = original_push
        sys.stdin = original_stdin
        sys.stdout = original_out

    assert calls == [], "--dry-run transmitted the document"
    assert code == 0
    assert "nothing was sent" in buffer.getvalue().lower()


def test_max_bytes_fits_inside_the_wire_frame_limit():
    """The client cap used to be 2 MB while the link died above ~1 MiB."""
    assert embed.MAX_BYTES <= bridge_server.MAX_FRAME_BYTES


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

_TMP_ROOT = None


def _tmpdir() -> pathlib.Path:
    global _TMP_ROOT
    import tempfile
    if _TMP_ROOT is None:
        _TMP_ROOT = pathlib.Path(tempfile.mkdtemp(prefix="vault_units_"))
    sub = _TMP_ROOT / f"case_{len(list(_TMP_ROOT.iterdir()))}"
    sub.mkdir()
    return sub


def _main() -> int:
    """Plain-python runner, so the suite needs no pytest to be useful."""
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
