"""Command-line tools for the iQOO on-device vault.

Two commands, both talking to bridge_server.py on localhost:

    vault-embed   push documents to the phone and embed them there
    vault-query   ask a question, get a JSON context capsule back
"""

__all__ = ["client", "embed", "query"]
