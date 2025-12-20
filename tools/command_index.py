#!/usr/bin/env python3
"""
Generate commands.json based on JVE command_registry / command_implementations.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

COMMAND_MODULES = [
    "add_clip","add_track","batch_command","batch_ripple_edit","create_clip",
    "create_project","create_sequence","cut","delete_bin","delete_clip",
    "delete_master_clip","delete_sequence","deselect_all","duplicate_master_clip",
    "go_to_end","go_to_next_edit","go_to_prev_edit","go_to_start",
    "import_fcp7_xml","import_media","import_resolve_project","insert",
    "insert_clip_to_timeline","link_clips","load_project","match_frame",
    "modify_property","move_clip_to_track","new_bin","nudge","overwrite",
    "relink_media","rename_item","ripple_delete","ripple_delete_selection",
    "ripple_edit","select_all","set_clip_property","set_property",
    "set_sequence_metadata","setup_project","split_clip","toggle_clip_enabled",
    "toggle_maximize_panel",
]

ALIASES = {
    "ImportFCP7XML": "core.commands.import_fcp7_xml",
    "ImportResolveProject": "core.commands.import_resolve_project",
}

commands = []

for mod in COMMAND_MODULES:
    commands.append({
        "command": mod,
        "module": f"core.commands.{mod}",
        "entry": "register()",
        "source": "command_implementations.lua"
    })

for name, path in ALIASES.items():
    commands.append({
        "command": name,
        "module": path,
        "entry": "register()",
        "source": "command_registry.lua (alias)"
    })

out = {
    "version": 1,
    "notes": "Auto-generated command index",
    "commands": commands
}

out_path = ROOT / "docs" / "symbol-index" / "commands.json"
out_path.parent.mkdir(parents=True, exist_ok=True)

with open(out_path, "w") as f:
    json.dump(out, f, indent=2)

print(f"Wrote {len(commands)} command entries to {out_path}")
