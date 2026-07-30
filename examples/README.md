# DMC Navigator — worked examples (Glide docking on Freedom Space)

One command screens a make-on-demand chemical space against a target with
**your own Glide**, running the resumable `propose → dock → ingest` loop for a
fixed number of iterations. Everything here is customer-facing: the optimizer
runs in the licensed container; docking runs on your host in your Schrödinger
environment (Schrödinger is never inside the image).

Three worked targets are wired end-to-end — **KIF11**, **PYRD**, **TGFR1** —
each with a real example Glide grid and the same drug-like property filter and
per-target hit threshold we use internally.

## TL;DR

```bash
# from the repo root, after: install → login → pull → update-license → data install
export SCHRODINGER=/opt/schrodinger2026-1              # your install
examples/run_navigator.sh TGFR1                        # gamma, 100k budget, 10 rounds, Glide
```

## Prerequisites

1. `navigator` installed and the image pulled (`./install_navigator.sh`,
   `navigator login`, `navigator pull`).
2. A valid license activated (`navigator update-license …`, `navigator verify-license`).
3. The database installed once:
   ```bash
   navigator data install freedom-space-5          # ~1.8M synthons, encrypted; decrypts locally
   ```
4. For real docking, `SCHRODINGER` pointing at your install (Glide + LigPrep).
   No Schrödinger? Use `--scorer mock` to watch the loop turn (a stand-in score,
   not chemistry).

## Windows

Run this script from **Git Bash** (see the top-level README's "Running on Windows" section for
setup), not WSL2 — Git Bash is a native Windows process and can call your Schrodinger install
(`glide.exe`/`ligprep.exe`) directly; WSL2 is a separate Linux VM and risks path/extension mismatches
when calling native Windows executables across that boundary.

```bash
export SCHRODINGER="/c/Program Files/Schrodinger2024-3"   # your install, Git Bash path form
examples/run_navigator.sh TGFR1
```

`navigator`/Docker commands themselves work fine from either Git Bash or WSL2 (Docker Desktop exposes
`docker`/`docker compose` to both) — it's specifically the Glide-calling step inside `run_navigator.sh`
that needs to run as a native Windows process.

Windows executable naming (`glide.exe`/`ligprep.exe` vs. the extensionless Linux/Mac launchers) and the
`python3` vs. `python` naming difference are both already handled automatically by the script — no
action needed for either.

## The one command

```
examples/run_navigator.sh <TARGET> [options]
```

| Option | Values | Default | Meaning |
|---|---|---|---|
| `<TARGET>` | `KIF11` `PYRD` `TGFR1` | — | which `examples/configs/<TARGET>.json` |
| `--method` | `gamma` `alpha` `beta` `analog` `all` | `gamma` | strategy (or all four) |
| `--budget` | `10k` `100k` `1m` or an integer | `100k` | total molecules docked |
| `--iters` | integer | `10` | propose/dock/ingest rounds (batch = budget ÷ iters) |
| `--database` | `db@release` | `freedom-space-5@2026-03-296b.2` | installed release to screen |
| `--scorer` | `glide` `mock` | `glide` | real Glide, or the no-Schrödinger stand-in |
| `--pool` | integer | `20000` | surrogate candidate-pool per round |
| `--gpu` | flag | off | XGBoost surrogate on CUDA (falls back to CPU if absent) |
| `--precision` | `HTVS` `SP` `XP` | `HTVS` | Glide precision (overrides docking_settings) |
| `--status` | flag | — | print status of this target's runs and exit |

### Examples

```bash
examples/run_navigator.sh TGFR1                          # default: gamma, 100k, Glide HTVS
examples/run_navigator.sh KIF11 --budget 10k --gpu       # quick 10k run, GPU surrogate
examples/run_navigator.sh PYRD  --method all             # gamma+alpha+beta+analog, separate runs
examples/run_navigator.sh TGFR1 --scorer mock --budget 200 --iters 2   # smoke, no Schrödinger
examples/run_navigator.sh KIF11 --database enamine-real-v5a@2026-07-02.1  # a different space
```

## What it does

Each round: the container **proposes** a batch (surrogate-guided, diversity-aware),
you **dock** it with Glide on the host, the container **ingests** the scores and
refits — for `--iters` rounds. State lives in `runs/<target>_<method>_<budget>_<scorer>/`.

- **Resumable.** Re-run the *exact same command* to continue after a Ctrl-C,
  reboot, or spot reclaim — nothing already docked is re-docked, and a batch that
  was proposed but not yet scored is recovered automatically.
- **Compiled logs.** Progress prints one clean line per phase and is appended to
  `runs/<run>/pipeline.log`; the optimizer prints single-line errors by design.
  Set `DMC_NAV_DEBUG=1` in `.env` only when you need full tracebacks.
- **Property filter (0.3.0).** Two layers, both configured here. The config's
  `space.property_constraints` is the additive, generation-time drug-like
  prefilter — approximate by design, it only biases what gets built. The
  authority is `space.exact_filter_profile` (`"druglike-v1"` in these configs):
  every assembled molecule is re-checked against the full property window **and**
  the reactive-group / structural-alert exclusions before the proposal file is
  written, whichever internal operator produced it. So nothing out-of-window or
  alerting reaches your docking step, and rejects cost you no budget. Earlier
  versions of this note said the exact exclusions were left to your scoring step;
  that was true before 0.3.0 and is not any more.

## A random baseline to compare against (0.3.0)

A campaign's numbers only mean something next to a baseline. `navigator random`
draws molecules from the same space with no optimization at all, so you can dock
a random set through the identical Glide setup and see what the search actually
bought you:

```bash
# 10k random drug-like molecules from the same space the KIF11 config screens
navigator random 10000 --mode pw \
  --database freedom-space-5@2026-03-296b.2 \
  --filter-profile druglike-v1 \
  --output runs/random_baseline.csv --seed 0
```

Use `--mode pw` for a baseline: it makes every *molecule* in the space equally
likely, which is the honest "what would picking at random have given me" control.
`--mode rw` makes every *reaction* equally likely instead — better when you want
scaffold breadth rather than a fair baseline. Add `--filter-profile druglike-v1`
so the baseline is drawn from the same filtered chemistry your run proposes from;
without it you are comparing against the raw space and the comparison flatters
the optimizer.

The output is an `id,smiles` CSV. `scoring/glide_batch.py` expects the proposal
schema rather than this one, so add the `batch_id`/`status` columns (or dock the
SMILES directly with your own Glide call) before feeding it through.

## Warm-starting a campaign with molecules you already scored

`navigator warm-start` hands a fresh run a set of scored molecules so its first
`propose` is already informed, and `navigator enrich` does the same for a run
that is already under way. Full explanation of the two modes and the budget rule
is in the top-level README; here is how the pieces in this directory fit together.

**Where the seed molecules come from matters.** If they carry ids from the
database the run is screening, Navigator can rebuild their structures and they
become full members of the run — proper starting points for analogue growth, with
their building blocks steering the search. If they are only structures, they can
warm-train the ranking model and nothing more. Export the ids where you have them.

### Building a seed set from scratch with your own Glide

```bash
DB=freedom-space-5@2026-03-296b.2

# 1. Draw a seed pool from the same space (and same filter) the run screens.
navigator random 5000 --mode pw --database "$DB" \
  --filter-profile druglike-v1 --output inputs/seed_pool.csv --seed 0

# 2. glide_batch.py expects a `product_id` column; `random` writes `id`. Rename it.
#    (These ARE the space's ids, which is what makes the warm start full-strength.)
sed '1s/^id,/product_id,/' inputs/seed_pool.csv > inputs/seed_proposals.csv

# 3. Dock the seed pool with the same Glide setup the campaign uses.
"$SCHRODINGER/run" python3 examples/scoring/glide_batch.py \
  --proposals inputs/seed_proposals.csv --out inputs/seed_scores.csv \
  --docking-settings examples/docking/docking_settings.json --target TGFR1

# 4. Check it before committing to it, then seed the run.
navigator init       --run-dir runs/tgfr1_warm --config-json inputs/TGFR1.json --overwrite
navigator warm-start --run-dir runs/tgfr1_warm --scores inputs/seed_scores.csv --dry-run
navigator warm-start --run-dir runs/tgfr1_warm --scores inputs/seed_scores.csv \
  --label "random-pw-5k-seed"

navigator status --run-dir runs/tgfr1_warm   # submitted: 5000 of your budget
```

`glide_batch.py` writes `batch_id,product_id,status,score,…`, which is exactly the
schema `warm-start` reads — including `status`, so seeds Glide could not pose are
counted without becoming misleading training labels, the same as in a normal round.

Note step 4's effect on the budget: those 5,000 docks are **charged**, so the run
proposes 5,000 fewer molecules of its own. That is deliberate — it keeps a
warm-started run and a cold run comparable at equal oracle cost. Pass `--free` if
you want the full budget on top of the seeds instead.

### Pausing a campaign to add your own molecules

`run_navigator.sh` runs to completion, so drive the loop manually (top-level
README, "Manual loop") when you want to break in partway:

```bash
# ... after three propose/dock/ingest rounds on runs/tgfr1 ...
navigator status --run-dir runs/tgfr1          # pending_batch_id must be null

# Dock your own picks however you like, then hand them over.
navigator enrich --run-dir runs/tgfr1 --scores inputs/my_round3_picks.csv \
  --label "medchem-picks-round3"
navigator propose --run-dir runs/tgfr1         # next batch sees them
```

`enrich` refuses while a batch is awaiting scores — ingest that batch first. New
evidence is tagged as available from the round about to be proposed, never
backdated, so the run's history stays an honest record of what was known when.

## Bring your own target

Copy a config, point `space.database` at your installed release (or your own
`space.reactions_path`/`synthons_path` under `./inputs`), set `objective`, and
drop your Glide grid into `examples/docking/` with a matching
`docking_settings.json` entry. `glide_batch.py` is yours to adapt to your site's
Glide/scheduler — the optimizer only consumes the returned
`batch_id,product_id,status,score` CSV.

## Files

| Path | Role |
|---|---|
| `run_navigator.sh` | the one-command pipeline (host orchestrator) |
| `configs/{KIF11,PYRD,TGFR1}.json` | per-target run configs (Freedom + property filter + gamma) |
| `docking/docking_settings.json` | per-target Glide grid / precision / pH |
| `docking/glide-grid_*.zip`, `glide-dock_*.in` | example grids (replace with your own) |
| `scoring/glide_batch.py` | your Glide adapter (LigPrep+Epik → Glide → scores); resume-safe |
| `scoring/mock_score.py` | dependency-free stand-in scorer (smoke only) |
