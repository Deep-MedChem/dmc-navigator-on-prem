#!/bin/bash
# Installer for dmc-navigator-prod on-prem. Modelled on cheese-on-prem's
# install-cheese.sh, trimmed for a single license-gated CLI image.
#
# What it does:
#   1. creates the config + local-bin directories,
#   2. seeds .env from .env.example (preserving an existing .env),
#   3. records your UID/GID and this repo path so `navigator` works anywhere,
#   4. creates ./runs, ./inputs and an empty ./license.json placeholder,
#   5. installs the `navigator` command onto your PATH.
#
# It does NOT pull the image or touch your license — do that after install with
# `navigator pull` and `navigator update-license <file>`.
set -euo pipefail

echo "Installing dmc-navigator-prod (on-prem)..."

REPO_FOLDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config/dmc-navigator"
BIN_DIR="${HOME}/.local/bin/dmc-navigator"

# Production support is linux/amd64 only. Keep local smoke tests possible under
# Docker Desktop emulation, but make a non-production host impossible to miss.
HOST_PLATFORM="$(uname -s)/$(uname -m)"
case "$HOST_PLATFORM" in
  Linux/x86_64|Linux/amd64) ;;
  *)
    echo "⚠️  This host is ${HOST_PLATFORM}; the production image supports linux/amd64 only." >&2
    echo "   Use an x86_64 Linux host for a supported customer deployment." >&2
    ;;
esac

echo "Preparing folders..."
mkdir -p "${CONFIG_DIR}" "${BIN_DIR}"

# ── .env ──────────────────────────────────────────────────────────────────────
# Preserve an existing .env (it holds your image ref + paths); only seed it from
# the template on a fresh install.
if [ -f "${REPO_FOLDER}/.env" ]; then
  echo "Keeping existing ${REPO_FOLDER}/.env"
else
  cp "${REPO_FOLDER}/.env.example" "${REPO_FOLDER}/.env"
  echo "Seeded ${REPO_FOLDER}/.env with the shared production ECR image."
fi

# Record UID/GID so the container writes ./runs as you (not root). Append only if
# absent, so re-running the installer is idempotent.
grep -q '^DMC_NAV_UID=' "${REPO_FOLDER}/.env" || printf 'DMC_NAV_UID=%s\n' "$(id -u)" >> "${REPO_FOLDER}/.env"
grep -q '^DMC_NAV_GID=' "${REPO_FOLDER}/.env" || printf 'DMC_NAV_GID=%s\n' "$(id -g)" >> "${REPO_FOLDER}/.env"

# ── host directories the compose mounts expect ────────────────────────────────
mkdir -p "${REPO_FOLDER}/runs" "${REPO_FOLDER}/inputs" "${REPO_FOLDER}/databases"
# An empty license placeholder keeps the read-only compose mount valid before a
# real license arrives. `machine-id` works against it; `verify-license` will
# report "no license" until you install one.
[ -e "${REPO_FOLDER}/license.json" ] || : > "${REPO_FOLDER}/license.json"
# Likewise for the database install key: an empty placeholder keeps the
# read-only mount valid. `navigator data install` needs the real key (delivered
# by Deep-MedChem); every other command works without it.
[ -e "${REPO_FOLDER}/db_install.key" ] || : > "${REPO_FOLDER}/db_install.key"

# ── record repo path for the `navigator` command ─────────────────────────────
cat > "${CONFIG_DIR}/env.sh" <<EOF
# Written by install_navigator.sh — do not edit by hand.
export REPO_FOLDER="${REPO_FOLDER}"
EOF

# ── install scripts onto PATH ─────────────────────────────────────────────────
echo "Installing the 'navigator' command to ${BIN_DIR}..."
for f in "${REPO_FOLDER}"/scripts/*; do
  install -m 0755 "$f" "${BIN_DIR}/$(basename "$f")"
done

bash "${REPO_FOLDER}/install/configure-bashrc.sh" "${BIN_DIR}"

cat <<EOF

✅ Installed.

Next steps (open a new shell first, or run: export PATH="\$PATH:${BIN_DIR}"):
  1. configure the AWS source credentials supplied by Deep-MedChem
  2. navigator login            # assume navigator-onprem-pull and authenticate to ECR
  3. navigator pull             # fetch the linux/amd64 image
  4. navigator machine-id       # send the printed ID to Deep-MedChem
  5. navigator update-license <license.json>   # install the license we send back
  6. navigator verify-license   # expect: ✅ Valid license
  7. navigator data install freedom-space-5     # download + decrypt a database (optional)
  8. navigator status --help    # then run the workflow (init / propose / ingest / ...)

Run 'navigator help' for the full command list.
EOF
