#!/bin/bash
# Add the navigator bin dir to PATH via ~/.bashrc, idempotently.
set -euo pipefail
BIN_DIR="${1:-${HOME}/.local/bin/dmc-navigator}"
MARKER="# dmc-navigator on-prem PATH"
BASHRC="${HOME}/.bashrc"

if [ -f "$BASHRC" ] && grep -qF "$MARKER" "$BASHRC"; then
  echo "PATH entry already present in ${BASHRC}."
else
  {
    echo ""
    echo "$MARKER"
    echo "export PATH=\"\$PATH:${BIN_DIR}\""
  } >> "$BASHRC"
  echo "Added ${BIN_DIR} to PATH in ${BASHRC} (open a new shell to pick it up)."
fi
