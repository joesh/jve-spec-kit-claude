# Contract: RelinkClips

## media_relinker.relink_clips_batch

```
Input:
  clips: [{
    clip_id: string,
    media_id: string,
    source_in: integer (native units),
    source_out: integer (native units),
    fps_num: integer,
    fps_den: integer,
    media_start_tc_value: integer|nil,
    media_start_tc_rate: integer|nil,
    media_path: string,
    media_name: string,
    width: integer,
    height: integer,
    clip_kind: "master"|"timeline"
  }]
  options: {
    search_paths: [string],
    matching_rules: {
      match_filename: boolean,
      match_timecode: boolean,
      match_resolution: boolean,
      match_frame_rate: boolean,
      accept_trimmed_media: boolean,
      accept_filename_suffixes: boolean
    }
  }
  progress_cb: function(pct, status, log_line)|nil

Output:
  {
    relinked: [{
      clip_id: string,
      new_media_id: string|nil (nil = reuse existing),
      new_source_in: integer,
      new_source_out: integer,
      new_path: string,
      strategy: "filename"|"timecode"|"segment",
      tc_offset: integer|nil (frames of offset applied)
    }],
    failed: [{clip_id: string, reason: string}],
    ambiguous: [{clip_id: string, candidates: [{path, start_tc, duration}]}],
    new_media: [{
      media_id: string (generated UUID),
      path: string,
      name: string,
      start_tc_value: integer,
      start_tc_rate: integer,
      width: integer, height: integer,
      duration_frames: integer,
      fps_num: integer, fps_den: integer
    }]
  }
```

## RelinkClips Command

```
Executor args:
  clip_relink_map: {clip_id → {new_media_id, new_source_in, new_source_out}}
  media_path_changes: {media_id → new_path}
  new_media_records: [{id, path, name, start_tc_value, start_tc_rate, duration_frames, fps_num, fps_den, width, height}]
  project_id: string

Persisted for undo:
  old_clip_state: {clip_id → {old_media_id, old_source_in, old_source_out}}
  old_media_paths: {media_id → old_path}

Spec:
  undoable: true (default)
```

## matching_rules_dialog.show

```
Input:
  current_rules: {match_filename, match_timecode, match_resolution, match_frame_rate, accept_trimmed_media, accept_filename_suffixes}
  parent_window: widget|nil

Output:
  updated_rules: table (same shape) | nil (cancelled)
```
