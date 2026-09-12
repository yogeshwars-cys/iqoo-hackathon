"""`vault-embed` — push documents from the laptop into the phone's index.

    vault-embed notes.md
    vault-embed src/ --recursive --ext py,dart
    vault-embed --stdin --name pasted.txt
    vault-embed corpus/ -r --dry-run

The text travels to the phone, is embedded there by MiniLM, and the vectors
stay there. Nothing is embedded on this machine and nothing goes to a cloud
service — which is the entire point, so the command says so on completion
rather than leaving it implied.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time
from typing import Iterable, List

from .client import (
    RULE,
    TIMEOUT_INDEX,
    BridgeError,
    fail,
    heading,
    post,
)

# Mirrors allowedExtensions in lib/core/vault_engine.dart. The phone enforces
# its own list regardless; this one exists so that `vault-embed src/ -r` does
# not spend minutes uploading .png files for the device to reject.
DEFAULT_EXTENSIONS = {
    "txt", "md", "dart", "py", "js", "ts", "json", "yaml", "yml",
    "java", "kt", "c", "h", "cpp", "rs", "go", "sh", "csv", "html", "css",
    "toml", "ini", "cfg", "conf", "env", "sql", "xml", "gradle", "kts",
}

# Directories that are never worth indexing and are usually enormous.
SKIP_DIRS = {
    ".git", ".svn", "node_modules", "__pycache__", ".dart_tool", "build",
    ".gradle", ".idea", ".venv", "venv", "dist", ".mypy_cache", ".pytest_cache",
}

# Sized to the WebSocket frame the bridge can actually deliver, not to what
# feels like a reasonable document. Anything larger than roughly 1 MiB once
# serialised makes the phone close the link with status 1009 ("message too
# big"), which kills every other request in flight — so this used to be 2 MB
# and a single fat file would drop the device off the bridge entirely.
#
# This is a cheap early check on the raw file, not the real limit: JSON
# escaping inflates non-ASCII (an emoji is 4 bytes on disk and 12 in the
# frame), so bridge_server does the authoritative check post-serialisation
# and returns 413. A file under this cap can still be refused there.
MAX_BYTES = 1024 * 1024


def read_stdin_text() -> str | None:
    """Reads standard input as UTF-8 regardless of the console code page.

    sys.stdin on Windows decodes with the ANSI code page (cp1252 here), so
    piping a UTF-8 file in turned "Café" into "CafÃ©" and emoji into four
    bytes of mojibake — with no error, because cp1252 happily decodes almost
    any byte. The corrupted text was then embedded on the phone, so the
    damage was permanent and invisible until someone searched for it.
    Reading the raw buffer and decoding explicitly is the only reliable fix.

    Strict, and returns None on failure, to match read_text(): refusing
    non-UTF-8 input is better than embedding replacement characters that
    nobody will ever be able to search for.
    """
    raw = sys.stdin.buffer.read()
    try:
        # BOM-prefixed input is common from PowerShell redirection.
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None

    # Reading the raw buffer also bypasses the universal-newline translation
    # that text mode did for free, and Path.read_text() still does it on the
    # file path. Without this, piping a CRLF document in and passing the same
    # document by name produce different chunk text on the device — and the
    # verbatim spans in a capsule are checked by substring match, so that
    # difference is not cosmetic.
    return text.replace("\r\n", "\n").replace("\r", "\n")


def collect(paths: Iterable[str], recursive: bool,
            extensions: set[str]) -> List[pathlib.Path]:
    found: List[pathlib.Path] = []
    for raw in paths:
        path = pathlib.Path(raw)
        if path.is_file():
            # An explicitly named file is indexed whatever its extension.
            # The filter exists to make directory walks sane, not to argue
            # with someone who pointed at one specific file.
            found.append(path)
        elif path.is_dir():
            if not recursive:
                print(f"  skipping directory {path} (use --recursive)")
                continue
            for child in sorted(path.rglob("*")):
                if not child.is_file():
                    continue
                if any(part in SKIP_DIRS for part in child.parts):
                    continue
                if child.suffix.lstrip(".").lower() in extensions:
                    found.append(child)
        else:
            print(f"  no such path: {path}")
    return found


def read_text(path: pathlib.Path) -> str | None:
    """Returns the file's text, or None when it is not text.

    Decoding as strict UTF-8 and letting it fail is the cheapest reliable
    binary test there is — and it matches what the phone does, so a file
    accepted here will not be rejected there.
    """
    try:
        if path.stat().st_size > MAX_BYTES:
            print(f"  {path.name}: skipped — larger than "
                  f"{MAX_BYTES // (1024 * 1024)} MB")
            return None
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        print(f"  {path.name}: skipped — not UTF-8 text")
        return None
    except OSError as exc:
        print(f"  {path.name}: skipped — {exc}")
        return None


def push(name: str, content: str) -> tuple[bool, int]:
    started = time.perf_counter()
    try:
        data = post(
            "/api/index",
            {"filename": name, "content": content},
            timeout=TIMEOUT_INDEX,
        )
    except BridgeError as exc:
        print(f"  {name}: FAILED — {exc}")
        return False, 0

    if "error" in data:
        print(f"  {name}: FAILED — {data['error']}")
        return False, 0

    roundtrip = (time.perf_counter() - started) * 1000
    added = data.get("chunks_added", 0)
    print(f"  {name}: +{added} chunks · "
          f"{data.get('elapsed_ms')} ms on-device "
          f"({data.get('ms_per_chunk')} ms/chunk) · "
          f"{roundtrip:.0f} ms roundtrip")
    return True, data.get("total_indexed", 0)


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="vault-embed",
        description="Embed documents into the phone's on-device vector index.",
        epilog="The phone does the embedding. Nothing is sent to a cloud "
               "service and no vectors come back.",
    )
    parser.add_argument("paths", nargs="*", help="files or directories")
    parser.add_argument("-r", "--recursive", action="store_true",
                        help="descend into directories")
    parser.add_argument("--ext", default=None,
                        help="comma-separated extensions for directory walks "
                             f"(default: {len(DEFAULT_EXTENSIONS)} text and "
                             "source types)")
    parser.add_argument("--stdin", action="store_true",
                        help="read the document from standard input")
    parser.add_argument("--name", default="stdin.txt",
                        help="filename to record for --stdin content")
    parser.add_argument("--dry-run", action="store_true",
                        help="list what would be sent, send nothing")
    args = parser.parse_args(argv)

    if args.stdin:
        content = read_stdin_text()
        if content is None:
            return fail("Standard input is not UTF-8 text.")
        if not content.strip():
            return fail("Nothing on standard input.")

        heading(f"vault-embed · {args.name} from stdin")

        # --dry-run used to be ignored on this path entirely: the document
        # was read, uploaded and embedded, and the phone's chunk count went
        # up, while the flag promised nothing would be sent. For a tool whose
        # whole premise is that data moves only when you say so, a --dry-run
        # that transmits is the worst bug in the file.
        if args.dry_run:
            print(f"  would send {args.name} "
                  f"({len(content.encode('utf-8'))} bytes from stdin)")
            print(RULE)
            print("  Dry run — nothing was sent.")
            return 0

        ok, total = push(args.name, content)
        if ok:
            print(RULE)
            print(f"  Vault now holds {total} chunks, all on the phone.")
        return 0 if ok else 1

    if not args.paths:
        parser.print_help()
        return 2

    extensions = (
        {e.strip().lstrip(".").lower() for e in args.ext.split(",")}
        if args.ext else DEFAULT_EXTENSIONS
    )

    files = collect(args.paths, args.recursive, extensions)
    if not files:
        return fail("Nothing to embed.")

    heading(f"vault-embed · {len(files)} file(s)")

    if args.dry_run:
        for path in files:
            print(f"  would send {path} ({path.stat().st_size} bytes)")
        print(RULE)
        print("  Dry run — nothing was sent.")
        return 0

    sent = 0
    failed = 0
    skipped = 0
    total = 0
    started = time.perf_counter()

    for path in files:
        content = read_text(path)
        if content is None:
            skipped += 1          # read_text already said why
            continue
        if not content.strip():
            # Used to be skipped in silence, so `vault-embed empty.txt`
            # printed a header, a rule and nothing between them.
            print(f"  {path.name}: skipped — empty")
            skipped += 1
            continue
        ok, total_now = push(path.name, content)
        if ok:
            sent += 1
            total = total_now
        else:
            failed += 1

    elapsed = time.perf_counter() - started
    print(RULE)
    summary = f"  {sent} embedded, {failed} failed"
    if skipped:
        summary += f", {skipped} skipped"
    print(f"{summary}, {elapsed:.1f}s total")
    if sent:
        print(f"  Vault now holds {total} chunks, all on the phone.")

    # The old rule was `failed and not sent`, which reported success for two
    # cases a script very much wants to know about: a partial run where some
    # uploads failed, and a run where every file was skipped as binary or
    # empty — nothing embedded, nothing technically "failed", exit 0.
    #
    # Skips alone do not fail a directory walk; hitting a binary in a tree is
    # routine. They do fail it when nothing got through at all, which is what
    # `vault-embed some.png` is.
    return 0 if sent and not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
