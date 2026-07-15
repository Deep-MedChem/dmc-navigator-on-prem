# dmc-navigator-prod — on-prem

Run the DMC Navigator production workflow on your own machine, fully offline.

This repository contains **no source code and builds nothing**. It pulls a
pre-built, obfuscated, license-gated container image from Deep-MedChem and wraps
it in a small `navigator` command. Your molecules, run state, and license never
leave your host.

Production updates arrive through the `stable` image channel. Deep-MedChem moves
that tag only after a reviewed on-prem release passes tests and image smoke checks;
you choose when to install it by running `navigator update`.

- **Offline:** after the image is pulled the workflow runs with no network
  access. The one exception is `navigator data` (downloading an encrypted
  database from Deep-MedChem's public bucket); the databases are also
  installable fully offline from a local mirror (see
  [Install a database](#4-install-a-database)).
- **Licensed:** the image only runs with a valid license issued for *this*
  machine (see [Activate your license](#3-activate-your-license)).
- **Self-contained:** run state lives in `./runs`, inputs in `./inputs`,
  installed databases in `./databases`.

---

## Prerequisites

- A **Linux x86_64 / amd64** host. The published image is currently
  `linux/amd64` only; arm64 is not a supported production target.
- **Docker** Engine 24+ with the `docker compose` plugin.
- **AWS CLI** with the customer source access key supplied by Deep-MedChem.
  The source identity cannot pull from ECR directly; `navigator login` assumes
  the short-lived pull role automatically.
- A license file — issued by Deep-MedChem for your machine (step 3).

---

## 1. Install

```bash
git clone https://github.com/Deep-MedChem/dmc-navigator-on-prem.git
cd dmc-navigator-on-prem
./install_navigator.sh
```

This installs the `navigator` command at
`~/.local/bin/dmc-navigator/navigator` and seeds `.env` with the production image
reference. Open a new shell (or
`export PATH="$PATH:$HOME/.local/bin/dmc-navigator"`) so `navigator` is on your
PATH.

## 2. Authenticate and pull the image

The checked-in configuration uses this exact shared image:

```text
815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/dmc-navigator:stable
```

Configure the source access key supplied by Deep-MedChem under any AWS profile
name you choose:

```bash
aws configure --profile dmc-navigator-source
```

Then authenticate and pull:

```bash
AWS_PROFILE=dmc-navigator-source navigator login
navigator pull
navigator roster      # public strategy metadata; no license required
navigator self-test   # packaged-runtime health; no license required
```

`navigator login` checks the active identity. Unless it is already an
`arn:aws:sts::815935788477:assumed-role/navigator-onprem-pull/...` session, the
script assumes `arn:aws:iam::815935788477:role/navigator-onprem-pull`, uses those
temporary credentials only for the ECR password request, and discards them. It
does not need `jq` and does not write assumed-role credentials to disk.

## 3. Activate your license

The license is bound to this machine's hardware fingerprint. `machine-id` reads
your host's DMI identity directly, so it needs **no image, registry, or license**
— you can run it right after `install` (even before `pull`):

```bash
navigator machine-id
# -> a long integer, e.g. 65422506854891754323540879716734070853
```

Send that integer to Deep-MedChem. We return a `license.json` (which also
carries your database install key, so activating it enables database downloads
in step 4). Install and verify it (this step does use the image, so `pull`
first):

```bash
navigator update-license /path/to/license.json
navigator verify-license
# -> ✅ Valid license (customer='<you>', expires=YYYY-MM-DD)
```

## 4. Install a database

Navigator screens a make-on-demand chemical space (reactions + synthons). You
can bring your own via `./inputs`, or install one of Deep-MedChem's curated
spaces (e.g. **Freedom Space**, ~1.8M synthons).

Database releases are **client-side encrypted**: the bundles are served from a
public bucket as ciphertext, so the download needs no credentials, and only your
machine can decrypt them. The **database install key is embedded in your signed
license** (the same `license.json` from step 3), so there is normally **nothing
extra to install** — activating your license also enables database decryption.

> Air-gapped / override: if Deep-MedChem instead sends a standalone key, save it
> as `./db_install.key` (or point `DMC_NAV_DB_INSTALL_KEY_FILE` in `.env` at it);
> a non-empty key file takes precedence over the license-embedded key.

Browse and install:

```bash
navigator data catalog                    # databases you can install
navigator data install freedom-space-5    # download + verify + decrypt + install
navigator data list                        # -> ["freedom-space-5@2026-03-296b.2"]
navigator data verify freedom-space-5@2026-03-296b.2   # re-check signature + hashes
```

`data install` downloads the encrypted objects, verifies the release's Ed25519
signature **before** touching any payload, unwraps the data key locally with your
install key, decrypts, checks every hash, and atomically installs into
`./databases`. Nothing is decryptable without the install key, and a tampered
bundle fails closed.

**Fully offline / air-gapped install.** If the host has no internet, copy the
release bundle onto it (same `catalog/` + `releases/…` layout) and point the
installer at the local mirror — decryption still happens on-box with your key:

```bash
navigator data install freedom-space-5 --source /mnt/usb/dmc-navigator-databases
```

Remove a release you no longer need with `navigator data remove <db@release>`.

## 5. Run the workflow

**Fastest path — the worked examples.** `examples/run_navigator.sh` drives the
whole resumable `propose → dock → ingest` loop for you against Freedom Space,
docking each batch with *your own* Glide, for three ready-made targets (KIF11,
PYRD, TGFR1). After installing a database (step 4):

```bash
export SCHRODINGER=/opt/schrodinger2026-1        # your install
examples/run_navigator.sh TGFR1                  # gamma, 100k budget, 10 rounds, Glide
examples/run_navigator.sh KIF11 --budget 10k --gpu     # quick run, GPU surrogate
examples/run_navigator.sh PYRD  --scorer mock --budget 200 --iters 2   # smoke, no Schrödinger
```

It is resumable (re-run the same command to continue), writes a compiled
`runs/<run>/pipeline.log`, and lets you pick the strategy (`--method gamma|alpha|beta|analog|all`)
and budget (`--budget 10k|100k|1m`). See [`examples/README.md`](examples/README.md).

**Manual loop.** To drive the steps yourself, put your target config and
reaction/synthon inputs under `./inputs`, then:

```bash
navigator init  --run-dir runs/hk --config-json inputs/HK.json --overwrite
proposals="$(navigator propose --run-dir runs/hk)"
# stdout: runs/hk/proposals/iteration_0000_proposals.parquet
# also writes:
#   runs/hk/proposals/iteration_0000_proposals.csv
#   runs/hk/scores/iteration_0000_scores_template.csv

# Copy the template, set each row's status and score externally, then ingest it.
cp runs/hk/scores/iteration_0000_scores_template.csv \
   runs/hk/scores/iteration_0000_scores.csv
navigator ingest  --run-dir runs/hk --scores runs/hk/scores/iteration_0000_scores.csv
navigator propose --run-dir runs/hk           # next batch
navigator status  --run-dir runs/hk
```

To screen an installed database instead of your own inputs, point `init` at it
with `--database` (and a target):

```bash
navigator init --run-dir runs/freedom --database freedom-space-5@2026-03-296b.2 \
  --target inputs/my_target.json --overwrite
navigator propose --run-dir runs/freedom
```

Paths are relative to the container's working directory: `runs/…` maps to
`./runs`, `inputs/…` to `./inputs`, and installed databases live in `./databases`.

The image's self-contained example target is named
`examples/configs/HK.json` (not `examples/targets/HK.json`). Target configs use
`space.reactions_path` and `space.synthons_path`; the install smoke-test notebook
shows how to copy and adapt that example.

Append `--help` to any workflow command for its options
(`navigator status --help`).

## Choosing a strategy

The optimizer ships four strategies, selected by the `strategy` field in your
target config (`navigator roster` lists them):

| Preset | Role |
|---|---|
| `alpha_diversity_screening` | **Default.** Broad global discovery — start here. |
| `gamma_diversity_screening` | Faster/balanced alternative screen. |
| `beta_diversity_screening` | Advanced exploration (experimental). |
| `analog_harvest` | Harvest analogs of your best chemotypes (beta). |

Recommended: run `alpha_diversity_screening` first; once you have measured hits,
switch to analog harvesting over the same archive and budget:

```bash
navigator transition --run-dir runs/hk --to analog_harvest
navigator propose    --run-dir runs/hk
```

`analog_harvest` reports how concentrated its hits are on every proposal and
warns if a campaign narrows to one or two chemotype families.

---

## Command reference

| Command | Purpose |
|---|---|
| `navigator login` | Assume the pull role and authenticate Docker to ECR |
| `navigator pull` | Pull / update the container image |
| `navigator update` | Check for a newer production image, pull it, and report whether it changed |
| `navigator machine-id` | Print this machine's license fingerprint |
| `navigator update-license <file>` | Install a signed license file |
| `navigator verify-license` | Verify the installed license |
| `navigator data catalog` | List the databases you can install |
| `navigator data install <db[@rel]>` | Download + verify + decrypt + install a database release |
| `navigator data list` | List installed database releases |
| `navigator data verify <db@rel>` | Re-verify an installed release offline (signature + hashes) |
| `navigator data remove <db@rel>` | Delete an installed release from `./databases` |
| `navigator init / propose / ingest / update-params / status` | Workflow (forwarded to the licensed CLI) |
| `navigator transition --to <preset>` | Switch strategy, keeping the archive and budget |
| `navigator roster` | List the public strategy presets (no license required) |
| `navigator self-test` | Report packaged-runtime health without disclosing data (no license required) |
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
- **AWS `AccessDenied` during login.** Confirm that the active profile contains
  the customer source credentials supplied by Deep-MedChem. Do not add ECR
  permissions to that user; it only needs permission to assume
  `navigator-onprem-pull`.
- **arm64 host.** The current release is `linux/amd64` only. Use a supported
  x86_64 Linux host for production rather than relying on emulation.
- **Updating the image.** Run `navigator update`. It fetches the configured tag
  in `.env` (`DMC_NAV_IMAGE_TAG`) and reports whether the local image changed.
  Existing runs, inputs, and the installed license remain in place.
- **Existing `latest` installs.** Change `DMC_NAV_IMAGE_TAG=latest` to
  `DMC_NAV_IMAGE_TAG=stable` in `.env` once, then run `navigator update`.
