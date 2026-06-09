#!/usr/bin/env python3
"""Build the Anamnesis .jvp template that the smoke suite copies per test.

Invocation:
    python3 tests/live/runner/build_template.py [--force]

Idempotent against the DRP fixture's sha256: re-runs only when the
fixture changes (or with ``--force``). Result lives at
``/tmp/jve_smoke/template.jvp``.
"""

import argparse
import hashlib
import sys
from pathlib import Path

# Make the runner package importable when invoked directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tests.live.runner.jve_runner import (  # noqa: E402
    Fixtures, JVERunner, REPO_ROOT,
)


HASH_SUFFIX = ".drp.sha256"


def _drp_hash(drp_path: Path) -> str:
    h = hashlib.sha256()
    with drp_path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _existing_hash(template_path: Path) -> str:
    p = template_path.with_suffix(template_path.suffix + HASH_SUFFIX)
    if not p.exists():
        return ""
    return p.read_text().strip()


def _write_hash(template_path: Path, digest: str) -> None:
    p = template_path.with_suffix(template_path.suffix + HASH_SUFFIX)
    p.write_text(digest)


def build(force: bool = False) -> Path:
    fixtures = Fixtures()
    drp_path = fixtures.DRP_FIXTURE
    if not drp_path.exists():
        raise SystemExit(
            f"DRP fixture missing at {drp_path}. "
            f"Cannot build smoke template without it.")

    current_hash = _drp_hash(drp_path)
    if not force and fixtures.template_path.exists():
        if _existing_hash(fixtures.template_path) == current_hash:
            print(f"template up to date at {fixtures.template_path}")
            return fixtures.template_path

    # Build path: launch JVE on a scratch .jvp, drive DRP import via the
    # socket, shut down. Result is the template.
    scratch_jvp = fixtures.scratch_root / "build_scratch.jvp"
    for suffix in ("", "-wal", "-shm"):
        p = Path(str(scratch_jvp) + suffix)
        if p.exists():
            p.unlink()

    path_lit = str(scratch_jvp).replace("'", "\\'")
    drp_lit = str(drp_path).replace("'", "\\'")

    runner = JVERunner(
        socket_path="/tmp/jve_smoke_build.sock",
        stdout_log=fixtures.scratch_root / "build_template.log",
    )
    try:
        runner.start()
        runner.eval(
            "require('core.commands.open_project')._convert_drp_to_jvp("
            f"'{drp_lit}', '{path_lit}')")
    finally:
        runner.shutdown()

    if not scratch_jvp.exists():
        raise SystemExit(
            f"template build failed — scratch .jvp not produced at {scratch_jvp}. "
            f"See {fixtures.scratch_root / 'build_template.log'}")

    # Checkpoint the WAL into the main file so the template is
    # self-contained — case.py copies only the .jvp per test, and
    # without this the per-test DB would be missing every row that
    # the importer wrote (a pre-2026-05-25 bug: builder reported
    # success while producing an empty template).
    import sqlite3
    conn = sqlite3.connect(str(scratch_jvp))
    try:
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.commit()
    finally:
        conn.close()

    # Postcondition: at least one project row landed. NSF — fail
    # loudly here, not three layers up when JVE rejects the empty DB.
    conn = sqlite3.connect(str(scratch_jvp))
    try:
        count = conn.execute("SELECT count(*) FROM projects").fetchone()[0]
    finally:
        conn.close()
    if count == 0:
        raise SystemExit(
            f"template build produced 0 projects — DRP import silently failed. "
            f"See {fixtures.scratch_root / 'build_template.log'}")

    # Move into place.
    import shutil
    shutil.move(str(scratch_jvp), str(fixtures.template_path))
    _write_hash(fixtures.template_path, current_hash)
    print(f"built template at {fixtures.template_path} ({count} project(s))")
    return fixtures.template_path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="rebuild even if up to date")
    args = ap.parse_args()
    build(force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
