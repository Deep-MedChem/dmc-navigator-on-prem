# Warm start and mid-run enrichment

For a step-by-step workflow, see [Custom seeds](CUSTOM_SEEDS.md): validate before
docking, map vendor/release IDs, and import existing scores (0.5.0+).

Navigator's contract with the oracle is a strict barrier: it proposes a batch, you
score exactly that batch, it ingests exactly that batch. Two things a real campaign
needs do not fit through that barrier.

**Warm start.** You already have scored molecules — an HTS deck, a prior campaign
against the same target, a supplied seed set — and want round 0 to begin informed
instead of drawing at random.

**Enrichment.** You paused after round *k*, docked some molecules on the side or
with a different method, and want that evidence in before round *k+1*.

Both are the same operation at two points in a campaign's life, so they are one
implementation (`api/external.py`) with two commands.

| | `warm-start` | `enrich` |
|---|---|---|
| when | fresh run, nothing observed yet | between rounds, no batch awaiting scores |
| rows tagged | `iteration = -1` | `iteration = <last completed round>` |
| refuses | a run that already has observations | a run mid-barrier |

The separation is not cosmetic. `warm-start` asserts a virgin run, so you cannot
tag mid-campaign evidence as if it had been there from the start — which would
make a gamma/CEM replay reconstruct a history that never happened.

---

## The two modes, and why the difference matters

### `--mode synthon` — recommended

The rows carry identifiers that resolve **inside the space**:

* a Navigator `product_id` — `reaction____synthon1____synthon2`, exactly the form
  `navigator random`, `proposals.csv`, and `history.csv` emit; or
* explicit `reaction_id` + `synthon_ids` (pipe-joined) columns.

Navigator resolves each id against the loaded release, then **assembles the SMILES
itself**. It does not take your word for the structure: if the file also carries a
`smiles` column, it is canonicalized and compared, and a disagreement fails the
ingest (`--allow-conflict` trusts the ids and discards the supplied structure).
That way the molecule Navigator learns from is a molecule Navigator can build.

A resolved row is written straight into `history.parquet` and is **first-class
evidence** from that point on — downstream code cannot tell it from an oracle row:

* it trains the surrogate through the exact synthon-OR feature path;
* it becomes an elite, and its synthons are available for swapping;
* its reaction and per-slot synthons feed the CEM / GA distributions;
* its `product_id` is marked **seen**, so Navigator never spends budget
  re-proposing a molecule you already scored.

This is what a warm start is supposed to buy, and it needs ids.

### `--mode external` / `--mode smiles` — the fallback

The rows carry only a structure and a score. Nothing can be resolved, so these
rows **do not enter the archive**. They go to `external/smiles_train.parquet` and
are appended to the surrogate's training rows and nothing else.

Concretely, what you get and what you do not:

| | `synthon` | `smiles` |
|---|---|---|
| trains the surrogate | ✅ | ✅ |
| becomes an elite | ✅ | ❌ |
| available for synthon swapping | ✅ | ❌ |
| seeds the CEM / GA distributions | ✅ | ❌ |
| marked seen (never re-proposed) | ✅ | ❌ |
| can be charged to the budget | ✅ | ✅ |

So the first `propose` after a smiles-only warm start still draws its own round-0
pool exactly as a cold run would — the surrogate ranking that pool is simply no
longer naive. Nothing about the *space* has been seeded, because nothing about the
space is known.

There is a second, much smaller effect. Every pool candidate is featurized as a
**synthon-OR** Morgan print — per-synthon prints OR-ed across slots. A smiles-only
row has no synthons, so it is featurized as a **whole-molecule** Morgan print at
the same radius and width. Because a synthon-OR print is the print of the
disconnected fragments, every environment away from a junction is shared and the
two overlap heavily; what differs is the junction environments plus, under the
default `space.strip_connectors = false`, the connector-atom (`[U]`/`[Np]`)
environments. Setting `strip_connectors = true` closes most of the remainder. The
round's telemetry records `external.mixed_feature_representations` and
`external.strip_connectors` so this is auditable, but it is not the reason to
prefer the id path — the reason is the table above.

### `--mode auto` (default)

Picks per file: `synthon` if there are `reaction_id` + `synthon_ids` columns, or if
**every** non-empty id in the id column carries the `____` separator. Otherwise
`smiles`. The "every" is deliberate — a file where only some ids look like product
ids is a mixed or renamed export, and splitting it row-by-row would silently treat
half of it one way and half the other.

### Warnings

Landing on the smiles-only path is a **silent** loss of capability: the ingest
succeeds, the surrogate is trained, and the summary looks healthy — while the
molecules never enter the space at all. Nothing errors, so nothing would tell you.

So the ingest diagnoses it and says so, in `summary["warnings"]`, in the ingest
manifest, and on stderr as `warning:` lines. Three cases are named:

| Situation | What the warning says |
|---|---|
| an id column exists but holds something else (typically vendor catalog ids like `PV-002637465035`) | which column, three example values, what a Navigator product id looks like, and where to get them |
| no id column at all | add `product_id`, or `reaction_id` + `synthon_ids`, if these molecules came from the screened database |
| `--allow-unmatched` demoted rows whose ids did not resolve | how many, plus the likely cause — a file exported against a different database or release |

Every one of them quotes the same consequence, because that is the part that
matters: these rows *train the surrogate*, but they never become elites, cannot be
synthon-swapped, do not seed the reaction/synthon distributions, and are not marked
seen — so the next `propose` may re-dock them at your expense.

`--dry-run` produces the same warnings without writing anything, which is the
cheap way to find out which path a file will take before committing to it.

---

## Budget

External molecules are **charged** to `budget.submitted` by default. A warm start
is evidence somebody paid an oracle for, and exempting it silently turns any
budget-matched comparison into a head start — the exact hazard the benchmark
harness's fairness ledger (`dmc-navigator-orion`, `docs/04_FAIRNESS.md` §2 "The
oracle budget") is written to prevent. `N` charged seeds buy `N` fewer proposals;
a warm-started arm and a cold arm spend the same number of oracle calls.

Pass `--free` when that is not what you are measuring — a customer who already
docked those molecules on their own time and simply wants Navigator to know about
them. `status` reports both numbers so the two never blur:

| field | meaning |
|---|---|
| `submitted` | budget-facing: charged rows only. Gates `can_propose`. |
| `observations` | every row in the archive, charged or free |
| `external_observations` | archive rows that came from `warm-start` / `enrich` |
| `external_ingests` | one record per ingestion (batch id, mode, counts, file SHA-256) |

On a run with no external evidence all three collapse to today's numbers, so
nothing an existing driver reads changes.

---

## Guarantees

* **Total resolution.** An id resolves only if the reaction exists, the tuple has
  one id per slot, and every id is listed for its slot. A near miss is reported
  with its reason. An explicit `--id-map` can translate known identities from
  another database/release, with the supplied structure checked by reassembly.
* **Strict assembly/structure checks.** Assembly failures fail the entire synthon
  import. Invalid or conflicting supplied SMILES also fail unless `--allow-conflict`
  explicitly trusts the IDs (unavailable with `--id-map`).
* **No double counting.** The source file's SHA-256 is recorded; re-ingesting the
  same file is refused (`--force` overrides). Independently, a product already in
  the archive is skipped, so even a forced re-ingest cannot re-charge it. The
  run's own measurement of a product always wins over a later file's.
* **No structure counted twice.** The smiles-only store is keyed on canonical
  SMILES; the same molecule written two ways is stored and charged once.
* **Nothing crosses an open barrier.** Both commands refuse while a batch is
  awaiting scores.
* **Determinism is unaffected.** External evidence changes the archive, not the
  run identity (seed / schema / objective direction / space), so the resume guard
  still passes and `propose` remains a pure function of
  `(archive, seed, iteration)`.

---

## Filter gate

When the run sets `space.exact_filter_profile`, incoming molecules are evaluated
against it and the pass fraction is reported in the summary and the ingest
manifest — but **nothing is dropped**. Discarding evidence you already paid for is
the wrong default. Pass `--drop-gate-failures` to enforce it, which is the right
call when you need the elite set to contain only molecules Navigator itself would
have been permitted to propose.

---

## Usage

```bash
# Always dry-run a large file first: validates and reports, writes nothing.
dmc-navigator-prod warm-start --run-dir runs/tgfr1 --scores seeds.csv --dry-run

# Full-strength warm start from ids.
dmc-navigator-prod warm-start --run-dir runs/tgfr1 --scores seeds.csv \
    --label "prior-campaign-2026Q1"

# Structures only, not charged to this run's oracle budget.
dmc-navigator-prod warm-start --run-dir runs/tgfr1 --scores hts_deck.csv \
    --mode smiles --free

# Pause after round 3, dock on the side, hand the results over, continue.
dmc-navigator-prod enrich --run-dir runs/tgfr1 --scores side_docking.csv \
    --label "manual-round-3"
dmc-navigator-prod propose --run-dir runs/tgfr1
```

### Input file

CSV, TSV, or parquet. One required column plus whatever mode you are in:

| Column | Required | Notes |
|---|---|---|
| `score` | yes | numeric for `valid` rows; rename via `--score-column` |
| `product_id` / `navigator_id` / `id` | synthon mode | the Navigator product id |
| `reaction_id` + `synthon_ids` | synthon mode (alt.) | `synthon_ids` pipe-joined |
| `smiles` | smiles mode | verified against the ids when both are present |
| `status` | no | `valid` (default), `failed`, `timeout`, `filtered`, `cancelled` |

A `valid` row with no finite score is rejected. Mark it `failed` instead and it is
counted for budget without becoming a training label — the same policy the normal
`ingest` applies, including the run's `penalty_mode` and any oracle sentinel guard.

### Flags

| Flag | Effect |
|---|---|
| `--mode auto\|synthon\|smiles\|external` | see above; default `auto` |
| `--id-map PATH` | verified `external_id,product_id` crosswalk; mapped rows require matching supplied SMILES |
| `--score-column NAME` | column holding the measured value (default `score`) |
| `--free` | do not charge these molecules to `budget.submitted` |
| `--label TEXT` | free-text provenance tag recorded in the manifest |
| `--allow-unmatched` | demote unresolvable rows to the smiles path instead of failing |
| `--allow-conflict` | trust the ids when a supplied SMILES disagrees |
| `--drop-gate-failures` | drop molecules failing `space.exact_filter_profile` |
| `--dry-run` | validate and report; write nothing |
| `--force` | re-ingest a file already ingested into this run |

---

## On disk

```text
runs/<name>/
  history.parquet          # + source, charged columns
  external/
    smiles_train.parquet   # the smiles-only training store
    <run>-warm00_manifest.json
    <run>-ext00_manifest.json
```

`history.parquet` gains two columns: `source` (`oracle` | `warm_start` |
`enrichment`) and `charged` (bool). A history written before this feature has
neither; it is read as all-oracle, all-charged, which is exactly what it was.
