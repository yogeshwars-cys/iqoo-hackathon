@echo off
REM Run vault-embed without pip installing. `pip install -e .` gives a real
REM command on PATH; this is for when you just want it to work now.
python -m vault_cli.embed %*
