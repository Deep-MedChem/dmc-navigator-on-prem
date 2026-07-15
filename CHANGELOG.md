# Changelog — DMC Navigator on-prem

Image releases published to `on-prem/dmc-navigator` (pull the `stable` tag; run
`navigator update` to pick up a new release). Newest first.

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
