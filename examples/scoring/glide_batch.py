"""Reference Glide batch adapter (example, not a bundled docking service).

This is a template the customer owns and runs in their own Schrodinger
environment. It reads the proposal schema, writes a ligand input keyed by
``product_id``, optionally runs LigPrep, invokes the customer's
``$SCHRODINGER/glide`` (or their scheduler), maps every proposal to a ``valid``
row or an explicit failure status, preserves the raw GlideScore separately, and
supports resume/retry without redocking successful products.

It contains NO license credentials, hard-coded grids, internal hosts, or DMC
infrastructure paths. The grid and Schrodinger install are supplied by the
customer at run time. Nothing here is executed by the optimizer image.

Every ligand is LigPrepped (with Epik ionization/tautomer prediction, on by
default) before docking, matching standard practice for real-Glide scoring —
not just raw proposal SMILES straight into Glide.

Run:  python examples/scoring/glide_batch.py \\
          --proposals <file> --grid <grid.zip> --out <file> \\
          [--precision HTVS] [--forcefield OPLS_2005] [--ph 7.4] [--no-epik]

Or, to resolve the grid/precision/ph/forcefield from a docking_settings.json entry
instead of passing them directly (see examples/docking/docking_settings.json):

      python examples/scoring/glide_batch.py \\
          --proposals <file> --out <file> \\
          --docking-settings examples/docking/docking_settings.json --target <NAME>
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path

import pandas as pd

SCORE_COLUMNS = ("batch_id", "product_id", "status", "score", "raw_score", "docking_precision", "notes")


def _read(path: Path) -> pd.DataFrame:
    return pd.read_parquet(path) if path.suffix.lower() == ".parquet" else pd.read_csv(path)


def _load_done(out_path: Path) -> dict[str, dict]:
    """Resume support: successfully docked product ids from a prior partial run."""
    if not out_path.exists():
        return {}
    prev = pd.read_csv(out_path)
    return {str(r["product_id"]): r.to_dict() for _, r in prev.iterrows() if str(r.get("status")) == "valid"}


def resolve_from_docking_settings(settings_path: Path, target: str) -> tuple[Path, str, float | None, str]:
    """Resolve (grid_path, precision, ph, forcefield) for `target` from a docking_settings.json file.

    `binding_site` is a repo-root-relative path to a Glide .in file; the GRIDFILE
    line inside that .in file is itself repo-root-relative. Both are resolved
    against this script's own checkout, since the referenced files only exist
    there (not wherever a customer's --proposals/--out files happen to live).

    The force field is taken from the settings entry's ``forcefield`` key (or the
    ``FORCEFIELD`` line of the .in file), defaulting to OPLS_2005 — the force
    field the shipped grids were built with and the example hit thresholds were
    calibrated against. Glide 2024+ defaults to OPLS4 if none is specified, which
    yields systematically different scores, so it must be pinned explicitly.
    """
    repo_root = Path(__file__).resolve().parents[2]
    settings = json.loads(settings_path.read_text())
    try:
        entry = settings[target]
    except KeyError:
        raise SystemExit(f"no docking_settings entry for target {target!r} in {settings_path}")

    in_path = repo_root / entry["binding_site"]
    in_lines = in_path.read_text().splitlines()
    grid_line = next(
        (line for line in in_lines if line.strip().startswith("GRIDFILE")),
        None,
    )
    if grid_line is None:
        raise SystemExit(f"no GRIDFILE line found in {in_path}")
    grid_rel = grid_line.split()[1]
    ff_line = next((line for line in in_lines if line.strip().startswith("FORCEFIELD")), None)
    forcefield = entry.get("forcefield") or (ff_line.split()[1] if ff_line else "OPLS_2005")
    return repo_root / grid_rel, entry["precision"], entry.get("ph"), forcefield


def _pick_score_column(docked: pd.DataFrame, preferred: str) -> str:
    """Return the GlideScore column present in the results CSV.

    Glide labels the raw docking score ``r_i_docking_score`` in the job CSV, but
    depending on suite/version/output type it may instead appear as
    ``r_i_glide_gscore`` or ``docking score``. Prefer the requested column, then
    fall back across the known aliases.
    """
    aliases = (preferred, "r_i_docking_score", "r_i_glide_gscore", "docking score", "GlideScore")
    for col in aliases:
        if col in docked.columns:
            return col
    raise SystemExit(
        f"no GlideScore column found in results (looked for {aliases}); columns: {list(docked.columns)}"
    )


def schrodinger_tool(schrodinger: str, name: str) -> Path:
    """Resolve a Schrodinger tool path, preferring "<name>.exe" on Windows if the bare name doesn't exist."""
    bare = Path(schrodinger) / name
    if bare.exists():
        return bare
    exe = bare.with_suffix(".exe")
    if exe.exists():
        return exe
    return bare  # neither exists — let the caller's own error handling surface this clearly


def write_ligand_input(frame: pd.DataFrame, path: Path) -> None:
    """Write an SMILES file titled by product_id (stable ligand ids for Glide)."""
    with path.open("w") as handle:
        for _, row in frame.iterrows():
            handle.write(f"{row['smiles']} {row['product_id']}\n")


def run_ligprep(*, ligands: Path, workdir: Path, ph: float, epik: bool, schrodinger: str) -> Path:
    """Run LigPrep (optionally with Epik ionization/tautomer prediction) on the
    input ligands. Returns the prepared Maestro structure file that Glide should
    dock instead of the raw SMILES.

    Epik may expand one input molecule into several output states, titled
    "<product_id>-1", "<product_id>-2", etc. — see fold_epik_states() for how
    those get collapsed back to the original product_id when scoring.
    """
    ligprep = schrodinger_tool(schrodinger, "ligprep")
    prepped = workdir / "ligands_prepped.maegz"
    prepped.unlink(missing_ok=True)
    # Flags mirror the validated internal protocol (dmc_docking.glide): one
    # stereoisomer / one tautomer per input (-s 1 -t 1) so each product maps to a
    # single prepared form, target pH with +-2 tolerance, and a local single-CPU
    # job with no queue (-HOST localhost:1 -WAIT -NOJOBID). Epik (classic) adds
    # ionization/tautomer states, which fold_epik_states() collapses back later.
    cmd = [
        str(ligprep),
        "-ismi", str(ligands),
        "-omae", str(prepped),
        "-s", "1", "-t", "1",
        "-ph", str(ph), "-pht", "2.0",
        "-HOST", "localhost:1",
        "-WAIT", "-NOJOBID",
    ]
    if epik:
        cmd.append("-epik")
    subprocess.run(cmd, cwd=workdir, check=True)
    if not prepped.exists() or prepped.stat().st_size == 0:
        raise FileNotFoundError(f"LigPrep did not produce {prepped}; inspect the job log in {workdir}")
    return prepped


def fold_epik_states(docked: pd.DataFrame, score_column: str, known_ids: set[str]) -> dict[str, float]:
    """Collapse Epik-expanded titles back to their original product_id, keeping
    the best (most negative) raw GlideScore per product.

    Glide's raw docking score is always "more negative is better" regardless of
    the optimizer's own objective.direction, so among several ionization/
    tautomer states for the same product, the most negative score is the one
    that represents it. A title is only treated as an expanded state if
    stripping a trailing "-<digits>" yields a product_id we actually proposed —
    otherwise it's left as-is, since product_ids may themselves contain hyphens.
    """
    best: dict[str, float] = {}
    for _, r in docked.iterrows():
        if pd.isna(r.get(score_column)):
            continue
        title = str(r["title"])
        if title in known_ids:
            product_id = title
        else:
            base, _, suffix = title.rpartition("-")
            product_id = base if base in known_ids and suffix.isdigit() else title
        score = float(r[score_column])
        if product_id not in best or score < best[product_id]:
            best[product_id] = score
    return best


def run_glide(
    *, ligands: Path, grid: Path, workdir: Path, precision: str, schrodinger: str,
    forcefield: str = "OPLS_2005", n_poses: int = 1,
) -> Path:
    """Invoke the customer's Glide. Returns the results CSV path.

    This is intentionally a thin wrapper: adapt the flags to your site's Glide
    setup / scheduler. The optimizer only consumes the returned score file.

    The FORCEFIELD line is REQUIRED: Glide 2024+ defaults to OPLS4 when it is
    omitted, but the shipped grids were built with OPLS_2005 and the example hit
    thresholds are calibrated for it, so mixing force fields would silently
    shift every score. POSE_OUTTYPE poseviewer + POSES_PER_LIG match the
    validated internal protocol (dmc_docking.glide).
    """
    glide = schrodinger_tool(schrodinger, "glide")
    infile = workdir / "glide.in"
    infile.write_text(
        "\n".join(
            [
                f"FORCEFIELD   {forcefield}",
                f"GRIDFILE   {Path(grid).resolve().as_posix()}",
                f"LIGANDFILE   {Path(ligands).resolve().as_posix()}",
                f"PRECISION   {precision}",
                f"POSES_PER_LIG   {n_poses}",
                "POSE_OUTTYPE   poseviewer",
                "",
            ]
        )
    )
    subprocess.run([str(glide), str(infile), "-WAIT", "-OVERWRITE"], cwd=workdir, check=True)
    # Glide writes <jobname>.csv (here glide.csv) with an 'r_i_docking_score' column.
    results = workdir / "glide.csv"
    if not results.exists():
        raise FileNotFoundError(f"Glide did not produce {results}; inspect the job log in {workdir}")
    return results


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Reference Glide adapter for DMC Navigator proposals.")
    parser.add_argument("--proposals", required=True, type=Path)
    parser.add_argument("--grid", type=Path, help="Customer Glide grid (.zip)")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--precision", choices=["HTVS", "SP", "XP"], default=None)
    parser.add_argument("--forcefield", default=None, help="Glide force field (default OPLS_2005)")
    parser.add_argument("--workdir", type=Path, default=None)
    parser.add_argument("--score-column", default="r_i_docking_score")
    parser.add_argument("--docking-settings", type=Path, help="Per-target docking_settings.json")
    parser.add_argument("--target", help="Target key to look up in --docking-settings")
    parser.add_argument("--ph", type=float, default=None, help="Target pH for LigPrep/Epik (default 7.4)")
    parser.add_argument(
        "--epik", action=argparse.BooleanOptionalAction, default=None,
        help="Run Epik ionization/tautomer prediction during LigPrep (default: on)",
    )
    args = parser.parse_args(argv)

    grid = args.grid
    precision = args.precision
    ph = args.ph
    epik = args.epik
    forcefield = args.forcefield
    if args.docking_settings:
        if not args.target:
            parser.error("--target is required when --docking-settings is given")
        settings_grid, settings_precision, settings_ph, settings_ff = resolve_from_docking_settings(
            args.docking_settings, args.target
        )
        grid = grid or settings_grid
        precision = precision or settings_precision
        ph = ph if ph is not None else settings_ph
        forcefield = forcefield or settings_ff
    if grid is None:
        parser.error("--grid is required unless --docking-settings/--target are given")
    precision = precision or "HTVS"
    ph = ph if ph is not None else 7.4
    epik = True if epik is None else epik
    forcefield = forcefield or "OPLS_2005"

    schrodinger = os.environ.get("SCHRODINGER")
    frame = _read(args.proposals)
    done = _load_done(args.out)
    todo = frame[~frame["product_id"].astype(str).isin(done)].copy()

    rows: list[dict] = [
        {
            "batch_id": r.get("batch_id", ""),
            "product_id": pid,
            "status": "valid",
            "score": r.get("score", ""),
            "raw_score": r.get("raw_score", ""),
            "docking_precision": precision,
            "notes": "resumed",
        }
        for pid, r in done.items()
    ]

    if not todo.empty:
        if not schrodinger or not schrodinger_tool(schrodinger, "glide").exists():
            # No Schrodinger install available: emit explicit failures rather than
            # inventing scores. The customer runs this in their licensed env.
            for _, row in todo.iterrows():
                rows.append(
                    {
                        "batch_id": row.get("batch_id", ""),
                        "product_id": str(row["product_id"]),
                        "status": "failed",
                        "score": "",
                        "raw_score": "",
                        "docking_precision": precision,
                        "notes": "SCHRODINGER not set; run this adapter in your licensed Glide environment",
                    }
                )
        else:
            workdir = args.workdir or (args.out.parent / "glide_work")
            workdir.mkdir(parents=True, exist_ok=True)
            ligands = workdir / "ligands.smi"
            write_ligand_input(todo, ligands)
            docking_input = run_ligprep(
                ligands=ligands, workdir=workdir, ph=ph, epik=epik, schrodinger=schrodinger,
            )
            results = run_glide(
                ligands=docking_input, grid=grid, workdir=workdir,
                precision=precision, schrodinger=schrodinger, forcefield=forcefield,
            )
            docked = pd.read_csv(results)
            score_column = _pick_score_column(docked, args.score_column)
            known_ids = set(todo["product_id"].astype(str))
            score_by_id = fold_epik_states(docked, score_column, known_ids)
            for _, row in todo.iterrows():
                pid = str(row["product_id"])
                raw = score_by_id.get(pid)
                rows.append(
                    {
                        "batch_id": row.get("batch_id", ""),
                        "product_id": pid,
                        "status": "valid" if raw is not None else "failed",
                        "score": raw if raw is not None else "",
                        "raw_score": raw if raw is not None else "",
                        "docking_precision": precision,
                        "notes": "" if raw is not None else "no pose / score returned",
                    }
                )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(rows, columns=list(SCORE_COLUMNS)).to_csv(args.out, index=False)
    print(args.out)


if __name__ == "__main__":
    main()
