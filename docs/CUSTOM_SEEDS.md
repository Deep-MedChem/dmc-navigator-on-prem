# Custom seed molecules (0.5.0)

Use `validate-seeds` to check molecules before docking, then `warm-start` to import
scores before the first proposal. For a run already started, use `enrich` between
rounds. These commands never invoke a docking engine.

The commands below use the on-prem `navigator` wrapper. In a source installation,
substitute `dmc-navigator-prod`. Initialize the run with your target configuration
first. On-prem file paths must be visible inside the container: place files under
the on-prem checkout's `inputs/` or `runs/` mounts.

## Choose the mode

| Capability | `--mode synthon` | `--mode external` |
|---|---|---|
| Required data | resolvable IDs/decomposition and scores | SMILES and scores |
| Train the ranking surrogate | yes | yes |
| Seed elites, reaction/synthon distributions and swapping | yes | no |
| Exclude imported product IDs from future proposals | yes | no |
| Unknown vendor/release decomposition | fails with guidance | accepted |

`external` is a descriptive alias for the existing `smiles` mode. The stored mode
remains `smiles` for compatibility. `auto` retains its 0.4.0 behavior: it selects
synthon mode for explicit decomposition columns or a whole column of
`reaction____synthon...` IDs; otherwise it selects smiles mode and warns. **Use
`--mode synthon` when compatibility is required.** It never silently switches the
whole file to external mode after a compatibility failure.

External seeds train from whole-molecule fingerprints. Proposals still use the
configured synthon fingerprints, so the representations differ and predictive
benefit depends on the data. External seeds do not identify products in the space;
Navigator may later propose the same structure. The no-repeat guarantee applies
to resolved product IDs, not all chemically identical structures across IDs.

## 1. Check compatibility before paying for docking

```bash
navigator init --run-dir runs/custom --config-json inputs/target.json
navigator validate-seeds --run-dir runs/custom --molecules inputs/seeds.csv \
  --report runs/custom/compatibility.csv --output inputs/normalized_seeds.csv
```

`score` is optional for this check. Accepted identity formats:

```csv
product_id,smiles
reaction____synthon1____synthon2,STRUCTURE
```

or explicit columns (synthons ordered by the reaction's slots):

```csv
id,reaction_id,synthon_ids,smiles
customer-label,reaction,synthon1|synthon2,STRUCTURE
```

These two snippets describe the format; their identifiers and `STRUCTURE` are
placeholders. Export real IDs from `navigator random`, proposals/history, or a
verified decomposition for the installed release. Parquet can also hold a list of
synthon IDs. CSV/TSV, optionally gzip-compressed, preserve textual IDs and leading
zeros. Common SMILES aliases `SMILES` and `canonical_smiles` are accepted.

Validation checks the reaction, number of slots, membership of each synthon in its
slot, assembly success, and agreement with any supplied SMILES (canonical,
stereochemistry-aware RDKit comparison). It also rejects repeated product IDs and
conflicting explicit versus product-ID decompositions. It does not enumerate the
space or infer a decomposition from molecular structure.

The JSON summary gives counts and the first five incompatibilities; `--report`
writes **every row**, with a zero-based `row_index` and a reason. Exit status is 0
for complete compatibility, 2 for incompatible molecules, and 1 for a malformed
file/configuration or execution error. `--output` writes a normalized CSV/parquet
only when **all rows** are compatible; original scores/extra columns are retained.
No run history, state or budget is changed. Score validity is checked by the
subsequent ingestion dry run, not by `validate-seeds`.

If validation fails, an existing output file is left untouched. Always gate use
of normalized output on the command's successful exit status.

## 2. Resolve catalog or release incompatibility

Freedom IDs carrying the reaction and ordered synthons can resolve when those
identifiers exist in the installed Freedom release. Being a Freedom molecule
alone does not guarantee compatibility; a bare catalog ID is not a decomposition.

Orion's Enamine space and Navigator's reconstructed Enamine release are different
versions. IDs from one must not be assumed compatible with the other. Unknown
reactions, missing synthons, or conflicting assembled structures require the
correct release/decomposition or external mode.

If you can obtain a verified mapping to the installed release, supply a crosswalk:

```csv
external_id,product_id
PV-000001,reaction____synthon1____synthon2
```

The source key is the value of the seed's `product_id`, `navigator_id`, or `id`
column (in that priority). Targets are complete Navigator product IDs. Keys must
be unique and neither column may be empty. Unmapped seeds are still checked under
their original IDs. A mapping may replace an old decomposition explicitly, but
**mapped seeds must include the SMILES that was scored**. Every target must resolve
and reassemble to that supplied molecule. `--id-map` cannot be combined with
`--allow-conflict` or external mode. No fuzzy ID substitution is performed.

```bash
navigator validate-seeds --run-dir runs/custom --molecules inputs/seeds.csv \
  --id-map inputs/id_map.csv --report runs/custom/compatibility.csv
navigator warm-start --run-dir runs/custom --scores inputs/scored_seeds.csv \
  --mode synthon --id-map inputs/id_map.csv --free --dry-run
navigator warm-start --run-dir runs/custom --scores inputs/scored_seeds.csv \
  --mode synthon --id-map inputs/id_map.csv --free
```

The ingestion manifest records source and mapping paths, SHA-256 hashes, and the
mapped-row count. Use a crosswalk from a verified export; a crosswalk cannot make
chemistry absent from the release become available.

## 3. Import scores you already have

```csv
product_id,smiles,docking_score
reaction____synthon1____synthon2,STRUCTURE,-8.2
```

```bash
navigator warm-start --run-dir runs/custom --scores inputs/scored_seeds.csv \
  --mode synthon --score-column docking_score --free --dry-run
navigator warm-start --run-dir runs/custom --scores inputs/scored_seeds.csv \
  --mode synthon --score-column docking_score --free
navigator propose --run-dir runs/custom
```

There is **no docking during import**, whether `--free` is supplied or not. That
flag only controls accounting: by default imports consume `budget.submitted`;
`--free` leaves the configured proposal budget available. Synthon seeds are marked
seen, so their product IDs are excluded from subsequent proposals. Dock only the
new proposals in your normal oracle loop.

Use scores comparable to the campaign's target, scoring protocol, units and
objective direction. No score scaling or sign conversion is applied on import.
Valid rows require a finite numeric score. Mark failed docks with `status=failed`
and an empty score; handling follows the configured training failure policy.

## 4. Use molecules with unknown decomposition

After a failed compatibility check, choose this mode explicitly:

```csv
id,smiles,score
prior-001,CC(=O)Nc1ccccc1,-7.2
prior-002,CCOc1ccc(C(N)=O)cc1,-6.8
```

```bash
navigator warm-start --run-dir runs/custom --scores inputs/external_scored.csv \
  --mode external --free --dry-run
navigator warm-start --run-dir runs/custom --scores inputs/external_scored.csv \
  --mode external --free
navigator propose --run-dir runs/custom
```

IDs can be arbitrary or omitted. Rows enter `external/smiles_train.parquet` and
train the surrogate; they do not become elites or seed reaction/synthon search.
Canonical structures are deduplicated; evidence already stored keeps its original
score and is not charged again. Summaries count invalid/missing SMILES that were
dropped. Inspect the dry-run counts before importing a large file.

For a mixed file, `--mode synthon --allow-unmatched` explicitly allows unresolved
rows with valid SMILES to join this training store while resolved rows enter the
space. Assembly failures and structure conflicts still fail strict ingestion;
select external mode for those structures or correct their identities.

## Example file and upgrade

[`examples/custom_seeds/external_scored.csv`](../examples/custom_seeds/external_scored.csv)
contains illustrative synthetic scores for testing the input format. Copy it into
`inputs/` and use a separate fresh run.

### Upgrade from 0.4.0

Update this checkout (`git pull --ff-only`). In `.env`, set:

```dotenv
DMC_NAV_IMAGE=815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/navigator/dmc-navigator
DMC_NAV_IMAGE_TAG=0.5.0
```

The registry path changed to match the Navigator-specific customer pull grant.
Keep your existing license, database installation and run mounts. Then run:

```bash
navigator login
navigator update
navigator --version
navigator self-test
```

Expect version `0.5.0`. Use `stable` instead of `0.5.0` to follow future releases.
The [release](https://github.com/Deep-MedChem/dmc-navigator-prod/releases/tag/on-prem-v0.5.0)
also records the immutable image digest.
