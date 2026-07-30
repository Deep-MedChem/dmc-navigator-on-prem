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

## Running on Windows

Not the primary target, but fully working via Docker Desktop + WSL2. A few things are Windows-specific
enough to call out separately from the Linux instructions above.

### Setup

1. **Docker Desktop**, with WSL2 as the backend. Current Docker Desktop versions no longer offer a
   Hyper-V alternative for Linux containers, so WSL2 is effectively required, not optional. In
   Settings → Resources → WSL Integration, enable integration for your distro.
2. **AWS CLI + credentials** — same requirement as Linux (see Prerequisites above); install and
   configure inside your WSL2 distro.
3. **Git Bash** (bundled with "Git for Windows", https://git-scm.com/download/win) — use this
   specifically to run `examples/run_navigator.sh`, **not WSL2**. WSL2 is a real Linux VM; calling a
   *native Windows* Schrodinger install (`glide.exe`/`ligprep.exe`) across that VM boundary risks
   path-translation and executable-resolution failures. Git Bash runs as a native Windows process, so
   it can call native `.exe` files directly with no such risk. `navigator`/Docker commands themselves
   work fine from either shell — it's specifically the Glide-calling step that needs Git Bash.
4. **`$SCHRODINGER`**, set to the native Windows path in Git Bash's path form, e.g.:
   ```bash
   export SCHRODINGER="/c/Program Files/Schrodinger2024-3"
   ```

### Known gotchas

- **Docker Desktop's WSL integration sometimes doesn't activate on the first toggle.** If `docker` isn't
  found inside your distro or Git Bash after enabling it, do a *full* Docker Desktop restart — quit it
  entirely from the system tray (not just close the window) — then relaunch and retry.
- **`conda activate` fails with "Run 'conda init' before 'conda activate'"** even right after running
  `conda init`. Conda's hook only loads in a *fresh* terminal window — for PowerShell/cmd, just reopen
  the window. **For Git Bash specifically**, this isn't enough on its own: `conda init` hooks
  `~/.bashrc`, but Git Bash's login-shell startup reads `~/.bash_profile`, which doesn't source
  `~/.bashrc` by default. Fix once with:
  ```bash
  echo 'source ~/.bashrc' >> ~/.bash_profile
  ```
- **Plain `Ctrl+C`/`Ctrl+V` don't work as copy/paste in Git Bash** by default — `Ctrl+C` is reserved to
  send an interrupt signal, standard terminal behavior. Right-click pastes clipboard content directly
  (always works); selecting text often auto-copies. `Ctrl+Shift+C`/`Ctrl+Shift+V` may also work, and the
  behavior can be changed in the window's Options if you prefer plain Ctrl+C/V.
- **A fresh `git clone` needs its own license installed.** `install_navigator.sh` seeds an *empty*
  placeholder `license.json` — if you clone into a new directory, you'll need to
  `navigator update-license <path-to-your-license.json>` there too, even if you already activated a
  license in another checkout on the same machine.

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

### Alternative: keep the key in a secret manager

If your policy forbids plaintext keys in `~/.aws/credentials`, skip
`aws configure` entirely. `navigator login` honors the standard AWS environment
variables, so any secret manager that can inject `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` into a single command's environment works — the key is
read once for the role assumption and never written to disk.

**1Password CLI:**

```bash
cat > navigator-login.env <<'EOF'
AWS_ACCESS_KEY_ID="op://<vault>/<item>/access key id"
AWS_SECRET_ACCESS_KEY="op://<vault>/<item>/secret access key"
EOF
op run --env-file navigator-login.env -- navigator login
```

(The `op://` references are pointers, not secrets — the file is safe to keep.
If your item title contains characters `op` rejects in references, use the
vault/item UUIDs instead of names.)

**HashiCorp Vault / `pass` / anything with a CLI read:**

```bash
AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key_id secret/dmc-navigator)" \
AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_access_key secret/dmc-navigator)" \
navigator login
```

**Persistent profile without a plaintext file** — if you prefer a normal
`AWS_PROFILE` workflow, `credential_process` makes the AWS CLI ask your secret
manager on demand instead of reading `~/.aws/credentials`. In `~/.aws/config`:

```ini
[profile dmc-navigator-source]
credential_process = /usr/local/bin/dmc-navigator-creds
```

where the script prints `{"Version": 1, "AccessKeyId": "...", "SecretAccessKey": "..."}`
populated from your secret manager. Then `AWS_PROFILE=dmc-navigator-source navigator login`
works as in the standard flow.

In every variant, the only thing that reaches Docker is the ECR token, which
expires after 12 hours. If you also want *that* out of
`~/.docker/config.json`, configure a
[Docker credential helper](https://docs.docker.com/engine/reference/commandline/login/#credential-stores)
— it is optional and independent of `navigator login`.

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

### Available databases

`navigator data catalog` is always the authoritative list — it reflects what
*your* licence is entitled to. The table below maps each curated space to the
name you pass on the command line, the release you download from AWS, and the
equivalent BioSolveIT `.space` file, so you can line our spaces up against an
existing SpaceHASTEN/infiniSee setup.

The **CLI name** column is what you pass to both `navigator data install` and
`--database`. `data install` accepts the bare id (resolving to the latest
release); `init` and `random` need the fully-qualified `id@release`.

| Space | CLI name (`id@release`) | AWS release object prefix | BioSolveIT `.space` equivalent | Reactions | Synthons | Products |
|---|---|---|---|---:|---:|---:|
| Enamine REAL v5a | `enamine-real-v5a@2026-07-02.1` | `releases/enamine-real-v5a/2026-07-02.1/` | `REALSpace_95bn_2026-04.space` ¹ | 398 | 2,119,892 | 357.4 B ¹ |
| Freedom Space 5 | `freedom-space-5@2026-03-296b.2` | `releases/freedom-space-5/2026-03-296b.2/` | `FreedomSpace_296bn_2026-03.space` | 123 | 1,822,466 | 296.4 B |
| Synple eXplore | `synple-explore-2025-10@2025-10.2` | `releases/synple-explore-2025-10/2025-10.2/` | `eXplore_8tr_2026-06.space` ² | 28 | 1,857,059 | 9.53 T |
| Synple | `synple-synple-2025-10@2025-10.2` | `releases/synple-synple-2025-10/2025-10.2/` | `Synple_8tr_2026-06.space` ² | 49 | 1,227,380 | 7.61 T |
| VAST 2026 H1 | `vast-2026-h1@2026-h1.2` | `releases/vast-2026-h1/2026-h1.2/` | `VAST_4bn_2026-05.space` | 6 | 51,009 | 5.52 B |
| XtalPi VAST (legacy) | `xtalpi-vast-legacy@3p9b.2` | `releases/xtalpi-vast-legacy/3p9b.2/` | superseded by `VAST_4bn_2026-05.space` | 6 | 51,572 | 8.83 B |
| ChemInfinita 2026-02 | `cheminfinita-2026-02@2026-02.1` | `releases/cheminfinita-2026-02/2026-02.1/` | — no BioSolveIT space | 34 | 204,095 | 794.2 B |
| D2B SpaceM1 | `d2b-spacem1@2025-09-24.2` | `releases/d2b-spacem1/2025-09-24.2/` | — no BioSolveIT space | 2 | 99,573 | 1.49 B |

All prefixes are relative to the public release bucket
`s3://dmc-navigator-databases-815935788477/` (`us-east-1`); every object under
them is ciphertext, which is why the bucket can be public. Product counts are
the raw combinatorial product of the synthon positions, *before* any
drug-likeness filtering — the same convention BioSolveIT's file names use, so
the numbers are directly comparable.

¹ **Enamine REAL is our own reconstruction, not the BioSolveIT file.** We rebuild
the v5a reaction subset from Enamine's published synthons; it targets the same
chemistry as `REALSpace_95bn_2026-04.space` but is not byte-equivalent to it, and
its raw product count (357 B) is larger than the vendor's headline 95 B because
BioSolveIT quotes a property-filtered count. Expect comparable but not identical
enumerations.

² Ours is the **2025-10** Synple/eMolecules drop; BioSolveIT's current files are
the 2026-06 vintage. Same spaces, one drop behind — the reaction and synthon
counts will differ slightly from a 2026-06 `.space`.

**Not available yet.** These BioSolveIT spaces have no Navigator equivalent
today: `AuriVerse_5bn_2026-06`, `GalaXi_26bn_2025-09`, `AMBrosia_125bn_2025-07`,
`CHEMriya_55bn_2025-10`, `SAVISpace_7bn_2025-08`, `KnowledgeSpace_262tr_2025-07`.
If you need one of them, ask — the ingestion pipeline is generic and adding a
space is a data job, not a code change.

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
`runs/<run>/pipeline.log`, and lets you pick the strategy (`--method gamma|ga|accurate|fast|all`)
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

## Warm start & enrichment (`navigator warm-start` / `navigator enrich`)

If you already have scored molecules — an old campaign against the same target, an
HTS deck, a set you docked yourself while a run was paused — you can hand them to
Navigator instead of letting it start cold or ignore them.

```bash
# Seed a fresh run before its first propose. Dry-run a big file first: this
# validates and reports, and writes nothing.
navigator warm-start --run-dir runs/hk --scores inputs/seeds.csv --dry-run
navigator warm-start --run-dir runs/hk --scores inputs/seeds.csv

# Pause after round 3, dock some molecules your own way, hand them over, continue.
navigator enrich  --run-dir runs/hk --scores inputs/side_docking.csv
navigator propose --run-dir runs/hk
```

Put the file under `./inputs` (or `./runs`) — those are the directories the
container can see.

### Two modes, and the difference is worth understanding

**`--mode synthon` — recommended.** Your rows carry identifiers that exist in the
database Navigator is screening: a Navigator `product_id` (the `reaction____synthon____synthon`
form written by `navigator random`, by every `proposals.csv`, and by `history.csv`),
or separate `reaction_id` and `synthon_ids` columns. Navigator looks the ids up and
**rebuilds the structure itself**, so those molecules become full members of the
run. They train the ranking model, they count as good starting points to grow
analogues from, their building blocks steer where the search goes next, and
Navigator will never spend budget re-docking one of them.

**`--mode smiles`.** Your rows carry only structures. Navigator cannot place them
in the space, so they can only warm-train the ranking model — they are not starting
points, their building blocks are unknown, and the next `propose` still draws its
own fresh batch. Useful, but materially weaker than the id path. If your molecules
came from a Navigator-supported database, export the ids.

**`--mode auto` (default)** decides per file.

### Budget

These molecules are **charged** to the run's `budget.submitted` by default: 1,000
seeds means 1,000 fewer molecules Navigator will propose. That is the honest
default — you are not getting free oracle calls. Pass `--free` if you already paid
for the docking separately and want the full budget still available.

`navigator status` reports `submitted` (what counts against the budget) alongside
`observations` and `external_observations` so the two never blur.

### Useful flags

| Flag | Effect |
|---|---|
| `--dry-run` | Validate and report; write nothing. Run this first on a large file. |
| `--free` | Do not charge these molecules to the run's budget. |
| `--score-column NAME` | Your score column isn't called `score`. |
| `--label TEXT` | Provenance note recorded with the ingestion. |
| `--allow-unmatched` | Some ids don't resolve: treat just those as structures-only instead of failing the whole file. |
| `--mode synthon\|smiles\|auto` | Override the automatic choice. |

If ids do not resolve, the error names the reason — that almost always means the
file was exported against a **different database or release** than the run is using.

### You will be told if you lose the id path

Ending up in structures-only mode is easy to do by accident and produces no error:
the ingest succeeds, the ranking model is trained, and the summary looks fine —
while the molecules never enter the space. So Navigator warns you when it happens,
naming the cause and what it cost:

```
$ navigator warm-start --run-dir runs/hk --scores inputs/seeds.csv --dry-run
warning: the 'id' column does not hold Navigator product ids, so all 5000 row(s)
took the smiles-only path — they train the ranking surrogate, but they are NOT
placed in the combinatorial space: they never become elites, cannot be
synthon-swapped, do not seed the reaction/synthon distributions, and are not marked
as seen — so the next propose still draws its own pool and may re-dock them at your
expense. Values seen: 'PV-002637465035', 'Z1234567890'. ...
```

The most common cause is exactly that: a file keyed by **vendor catalog ids**
(`PV-…`, `Z…`) rather than by the ids of the synthons the run screens. Those cannot
be resolved. Re-export with the database's own ids and the same file becomes
full-strength evidence. You get the same warnings from `--dry-run`, so check before
committing to a large file.

## Choosing a strategy

The optimizer ships four strategies, selected by the `strategy` field in your
target config (`navigator roster` lists them):

| Preset | Role |
|---|---|
| `gamma_diversity_screening` | **Default.** Broad global discovery — start here (balanced cross-entropy screen). |
| `ga_dcso_v14_screening` | Advanced annealed genetic-algorithm exploration; the complementary GA discovery screen. |
| `analog_harvest_accurate` | Harvest analogs of your best chemotypes, surrogate-ranked (the 'accurate' harvest). |
| `analog_harvest_fast` | The same analog harvest without surrogate re-ranking (the 'fast' harvest; formerly `analog_harvest`, still a deprecated alias). |

Recommended: run `gamma_diversity_screening` first; once you have measured hits,
switch to analog harvesting over the same archive and budget:

```bash
navigator transition --run-dir runs/hk --to analog_harvest_accurate
navigator propose    --run-dir runs/hk
```

The analog-harvest presets report how concentrated their hits are on every
proposal and warn if a campaign narrows to one or two chemotype families.

> **Migration (0.3.0).** `alpha_diversity_screening` (the previous default) was
> retired; use `gamma_diversity_screening`. `beta_diversity_screening` was
> retired; use `ga_dcso_v14_screening`. A config naming a retired preset stops
> with a message naming its replacement — it never silently switches algorithm.

---

## Random sampling (`navigator random`)

Sometimes you want an unbiased random draw from a space rather than an optimized
one — a reference or baseline set to compare a campaign against, a negative
control, a coverage probe, or just a look at what a space actually contains.
`navigator random` does that directly, with no run directory, no target and no
optimizer loop:

```bash
navigator random 10000 --mode rw \
  --database freedom-space-5@2026-03-296b.2 \
  --output sample_10K.csv --seed 0
```

The output is a CSV with two columns, `id` and `smiles`. The `id` is the same
stable product identifier the optimizer uses, so a sample can be joined against
run archives and proposal files.

### Which mode?

`--mode` is required, because the two choices answer different questions and
there is no safe default:

| Mode | Meaning | Use it when |
|---|---|---|
| `pw` — product-weighted | Each **enumerable product** is equally likely. A reaction is drawn with probability proportional to its combinatorial size, then synthons uniformly within it. | You want a genuinely uniform sample *of the space's molecules* — the correct baseline for "what does this space look like". Large reactions dominate, in proportion to how much of the space they actually are. |
| `rw` — reaction-weighted | Each **reaction** is equally likely; a reaction is picked uniformly, then synthons uniformly within it. | You want scaffold/reaction diversity — small reactions get a fair share they would never receive under `pw`. Better for coverage probes and chemotype breadth. |

On a space with uneven reaction sizes the two produce visibly different
reaction-size distributions. That is the point; pick deliberately.

### Options

| Flag | Effect |
|---|---|
| `<N>` (positional) | How many **distinct** molecules to draw. Duplicates are removed, so you get N distinct or a clear `space_saturated` report if the space cannot supply them. |
| `--mode {pw,rw}` | Required. See above. |
| `--database <id@release>` | Which installed space to sample (see [Available databases](#available-databases)). |
| `--output <path>` | CSV to write. Rows stream out as they are drawn, so a large N does not have to fit in memory. |
| `--seed <int>` | Reproducible draws — the same seed, mode and database give byte-identical output. |
| `--filter-profile druglike-v1` | Optional. Applies the same exact drug-likeness / structural-alert gate the optimizer uses, so the sample is drawn from the filtered space rather than the raw one. Off by default: without it, the draw is over the **raw** space and the mode's statistical meaning is exactly as described above. |

Sampling uses the fast uniform draw, not the optimizer's constraint-aware
rejection sampler, so even large N stays quick.

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
| `navigator warm-start --run-dir <run> --scores <csv>` | Seed a fresh run with molecules you scored elsewhere, before its first `propose` |
| `navigator enrich --run-dir <run> --scores <csv>` | Add externally scored molecules to a run already under way (between rounds) |
| `navigator random <N> --mode pw\|rw --output <csv> --database <db>` | Random-sample N molecules from a space to an `id,smiles` CSV (pw = product-weighted, rw = reaction-weighted); optional `--filter-profile druglike-v1`, `--seed` |
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
- **`navigator data install` fails.** First `navigator update` (older images had a
  compatibility bug — fixed in 0.2.6 — that blocked all installs; the error
  mentioned an `rdkit … incompatible` bundle). Installs need a valid license (the
  install key is embedded in it) — check `navigator verify-license`. Each release
  is verified (signature + per-file hashes) before anything is written, so a
  failed/interrupted install leaves nothing partially installed; just re-run it.
  Ensure free disk for the release (e.g. Enamine REAL v5a ≈ 1.1 GB encrypted).
- **GPU / `--gpu` seems to run on CPU.** The surrogate only uses CUDA if the
  container has GPU access. Set `DMC_NAV_GPUS=all` in `.env` (needs an NVIDIA
  driver + the NVIDIA Container Toolkit on the host; see `docker-compose.gpu.yml`).
  Without it, `--gpu` / `surrogate.device=cuda` safely falls back to CPU.
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
