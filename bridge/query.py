"""Deprecated shim — use `vault-query` instead.

Kept so existing notes and muscle memory keep working. Everything now lives
in vault_cli/, which backs both `vault-query` and `vault-embed`; having two
implementations of the same client is how they drift apart.

    python query.py "question"     ->  vault-query "question"
    python query.py --index FILE   ->  vault-embed FILE
"""

from __future__ import annotations

import sys


def main() -> int:
    argv = sys.argv[1:]

    if "--index" in argv:
        index_at = argv.index("--index")
        target = argv[index_at + 1] if len(argv) > index_at + 1 else None
        if target is None:
            print("query.py: --index needs a file path", file=sys.stderr)
            return 2
        print("note: `python query.py --index FILE` is now `vault-embed FILE`",
              file=sys.stderr)
        from vault_cli.embed import main as embed_main
        return embed_main([target])

    print("note: `python query.py ...` is now `vault-query ...`",
          file=sys.stderr)
    from vault_cli.query import main as query_main
    return query_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
