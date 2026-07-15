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
- **Property filter.** The config's `space.property_constraints` is the
  additive (generation-time) drug-like prefilter — approximate by design.
  Reactive-group / exact-structure exclusions are left to your scoring step.

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
