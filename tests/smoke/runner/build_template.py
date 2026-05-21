#!/usr/bin/env python3
"""Build the Anamnesis .jvp template that the smoke suite copies per test.

Runs JVE twice, imports the DRP fixture, exits. Result lives at
``/tmp/jve_smoke/template.jvp``. Re-run when the DRP fixture changes
(or when JVE's import surface changes in a way that affects the
resulting .jvp).

Invocation:
    python3 tests/smoke/runner/build_template.py [--force]

Idempotent: if the template already exists AND the DRP fixture has not
changed since (mtime), skip and exit 0. ``--force`` bypasses.

KNOWN ISSUE (2026-05-21):
    ImportResolveProject creates a NEW project in the same .jvp
    alongside the placeholder created in pass 1, producing a 2-project
    .jvp which JVE refuses to open ("FATAL: Multiple projects exist;
    active project selection is required"). The smoke template story
    needs one of:
      (a) a project-delete API to remove the placeholder, OR
      (b) a fixture-build path that doesn't rely on the placeholder
          (e.g. manual model-layer construction of a small fixture
          appropriate for keymap smokes — doesn't need full Anamnesis), OR
      (c) ImportResolveProject teaching to drop the existing project
          when invoked from a smoke-build context.
    The runner + sanity tests work; only the Anamnesis-template
    consumer is blocked. Pending Joe's call on (a)/(b)/(c).
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

    # Pass 1 — write the blank .jvp from the "Film 24fps" template.
    # JVE is launched without a project (welcome screen). The welcome
    # screen's panel_manager dependency makes OpenProject-from-socket
    # unreliable here, but project_templates.create_project_from_template
    # is a pure on-disk write (binary copy + identity rebind) and works
    # regardless of UI state.
    pass1 = JVERunner(
        socket_path="/tmp/jve_smoke_build_p1.sock",
        stdout_log=fixtures.scratch_root / "build_template_p1.log",
    )
    try:
        pass1.start()
        pass1.eval(
            "local pt = require('core.project_templates'); "
            "pt.create_project_from_template(pt.TEMPLATES[1], "
            f"'smoke_template', '{path_lit}')")
    finally:
        pass1.shutdown()

    if not scratch_jvp.exists():
        raise SystemExit(
            f"pass 1 failed — blank .jvp not produced at {scratch_jvp}. "
            f"See {fixtures.scratch_root / 'build_template_p1.log'}")

    # Pass 2 — relaunch JVE WITH the new .jvp as the project arg. This
    # routes through layout.lua's normal init path (panel_manager,
    # signal listeners, etc.) so the subsequent ImportResolveProject
    # has the full editor environment available.
    pass2 = JVERunner(
        socket_path="/tmp/jve_smoke_build_p2.sock",
        startup_project=scratch_jvp,
        stdout_log=fixtures.scratch_root / "build_template_p2.log",
    )
    try:
        pass2.start()
        project_id = pass2.eval_str(
            "return require('core.database').get_current_project_id()")
        pass2.eval(
            "require('core.command_manager').execute('ImportResolveProject', { "
            f"project_id = '{project_id}', "
            f"drp_path = '{drp_lit}', "
            "audio_sample_rate = 48000 })")
        # SQLite WAL flush happens on connection close (JVE shutdown).
    finally:
        pass2.shutdown()

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
