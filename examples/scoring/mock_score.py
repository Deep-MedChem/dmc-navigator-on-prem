"""Dependency-free mock scorer (smoke only — NOT a real objective).

Turns the propose -> score -> ingest loop without Schrodinger, RDKit, or pandas,
so you can validate the workflow wiring on any host that has a plain `python3`.
It emits a deterministic pseudo-"affinity" (lower is better) derived from the
proposal SMILES string, in the standard return schema:

    batch_id, product_id, status, score

Resume-safe: rows already marked `valid` in an existing --out file are kept and
not re-scored. Reads CSV (the .csv proposal file `navigator propose` writes
next to the .parquet) using only the standard library.

Run:  python3 examples/scoring/mock_score.py --proposals <file.csv> --out <file.csv>

Replace this with examples/scoring/glide_batch.py (your licensed Glide) for real
docking; see examples/run_navigator.sh.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
from pathlib import Path

OUT_COLUMNS = ("batch_id", "product_id", "status", "score", "raw_score", "notes")


def _pseudo_score(smiles: str) -> float:
    """Deterministic, smooth-ish pseudo-affinity in roughly [-12, -4] (minimize).

    A stable hash of the SMILES gives a reproducible value; longer, more complex
    strings trend slightly more negative so the surrogate has a learnable signal.
    This is a stand-in, not chemistry.
    """
    digest = hashlib.sha256(smiles.encode("utf-8")).digest()
    frac = int.from_bytes(digest[:4], "big") / 0xFFFFFFFF  # 0..1
    length_term = min(len(smiles), 80) / 80.0  # 0..1
    score = -(4.0 + 6.0 * frac + 2.0 * length_term)
    return round(score, 3)


def _load_done(out_path: Path) -> set[str]:
    if not out_path.exists():
        return set()
    done: set[str] = set()
    with out_path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            if str(row.get("status")) == "valid":
                done.add(str(row.get("product_id")))
    return done


def _read_rows(path: Path) -> list[dict]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Dependency-free mock scorer for DMC Navigator proposals.")
    parser.add_argument("--proposals", required=True, type=Path, help="Proposal .csv (or .parquet's .csv sibling)")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)

    proposals_path = args.proposals
    if proposals_path.suffix.lower() == ".parquet":
        # We only read CSV here (no pandas/pyarrow); use the .csv sibling.
        proposals_path = proposals_path.with_suffix(".csv")
    rows_in = _read_rows(proposals_path)
    done = _load_done(args.out)

    rows_out: list[dict] = []
    # Preserve previously-scored valid rows (resume).
    if done and args.out.exists():
        for row in _read_rows(args.out):
            if str(row.get("status")) == "valid":
                rows_out.append({k: row.get(k, "") for k in OUT_COLUMNS})

    for row in rows_in:
        pid = str(row.get("product_id"))
        if pid in done:
            continue
        smiles = str(row.get("smiles", ""))
        score = _pseudo_score(smiles) if smiles else None
        rows_out.append(
            {
                "batch_id": row.get("batch_id", ""),
                "product_id": pid,
                "status": "valid" if score is not None else "failed",
                "score": score if score is not None else "",
                "raw_score": score if score is not None else "",
                "notes": "mock" if score is not None else "no smiles",
            }
        )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(OUT_COLUMNS))
        writer.writeheader()
        writer.writerows(rows_out)
    print(args.out)


if __name__ == "__main__":
    main()
