#!/usr/bin/env bash
# =============================================================================
# DMC Navigator — one-command example pipeline (customer-facing)
# =============================================================================
# Runs the full resumable screen for one target: it drives the licensed
# container through the propose -> dock -> ingest loop, docking each batch with
# YOUR OWN Glide install on the host (Schrodinger is never inside the image),
# for a fixed number of iterations (default 10) at a chosen budget.
#
# It is fully resumable: re-run the exact same command to continue an
# interrupted campaign (Ctrl-C, reboot, or spot reclaim) — nothing is re-docked.
#
#   examples/run_navigator.sh <TARGET> [options]
#
#   <TARGET>            KIF11 | PYRD | TGFR1   (an examples/configs/<TARGET>.json)
#
# Options (env vars or flags):
#   --method  M   gamma (default) | alpha | beta | analog | all | <preset-name>
#   --budget  B   10k | 100k (default) | 1m | <integer>     total molecules docked
#   --iters   N   number of propose/dock/ingest rounds (default 10)
#   --database S  installed release selector (default freedom-space-5@2026-03-296b.2)
#   --scorer  S   glide (default; needs $SCHRODINGER) | mock (no-Schrodinger smoke)
#   --scorer-cmd "<cmd>"  bring-your-own docking: a command that will be called as
#                 <cmd> --proposals <csv> --out <csv> --target <T> [--precision P]
#                 and must write the batch_id,product_id,status,score CSV. Overrides
#                 --scorer (use for your own docking engine / scheduler).
#   --pool    N   surrogate candidate-pool size per round (default 20000)
#   --gpu         run the XGBoost surrogate on CUDA (falls back to CPU if absent)
#   --precision P HTVS (default) | SP | XP   (Glide precision, overrides settings)
#   --status      print status for the target's runs and exit
#   -h|--help
#
# Examples:
#   examples/run_navigator.sh TGFR1                         # gamma, 100k, Glide
#   examples/run_navigator.sh KIF11 --budget 10k --gpu      # quick GPU run
#   examples/run_navigator.sh PYRD  --method all            # all 4 strategies
#   examples/run_navigator.sh TGFR1 --scorer mock --budget 200 --iters 2  # smoke
#
# Prerequisites: `navigator` installed (install_navigator.sh) with the image
# pulled and a valid license; the target's database installed
# (`navigator data install freedom-space-5`). Glide runs need $SCHRODINGER set.
# =============================================================================
set -euo pipefail

# ---- locate the repo (this script lives in <repo>/examples) -----------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

# `navigator` on PATH, or the installed bin, or an explicit override.
NAV="${NAVIGATOR_BIN:-}"
if [ -z "$NAV" ]; then
  if command -v navigator >/dev/null 2>&1; then NAV="navigator"
  elif [ -x "$HOME/.local/bin/dmc-navigator/navigator" ]; then NAV="$HOME/.local/bin/dmc-navigator/navigator"
  else echo "error: 'navigator' not found on PATH. Run ./install_navigator.sh and open a new shell." >&2; exit 1
  fi
fi

# ---- defaults / arg parsing -------------------------------------------------
TARGET=""
METHOD="${METHOD:-gamma}"
BUDGET="${BUDGET:-100k}"
ITERS="${ITERS:-10}"
DATABASE="${DATABASE:-freedom-space-5@2026-03-296b.2}"
SCORER="${SCORER:-glide}"
SCORER_CMD="${SCORER_CMD:-}"
POOL="${POOL:-20000}"
GPU="${GPU:-0}"
PRECISION="${PRECISION:-}"
STATUS_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    KIF11|PYRD|TGFR1|kif11|pyrd|tgfr1) TARGET="$(echo "$1" | tr a-z A-Z)"; shift ;;
    --method)    METHOD="$2"; shift 2 ;;
    --budget)    BUDGET="$2"; shift 2 ;;
    --iters)     ITERS="$2"; shift 2 ;;
    --database)  DATABASE="$2"; shift 2 ;;
    --scorer)    SCORER="$2"; shift 2 ;;
    --scorer-cmd) SCORER_CMD="$2"; shift 2 ;;
    --pool)      POOL="$2"; shift 2 ;;
    --gpu)       GPU=1; shift ;;
    --precision) PRECISION="$2"; shift 2 ;;
    --status)    STATUS_ONLY=1; shift ;;
    -h|--help)   sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

[ -n "$TARGET" ] || { echo "error: TARGET required (KIF11|PYRD|TGFR1). See --help." >&2; exit 2; }
BASE_CFG="$REPO/examples/configs/${TARGET}.json"
[ -f "$BASE_CFG" ] || { echo "error: no config for target '$TARGET' at $BASE_CFG" >&2; exit 2; }

# ---- resolve budget -> label + integer, batch = budget/iters ----------------
case "$BUDGET" in
  10k|10K)   BUDGET_N=10000;   BLABEL=10k ;;
  100k|100K) BUDGET_N=100000;  BLABEL=100k ;;
  1m|1M)     BUDGET_N=1000000; BLABEL=1m ;;
  *) case "$BUDGET" in ''|*[!0-9]*) echo "error: --budget must be 10k|100k|1m or an integer" >&2; exit 2 ;; esac
     BUDGET_N="$BUDGET"; BLABEL="$BUDGET" ;;
esac
case "$ITERS" in ''|*[!0-9]*) echo "error: --iters must be an integer" >&2; exit 2 ;; esac
[ "$ITERS" -ge 1 ] || { echo "error: --iters must be >= 1" >&2; exit 2; }
BATCH=$(( BUDGET_N / ITERS ))
[ "$BATCH" -ge 1 ] || BATCH="$BUDGET_N"

# ---- resolve method(s) ------------------------------------------------------
map_method() {
  case "$1" in
    gamma)   echo gamma_diversity_screening ;;
    alpha)   echo alpha_diversity_screening ;;
    beta)    echo beta_diversity_screening ;;
    analog)  echo analog_harvest ;;
    *)       echo "$1" ;;   # already a full preset name
  esac
}
if [ "$METHOD" = "all" ]; then
  METHODS=(gamma_diversity_screening alpha_diversity_screening beta_diversity_screening analog_harvest)
else
  METHODS=("$(map_method "$METHOD")")
fi

# ---- device / scorer sanity -------------------------------------------------
if [ "$GPU" = "1" ]; then DEVICE=cuda; else DEVICE=cpu; fi
if [ -z "$SCORER_CMD" ] && [ "$SCORER" = "glide" ] && [ "$STATUS_ONLY" != "1" ]; then
  : "${SCHRODINGER:?SCHRODINGER is not set. Point it at your Schrodinger install for Glide, or use --scorer mock.}"
  [ -x "$SCHRODINGER/glide" ] || { echo "error: \$SCHRODINGER/glide not found ($SCHRODINGER/glide)" >&2; exit 1; }
fi

# =============================================================================
# helpers
# =============================================================================
nav() { "$NAV" "$@"; }

# status field, tolerant of the intentional non-zero exit on false/empty fields.
field() { nav status --run-dir "$1" --field "$2" 2>/dev/null || true; }

# Render the effective run config from the base template + runtime overrides,
# using only the standard library. Writes to $1.
render_config() {
  local out="$1" strategy="$2"
  python3 - "$BASE_CFG" "$out" "$strategy" "$BUDGET_N" "$BATCH" "$POOL" "$DEVICE" "$DATABASE" <<'PY'
import json, sys
base, out, strategy, budget, batch, pool, device, database = sys.argv[1:9]
cfg = json.load(open(base))
cfg["strategy"] = strategy
cfg["budget"] = {"submitted": int(budget), "batch_size": min(int(batch), int(budget))}
cfg["candidate_pool_size"] = max(int(pool), int(batch))
cfg.setdefault("surrogate", {})
cfg["surrogate"]["device"] = device
cfg["surrogate"]["allow_cpu_fallback"] = True  # keep runs safe on CPU-only hosts
cfg.setdefault("space", {})["database"] = database
json.dump(cfg, open(out, "w"), indent=2)
PY
}

# Dock one proposal batch on the host. $1 = relative proposal .parquet path.
# Writes the scores CSV and echoes its RELATIVE path (for `navigator ingest`).
dock_batch() {
  local prop_parquet="$1"
  local pdir base iter prop_csv scores_rel scores_abs
  pdir="$(dirname "$prop_parquet")"                       # runs/<run>/proposals
  base="$(basename "$prop_parquet")"                      # iteration_NNNN_proposals.parquet
  iter="${base%_proposals.parquet}"                       # iteration_NNNN
  prop_csv="${pdir}/${iter}_proposals.csv"                # navigator writes this too
  scores_rel="$(dirname "$pdir")/scores/${iter}_scores.csv"
  scores_abs="$REPO/$scores_rel"
  mkdir -p "$(dirname "$scores_abs")"
  local extra=()
  [ -n "$PRECISION" ] && extra+=(--precision "$PRECISION")
  if [ -n "$SCORER_CMD" ]; then
    # Bring-your-own docking: <cmd> --proposals <csv> --out <csv> --target <T> [--precision P]
    local cmd_arr=()
    read -r -a cmd_arr <<< "$SCORER_CMD"
    "${cmd_arr[@]}" \
      --proposals "$REPO/$prop_csv" --out "$scores_abs" --target "$TARGET" \
      "${extra[@]}" >>"$LOG" 2>&1
  elif [ "$SCORER" = "glide" ]; then
    "$SCHRODINGER/run" python3 "$REPO/examples/scoring/glide_batch.py" \
      --proposals "$REPO/$prop_csv" --out "$scores_abs" \
      --docking-settings "$REPO/examples/docking/docking_settings.json" --target "$TARGET" \
      "${extra[@]}" >>"$LOG" 2>&1
  else
    python3 "$REPO/examples/scoring/mock_score.py" \
      --proposals "$REPO/$prop_csv" --out "$scores_abs" >>"$LOG" 2>&1
  fi
  echo "$scores_rel"
}

# One target+method campaign.
run_campaign() {
  local strategy="$1"
  local mshort="${strategy%%_*}"                          # gamma/alpha/beta/analog
  local run="runs/$(echo "$TARGET" | tr A-Z a-z)_${mshort}_${BLABEL}_${SCORER}"
  mkdir -p "$REPO/$run"
  LOG="$REPO/$run/pipeline.log"

  if [ "$STATUS_ONLY" = "1" ]; then
    echo "== $TARGET / $strategy =="; nav status --run-dir "$run" 2>/dev/null || echo "  (no run yet at $run)"
    return 0
  fi

  log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

  log "campaign start: target=$TARGET strategy=$strategy budget=$BUDGET_N batch=$BATCH iters=$ITERS pool=$POOL device=$DEVICE scorer=$SCORER db=$DATABASE"

  die() { log "ERROR: $1 — see $run/pipeline.log (set DMC_NAV_DEBUG=1 in .env for full detail)"; exit 1; }

  # Init a fresh run, or resume an existing one (config carries over).
  if [ -f "$REPO/$run/config.json" ]; then
    log "resuming existing run at $run"
  else
    render_config "$REPO/$run/effective_config.json" "$strategy" || die "could not render config"
    nav init --run-dir "$run" --config-json "$run/effective_config.json" >>"$LOG" 2>&1 || die "init failed"
    log "initialized $run"
  fi

  # Resume a mid-dock interruption: a batch awaiting scores must be docked+ingested first.
  local pending
  pending="$(field "$run" pending_batch_id)"
  if [ -n "$pending" ] && [ "$pending" != "None" ]; then
    local lastprop scores
    lastprop="$(field "$run" last_proposal_file)"
    log "recovering pending batch $pending (re-docking $lastprop)"
    scores="$(dock_batch "$lastprop")" || die "docking failed while recovering pending batch"
    nav ingest --run-dir "$run" --scores "$scores" >>"$LOG" 2>&1 || die "ingest failed while recovering pending batch"
    log "recovered pending batch"
  fi

  # Main loop: propose -> dock -> ingest until the budget is spent.
  local it=0
  while [ "$(field "$run" can_propose)" = "True" ]; do
    local prop scores
    prop="$(nav propose --run-dir "$run" 2>>"$LOG")" || die "propose failed"
    log "iteration proposal: $prop"
    scores="$(dock_batch "$prop")" || die "docking failed"
    nav ingest --run-dir "$run" --scores "$scores" >>"$LOG" 2>&1 || die "ingest failed"
    log "ingested: submitted=$(field "$run" submitted) valid=$(field "$run" valid) hits=$(field "$run" hits)"
    it=$((it + 1))
    if [ "$it" -gt $(( ITERS + 5 )) ]; then log "safety stop after $it rounds"; break; fi
  done

  log "campaign complete"
  nav status --run-dir "$run" | tee -a "$LOG"
  echo "   log: $run/pipeline.log"
}

# =============================================================================
for strategy in "${METHODS[@]}"; do
  run_campaign "$strategy"
done
