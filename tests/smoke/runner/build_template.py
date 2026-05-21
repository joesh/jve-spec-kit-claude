#!/usr/bin/env python3
"""Build the Anamnesis .jvp template that the smoke suite copies per test.

Runs JVE twice, imports the DRP fixture, exits. Result lives at
``/tmp/jve_smoke/template.jvp``. Re-run when the DRP fixture changes
(or when JVE's import surface changes in a way that affects the
resulting .jvp).

Invocation:
    python3 tests/smoke/runner/build_template.py [--force]

Idempotent: if the template already exists AND the DRP fixture hash
has not changed since, skip and exit 0. ``--force`` bypasses.

Uses ``drp_importer.convert(drp_path, jvp_path)`` — the same primitive
``OpenProject`` drives behind its conversion dialog when the user picks
a .drp at open time. This produces a fresh single-project .jvp in one
shot; no placeholder, no second project. ``ImportResolveProject`` is
NOT the right tool here — it imports INTO an existing project (used
when the user already has a .jvp open and wants to merge in a Resolve
archive).
"""

import argparse
import hashlib
import sys
from pathlib import Path

# Make the runner package importable when invoked directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tests.smoke.runner.jve_runner import (  # noqa: E402
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

    # Single pass — `drp_importer.convert(drp, jvp)` writes a fresh
    # single-project .jvp directly. No placeholder; no second project;
    # no OpenProject in the loop. This is the same primitive Open's
    # conversion-dialog path drives behind the scenes (open_project.lua
    # M.resolve_format → drp_importer.convert).
    #
    # ImportResolveProject is NOT the right tool here — it imports INTO
    # an existing project (creating a second project alongside any
    # pre-existing one). For first-open-of-a-.drp the dispatch is
    # Open → resolve_format → drp_importer.convert.
    runner = JVERunner(
        socket_path="/tmp/jve_smoke_build.sock",
        stdout_log=fixtures.scratch_root / "build_template.log",
    )
    try:
        runner.start()
        runner.eval(
            "require('importers.drp_importer').convert("
            f"'{drp_lit}', '{path_lit}')")
    finally:
        runner.shutdown()

    if not scratch_jvp.exists():
        raise SystemExit(
            f"template build failed — scratch .jvp not produced at {scratch_jvp}. "
            f"See {fixtures.scratch_root / 'build_template.log'}")

    # Move into place.
    import shutil
    shutil.move(str(scratch_jvp), str(fixtures.template_path))
    _write_hash(fixtures.template_path, current_hash)
    print(f"built template at {fixtures.template_path}")
    return fixtures.template_path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="rebuild even if up to date")
    args = ap.parse_args()
    build(force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
