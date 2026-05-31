#!/usr/bin/env python3
"""T008 reference DRP authoring (via Resolve Python API).

Creates a fresh Resolve project with one known timeline, then asks
Resolve to export it as DRP — the canonical "known-good DRP shape"
we'll dissect against our minimal writer output.

Run AFTER closing any open project (or pass `--reuse-current` to
export whatever Resolve is currently showing).

Usage:
    python3 tools/resolve-helper/spikes/t008_export_reference_drp.py \\
        [--out /tmp/jve/t008_reference.drp] \\
        [--project-name JVE_T008_reference] \\
        [--reuse-current]

The script tries to also add a single media-pool item if `--media`
is given (so the timeline has one clip to mirror our spike DRT
shape). Without `--media` it produces an empty timeline — the shell
shape is what we need.
"""

from __future__ import annotations

import argparse
import os
import sys


def _resolve_connect():
    """Mirror of phase0-findings.md §(a)."""
    api_dir = os.environ.get("RESOLVE_SCRIPT_API") or (
        "/Library/Application Support/Blackmagic Design/"
        "DaVinci Resolve/Developer/Scripting"
    )
    lib = os.environ.get("RESOLVE_SCRIPT_LIB") or (
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/"
        "Contents/Libraries/Fusion/fusionscript.so"
    )
    modules = os.path.join(api_dir, "Modules")
    if modules not in sys.path:
        sys.path.insert(0, modules)
    os.environ["RESOLVE_SCRIPT_API"] = api_dir
    os.environ["RESOLVE_SCRIPT_LIB"] = lib

    import DaVinciResolveScript as dvr  # type: ignore[import-not-found]
    resolve = dvr.scriptapp("Resolve")
    assert resolve is not None, (
        "scriptapp('Resolve') returned None — Resolve Studio not running "
        "or External Scripting not enabled in Preferences."
    )
    return resolve


def _make_project(pm, name: str):
    """Create-or-load. If a same-named project exists, load it; else
    create. Loading lets us re-run the spike without naming collisions."""
    loaded = pm.LoadProject(name)
    if loaded is not None:
        print(f"loaded existing project: {name}")
        return loaded
    created = pm.CreateProject(name)
    assert created is not None, (
        f"CreateProject({name!r}) returned None — name already in use "
        f"in a different folder, or storage full."
    )
    print(f"created project: {name}")
    return created


def _ensure_timeline(project, timeline_name: str, media_paths: list[str]):
    """Make sure there's at least one timeline. With media_paths, import
    each, then create a timeline that contains them. Without media, just
    create an empty timeline."""
    n = project.GetTimelineCount()
    for i in range(1, n + 1):
        tl = project.GetTimelineByIndex(i)
        if tl is not None and tl.GetName() == timeline_name:
            print(f"timeline already exists: {timeline_name}")
            project.SetCurrentTimeline(tl)
            return tl

    media_pool = project.GetMediaPool()
    if media_paths:
        media_storage = _resolve_connect().GetMediaStorage()
        items = media_storage.AddItemListToMediaPool(media_paths) or []
        print(f"imported {len(items)} media item(s)")
        if items:
            timeline = media_pool.CreateTimelineFromClips(timeline_name, items)
        else:
            timeline = media_pool.CreateEmptyTimeline(timeline_name)
    else:
        timeline = media_pool.CreateEmptyTimeline(timeline_name)
    assert timeline is not None, "CreateTimeline returned None"
    print(f"created timeline: {timeline_name}")
    return timeline


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/jve/t008_reference.drp")
    ap.add_argument("--project-name", default="JVE_T008_reference")
    ap.add_argument("--timeline-name", default="JVE_T008_ref_seq")
    ap.add_argument("--media", action="append", default=[],
                    help="path(s) to media file(s) to import (repeatable). "
                         "Without --media the timeline is empty.")
    ap.add_argument("--reuse-current", action="store_true",
                    help="Skip project/timeline creation; export whatever "
                         "project Resolve currently has open.")
    args = ap.parse_args(argv[1:])

    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    resolve = _resolve_connect()
    print(f"product: {resolve.GetProductName()} {resolve.GetVersionString()}")

    if args.reuse_current:
        project = resolve.GetProjectManager().GetCurrentProject()
        assert project is not None, "no current project — open one first"
        print(f"reusing current project: {project.GetName()}")
    else:
        pm = resolve.GetProjectManager()
        project = _make_project(pm, args.project_name)
        _ensure_timeline(project, args.timeline_name, args.media)

    # Resolve API quirk: `ExportProject` lives on ProjectManager (not on
    # Project) in 20.x — signature is `ExportProject(project_name,
    # file_path, with_stills_and_luts?=False)`. The earlier Project-method
    # form returns None (i.e. doesn't exist) on this version.
    if os.path.exists(out_path):
        os.remove(out_path)
    pm = resolve.GetProjectManager()
    ok = pm.ExportProject(project.GetName(), out_path, False)
    assert ok, (
        f"ProjectManager.ExportProject({project.GetName()!r}, {out_path!r}) "
        f"returned falsy. Common causes: project must be the current "
        f"project, destination not writable, project still loading."
    )
    print(f"exported: {out_path}")
    print(f"size: {os.path.getsize(out_path)} bytes")
    print("\nNext: unzip and diff against our writer's stage tree.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
