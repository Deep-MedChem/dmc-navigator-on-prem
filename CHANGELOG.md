# Changelog — DMC Navigator on-prem

Image releases published to `on-prem/dmc-navigator` (pull the `stable` tag; run
`navigator update` to pick up a new release). Newest first.

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
