# dmc-navigator-prod — on-prem

Run the DMC Navigator production workflow on your own machine, fully offline.

This repository contains **no source code and builds nothing**. It pulls a
pre-built, obfuscated, license-gated container image from Deep-MedChem and wraps
it in a small `navigator` command. Your molecules, run state, and license never
leave your host.

- **Offline:** after the image is pulled, no network access is required or made.
- **Licensed:** the image only runs with a valid license issued for *this*
  machine (see [Activate your license](#3-activate-your-license)).
- **Self-contained:** run state lives in `./runs`, inputs in `./inputs`.

---

## Prerequisites

- Linux host with **Docker** (Engine 24+, with the `docker compose` plugin).
- Registry credentials from Deep-MedChem to pull the image (provided at handoff).
- A license file — issued by Deep-MedChem for your machine (step 3).

---

## 1. Install

```bash
git clone <this-repo-url> dmc-navigator-on-prem
cd dmc-navigator-on-prem
./install_navigator.sh
```

This installs the `navigator` command to `~/.local/bin/dmc-navigator` and seeds a
`.env`. Open a new shell (or `export PATH="$PATH:$HOME/.local/bin/dmc-navigator"`)
so `navigator` is on your PATH.

## 2. Configure and pull the image

Edit `.env` and set `DMC_NAV_IMAGE` to the registry reference we give you
(an ECR path such as
`123456789012.dkr.ecr.eu-central-1.amazonaws.com/on-prem/dmc-navigator/<your-org>`),
then:

```bash
navigator login     # authenticate to the registry (ECR uses the AWS CLI)
navigator pull      # fetch the image
```

## 3. Activate your license

The license is bound to this machine's hardware fingerprint. `machine-id` reads
your host's DMI identity directly, so it needs **no image, registry, or license**
— you can run it right after `install` (even before `pull`):

```bash
navigator machine-id
# -> a long integer, e.g. 65422506854891754323540879716734070853
```

Send that integer to Deep-MedChem. We return a `license.json`; install and
verify it (this step does use the image, so `pull` first):

```bash
navigator update-license /path/to/license.json
navigator verify-license
# -> ✅ Valid license (customer='<you>', expires=YYYY-MM-DD)
```

## 4. Run the workflow

Put your target config and reaction/synthon inputs under `./inputs`, then drive
the resumable workflow. Example using the config in your inputs directory:

```bash
navigator init  --run-dir runs/hk --config-json inputs/HK.json --overwrite
navigator propose --run-dir runs/hk
#   -> runs/hk/proposals/iteration_000_proposals.csv
#      runs/hk/scores/iteration_000_scores_template.csv

# score the proposed molecules externally, fill in the `score` column, then:
navigator ingest  --run-dir runs/hk --scores runs/hk/scores/iteration_000_scores.csv
navigator propose --run-dir runs/hk           # next batch
navigator status  --run-dir runs/hk
```

Paths are relative to the container's working directory: `runs/…` maps to
`./runs` and `inputs/…` maps to `./inputs` on your host.

Append `--help` to any workflow command for its options
(`navigator status --help`).

---

## Command reference

| Command | Purpose |
|---|---|
| `navigator login` | Authenticate Docker to the image registry |
| `navigator pull` | Pull / update the container image |
| `navigator update` | Check for a newer production image, pull it, and report whether it changed |
| `navigator machine-id` | Print this machine's license fingerprint |
| `navigator update-license <file>` | Install a signed license file |
| `navigator verify-license` | Verify the installed license |
| `navigator init / propose / ingest / update-params / status` | Workflow (forwarded to the licensed CLI) |
| `navigator shell` | Open a shell in the image (debugging) |
| `navigator uninstall` | Remove the installed command + config |

## Notes & troubleshooting

- **Clean errors by design.** Errors print a single line. For full tracebacks
  while diagnosing, set `DMC_NAV_DEBUG=1` in `.env`.
- **License is hardware-bound.** If you move to a different machine/VM, re-run
  `navigator machine-id` there and request a new license — the old one will
  report a hardware-fingerprint mismatch.
- **"No license found".** Install one with `navigator update-license`, or check
  that `DMC_NAV_LICENSE_FILE` in `.env` points at it.
- **Permissions on `./runs`.** The container runs as your UID/GID (recorded in
  `.env` at install) so generated files are owned by you.
- **Updating the image.** Run `navigator update`. It fetches the configured tag
  in `.env` (`DMC_NAV_IMAGE_TAG`) and reports whether the local image changed.
  Existing runs, inputs, and the installed license remain in place.
