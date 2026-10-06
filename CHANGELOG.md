# Changelog — DMC Navigator on-prem

Image releases published to `on-prem/navigator/dmc-navigator` (pull the `stable` tag; run
`navigator update` to pick up a new release). Newest first.

## 0.5.2 — 2026-10-06

Upgrading can change future proposals, including for default Gamma and GA-DCSO v14
campaigns. See [upgrade guidance](README.md#upgrading-a-campaign-that-is-already-running)
before updating an existing run.

### Pool and selection

- `candidate_pool_size` is now a hard total including one-hop mutants. Gamma previously
  added mutants on top of the pool; it now shares that limit between base candidates and
  mutants, backfilling unused mutant slots within the total. Sampling can leave a short pool.
- **Gamma restores the fixed 20,000-mutant ceiling from 0.5.0.** In 0.5.1 the effective
  ceiling could grow with the pool. `advanced.second_hop_cap: 0` continues to disable the
  hop; `null` removes the absolute cap. V14 remains uncapped by default, as in 0.5.0 and
  0.5.1. The removed `advanced.second_hop_cap_fraction` is rejected with migration guidance.
  Restoring Gamma's cap does not restore its 0.5.0 proposals: the combined pool budget is
  new, and the budget-spent annealing clock introduced in 0.5.1 remains.
- V14's default one-hop share changes from 10% → 30% to **0% → 20%**, using Gamma's
  linear interpolation on the budget-spent clock. Each unspecified endpoint adopts its
  new default; explicit overrides remain effective. Set `advanced.second_hop_fraction: 0.1` and
  `advanced.second_hop_fraction_late: 0.3` to retain the previous endpoints. With
  `anneal: false`, the default zero early fraction disables the hop. The similarity cap
  still starts at 0.65 and reaches 1.0 at 80% progress; a configured diversity floor can
  keep comparisons active afterward.
- V14 spreads novelty and random picks through each proposal, so trimming no longer
  systematically discards exploration at the tail. Ordering changes even without trimming;
  filtering and trimming can also change which molecules are delivered.
- V14 defaults to `advanced.novelty_selector: partitioned`, selecting within multiple
  random windows instead of exhausting one 4,096-candidate window. Windows share a sampled
  reference but do not enforce diversity against one another. `coreset` keeps the earlier selector.
- `selection.reaction_cap` applies across the complete batch, including exploration,
  unfitted rounds, both harvesters and refill. Only accepted molecules use the allowance;
  exhausted reactions can leave a short batch. The default remains no cap.

### Advanced system setting: diversity performance

`advanced.diversity_guard_backend` is for performance tuning on a measured workload.
Normally leave it unset: Gamma defaults to `packed_incremental`, V14 to `packed_batched`.
It chooses the comparison implementation; `selection.diversity` controls the
diversity pressure. `null` is invalid.

| Value | Method | Fallback when unsupported |
|---|---|---|
| `list_bulk` | Bulk comparisons against a list; packed bytes or RDKit, depending on the store | None |
| `packed_incremental` | Exact packed comparisons, one candidate at a time | `list_bulk` |
| `dense_float32` | Historical dense float32 comparisons | None |
| `packed_batched` | Block screening with exact packed verification | Incremental, then list/bulk |

Batching requires a supported 2048-bit packed store. Gamma can opt in with:

```json
{"advanced": {"diversity_guard_backend": "packed_batched"}}
```

Performance depends on the workload. Packed methods make the same decisions on identical
fingerprints. V14 previously used dense float32 arithmetic; the new default can change
decisions at similarity boundaries. `dense_float32` retains that arithmetic, but does not
undo the other selection changes.

### Diagnostics and runtime

- Run-changing commands append start/finish entries for commands and nested stages to
  `<run>/logs/operations.jsonl`, with full paths such as `propose.strategy.fit`.
  Finish entries report total elapsed time and **own time** (excluding child stages).
  Entries include command settings, state changes and available error tracebacks,
  and are written immediately. A hard kill leaves unfinished starts; dry runs emit
  nothing. Logging failures do not change the command's outcome. Use one writer per run.
  The log is diagnostic; iteration telemetry retains scientific counts and quality
  metrics. Timings separate training preparation, GA seeding/generation, second-hop
  generation, selection and exploration.
- The shared similarity/novelty pool now defaults to the logical CPU count instead of
  at most eight workers. Set `DMC_NAV_SIM_THREADS` in `.env` to choose its worker count
  (`1` disables threading); Compose now forwards this setting to the container.
  This affects performance, not selection results, and does not limit other Navigator
  threads. See [worker settings](README.md#notes--troubleshooting).
- A config asking for `surrogate.device: cuda` now stops with an error unless it also sets
  `surrogate.allow_cpu_fallback: true`. The image's XGBoost is CPU-only, and until now such
  a config ran on the CPU while reporting `cuda`. `examples/run_navigator.sh --gpu` sets
  the fallback and keeps running; telemetry now reports the device actually used, `cpu`,
  and why CUDA could not be used. For an existing CUDA config, set the device to `cpu`
  or enable fallback in the run's `config.json` before its next `propose`.
- pandas 3.0.6 (was 2.3.3). XGBoost stays at 3.3.0.

### Installer examples

- Accurate and Fast harvest now use separate directories for new example runs.
  Previously `--method all` could silently resume Accurate's run for Fast. Matching
  legacy `..._analog_...` runs are still resumed in place; a requested strategy that
  differs from the saved config is rejected before resuming.

### Published image

| Identifier | Value |
|---|---|
| Installer Git tag (this repository) | `v0.5.2` |
| Production Git tag (`dmc-navigator-prod`) | `on-prem-v0.5.2` |
| Production source commit | `3dc0bdfe6d2f1bf6acf188ff3d54ee46a062615b` |
| Image repository | `815935788477.dkr.ecr.us-east-1.amazonaws.com/on-prem/navigator/dmc-navigator` |
| Immutable image tags | `0.5.2`, `sha-3dc0bdfe6d2f` |
| Registry digest | `sha256:7d8d0c1c774f29c417e28062db68932b64fe284d95a58d6bd21ec3873ac4a94f` |

The installer tag identifies this repository's own commit. The `sha-` image tag
uses the first 12 characters of the production source commit; the registry digest
and the Docker image ID printed by `navigator update` are separate identifiers.
Set `DMC_NAV_IMAGE_TAG=0.5.2` or `sha-3dc0bdfe6d2f` in `.env` to pin this image.
`stable` pointed to the same digest at publication and will advance with future releases.
Installations still using `on-prem/dmc-navigator` (including 0.3.0) must also change
`DMC_NAV_IMAGE` to the image repository above; changing only the version tag leaves
the old repository path.
See the [complete upgrade procedure](README.md#upgrading-to-052).

Refresh this installer checkout and rerun `./install_navigator.sh` to update the
wrapper and examples while preserving the existing `.env` and license.
`navigator update` updates only the image. See the
[campaign upgrade guidance](README.md#upgrading-a-campaign-that-is-already-running)
before switching an existing run to 0.5.2.

## 0.5.1 — 2026-09-26

Optimiser fixes; what an unconfigured campaign does changes. A campaign already
running under 0.5.0 can stay on it — see
[Upgrading a campaign that is already running](README.md#upgrading-a-campaign-that-is-already-running).

- Imported molecules (`warm-start`, `enrich`) are no longer charged to the budget;
  `--charge-to-budget` charges them and `--free` is a no-op. `status` adds
  `docking_attempts`, `external_charged`, `budget_consumed` and `remaining_budget`.
- With `enforce_filtered_batch` off (the default), a round delivers the molecules
  that pass the drug-like filter instead of being refilled to a full batch;
  duplicates are still replaced.
- The budget caps what is docked: the final round delivers exactly the remainder.
- The anneal schedule follows the budget spent (`advanced.anneal_basis`, default
  `budget_spent`; `nominal_rounds` is the 0.5.0 behaviour).
- The one-hop expansion ceiling scales with the candidate pool
  (`advanced.second_hop_cap_fraction`); unchanged at every preset pool size.
- New: an optional `min_gate_yield` stop (`update-params --min-gate-yield`),
  `update-params --anneal-basis`, and validation of `advanced` parameters wherever
  a config is created, updated or transitioned.
- Faster proposal rounds with identical results.
- The image's Python (3.12) and numerical libraries are pinned to exact builds, the
  ones the release is tested with, so a rebuild of the same version proposes the same
  molecules. Proposals can differ from the 0.5.0 image's for this reason too.
- Molecules with equal similarity or equal scores are now ordered the same way on every
  machine. Before, the order could depend on whether the CPU supports AVX-512, so the
  same campaign could propose differently on different hardware.
- The surrogate runs on the CPU: the image's XGBoost is a CPU-only build, as it has been in
  every release. The GPU notes in this guide said otherwise and now say so.

## 0.5.0 — 2026-09-15

See [the custom seed guide](docs/CUSTOM_SEEDS.md) for upgrade and usage.

- `navigator validate-seeds` checks IDs, synthon slots, assembly and supplied
  structures before docking, with per-row reports and normalized exports.
- `--id-map` maps known vendor/release IDs to the installed space and verifies
  the mapped molecule against supplied SMILES.
- `warm-start` / `enrich` reuse supplied scores without docking. Resolved product
  IDs are excluded from subsequent proposals.
- `--mode external` (alias `smiles`) trains from molecules with unknown
  decompositions. Compatibility failures point to this fallback.
- Strict synthon imports reject assembly/structure failures before writing evidence.
- Optional `.env` settings may be omitted without aborting `navigator login`.
- The image now publishes at `on-prem/navigator/dmc-navigator`; update `DMC_NAV_IMAGE`
  in `.env` as described in the guide.

## Unreleased — 2026-09-03

**Database catalog**
- VAST 2026 H2 (`vast-2026-h2@2026-h2.1`) replaces both VAST 2026 H1 and the
  legacy XtalPi VAST entry in the signed public catalog.
- The encrypted H2 bundle is sealed to every currently issued database-install
  key and can be installed with `navigator data install vast-2026-h2`.

## 0.4.0 — 2026-07-30

Run `navigator update` to pick this up.

**Warm start and mid-run enrichment**
- New `navigator warm-start --run-dir <run> --scores <csv>` seeds a **fresh** run
  with molecules you scored elsewhere (an old campaign, an HTS deck, a supplied
  seed set), so its first `propose` is already informed instead of drawing at
  random.
- New `navigator enrich --run-dir <run> --scores <csv>` does the same for a run
  already under way: pause between rounds, dock some molecules your own way, hand
  them over, carry on. It refuses while a batch is awaiting scores.
- **Two modes.** `--mode synthon` (recommended) takes rows carrying ids from the
  database you are screening — a Navigator `product_id`, or `reaction_id` +
  `synthon_ids`. Navigator rebuilds the structures from the ids itself, so those
  molecules become full members of the run: they train the ranking model, act as
  starting points for analogue growth, steer the search through their building
  blocks, and are never re-docked at your expense. `--mode smiles` takes bare
  structures; they can only warm-train the ranking model, and the next `propose`
  still draws its own fresh batch. `--mode auto` (default) picks per file.
- **Budget.** These molecules are **charged** to the run's `budget.submitted` by
  default — 1,000 seeds means 1,000 fewer proposals, so a warm-started run and a
  cold run cost the same number of docks. `--free` opts out.
- `--dry-run` validates a file and reports what would happen without writing
  anything. Ingesting the same file twice is refused, and a molecule the run
  already knows is skipped, so nothing is ever double-charged.
- If ids do not resolve, the error names the reason per row — almost always a
  file exported against a different database or release. `--allow-unmatched`
  demotes just those rows to the structures-only path instead of failing the file.
- **You are warned when you lose the id path.** Ending up in structures-only mode
  produces no error — the ingest succeeds and the ranking model is trained while
  the molecules never enter the space — so Navigator prints a warning naming the
  cause and the cost. The usual cause is a file keyed by vendor catalog ids
  (`PV-…`, `Z…`) instead of the ids of the synthons being screened; the warning
  quotes the offending values and says what a Navigator id looks like.
- `navigator status` now reports `observations` and `external_observations`
  alongside `submitted`; `submitted` keeps its existing budget-facing meaning, so
  a run with no external evidence reports exactly the same numbers as before.

## 0.3.0 — 2026-07-28

The correctness and productization release. Two strategy renames are **breaking**;
both fail with a message naming the replacement rather than silently switching
algorithm, so an old config stops rather than quietly running something else.

**Breaking — strategy roster**
- `alpha_diversity_screening` (the previous out-of-box default) is **retired**. Use
  `gamma_diversity_screening`, which is now the default. It found roughly 20× more
  hits than alpha in our internal live-docking campaign.
- `beta_diversity_screening` is **retired**. Use `ga_dcso_v14_screening`, the
  consolidated GA discovery screen and the other default-tier strategy.
- `analog_harvest` still works as a deprecated alias for `analog_harvest_fast`, so
  configs from 0.2.2–0.2.9 keep running.
- The customer roster is now exactly four presets: `gamma_diversity_screening`,
  `ga_dcso_v14_screening`, `analog_harvest_accurate`, `analog_harvest_fast`.

**Chemistry — molecules that fail your filters no longer reach your docking**
- New authoritative exact filter gate: set `space.exact_filter_profile` (e.g.
  `"druglike-v1"`) and every proposed molecule is re-checked on its assembled
  structure *before* the proposal file is written — property window plus the
  structural alerts — no matter which internal operator generated it. Previously
  some generation paths could bypass the property prefilter, so out-of-window
  molecules could reach your scoring step. Rejected molecules consume no budget.
- A config with a reaction additive-policy path but no property window is now a
  validation error instead of silently filtering nothing.
- The shipped `examples/configs/*.json` enable `druglike-v1`; their notes no
  longer say the exclusions are left to your scoring step.

**Scale and reproducibility**
- Named run-scale profiles: `standard_100k` (100k budget / 10k batch / 100k pool)
  and `scale_1m` (1M / 100k / 1M), both ten rounds. A profile changes scale only —
  never the algorithm — and the fully resolved config lands in the run manifest.
- Large pools are markedly faster: the slow per-draw rejection sampler is off the
  hot path when the exact gate is on, which removes roughly 38 minutes per round
  at a 1M pool.
- Resume-integrity guard: `propose` now hard-fails if the seed, schema, objective
  direction, or space changed under an existing run, instead of continuing with
  mismatched state. Budget, pool and strategy remain freely adjustable.
- Per-round memory telemetry (peak RSS) so a large run's footprint is visible.

**New — `navigator random`**
- Draw N distinct random molecules from a space to an `id,smiles` CSV without an
  optimizer run — for baselines, negative controls and coverage probes.
  `--mode pw` (each product equally likely) or `--mode rw` (each reaction equally
  likely); `--seed` for reproducible draws; optional `--filter-profile druglike-v1`.
  See the README section for which mode answers which question.

**Docs**
- README now maps every curated database to its CLI name, its AWS release prefix,
  and the equivalent BioSolveIT `.space` file.

## 0.2.9 — 2026-07-15
- Strategies: GA-DCSO v12/v13 and reconciled alpha/gamma/analog presets to the internal benchmark.
- Surrogate: configurable failed-dock label policy — `surrogate.training_filter` (`default`|`glide`)
  and `surrogate.penalty_mode` (`exclude`|`cap`|`keep_sentinel_bug`) are now accepted in run configs
  again (they were rejected in 0.2.6–0.2.8). The shipped `examples/configs/*.json` use them.
- Assembly: `synthon_assembler` backend prepare/assemble fix.
- Workflow hardening: recoverable terminal statuses, space-exhaustion is a clean terminal state.
- Carries the 0.2.6 rdkit-advisory fix; signed with the same vendor key as 0.2.8.

## 0.2.8 — 2026-07-15
- Restored the original vendor license signing key (a 0.2.7 key rotation was reverted). Licenses
  signed with the original key verify again. Includes the 0.2.6 rdkit fix.

## 0.2.7 — 2026-07-15 (superseded by 0.2.8)
- Vendor signing-key rotation (later reverted). Do not rely on this tag.

## 0.2.6 — 2026-07-15
- **Fix (important): `navigator data install` worked again.** The rdkit compatibility check was a
  hard error, so an image whose rdkit had drifted from a release's build rdkit could not install ANY
  database. It is now advisory (a warning) — the fingerprint/descriptor contract is still pinned by
  `feature_schema` + `synthon_assembler`. If you are on an older image and `data install` fails with
  an rdkit incompatibility error, run `navigator update` then retry.

## 0.2.5 and earlier
- Initial on-prem releases: license gate, encrypted database delivery (`navigator data …`),
  workflow CLI (`init`/`propose`/`ingest`/`status`/`transition`).
