 # Relink Bug Report — anamnesis-gold-timeline (2026-06-17)

Fixture: `tests/fixtures/resolve/anamnesis-gold-timeline.drp`
Trimmed media: `anamnesis-gold-timeline` trimmed media export (Resolve-authored)

Relink results: 911 relinked ✓ · 16 partial · 2 rejected · 15 not found

Status (updated 2026-06-19 after verification):
- **Bug 1 — FIXED + committed** (`7f9f9701`, with `test_drp_binary_signed_offset.lua`).
- **Bug 2 — open, latent.** `partition_candidates` offset-sign guard still present.
  Needs a domain decision + the trimmed media to reproduce. See revised section.
- **Bug 3 — FIXED (freeze-frame retime decode).** The reported `A023_C026`
  "short at head 347 f" was a JVE bug: freeze-frame clips had their flat MTBA
  curve discarded → from-origin synth → `source_in` 347 f too low (and negative
  source span), dragging the relink extent before the trim. Fixed by accepting
  the flat freeze curve in `decode_media_timemap` + guaranteeing a 1-frame source
  span (`source_out = source_in + 1`, Joe's freeze model). Regression test
  `test_drp_freeze_frame_source_in.lua`. See revised section.

---

## Bug 1 — `read_be64` unsigned-only; SampleOffset is signed  ✅ FIXED (7f9f9701)

**File:** `src/lua/importers/drp_binary.lua:54–60`

```lua
function M.read_be64(bytes, pos)
    ...
    return hi * 4294967296 + lo   -- unsigned only; wrong for signed fields
end
```

**Impact:** 14+ partial WAV files with enormous tail shortfalls (e.g.
`374-T002.WAV: 9223372033677262848f at tail`).

### Root cause chain

DRP `SampleOffset` encodes which sample of the field-recorder WAV plays under
video frame 0. When the recorder started **after** the camera's frame 0, the
sync point is before the WAV's first byte → the value is **negative**. Negative
int64s in big-endian two's-complement have the high bit set. `read_be64`
treats the value as unsigned, producing a result ≈ 2⁶³–2⁶⁴.

That corrupt value reaches `add_synced_audio_streams` in `master_builder.lua`:

```lua
local source_in = audio_tc + file_offset   -- audio_tc + (corrupt ≈ 2⁶³) ≈ 2⁶³
```

The huge `source_in_frame` in the media_ref produces a huge `delta` inside
`map_source_through_mr` (`src/lua/models/media.lua:794`), which inflates
`source_extent_end` to ≈ 9.22e18 samples. `check_extent_containment` fails.
Tail shortfall = `source_extent_end − cand_end ≈ 9.22e18`.

### Why the existing test doesn't catch this

`tests/synthetic/binding/test_drp_synced_relink_extent.lua` passes because its
fixture (`synced clip example.drp` / `S064-T002.WAV`) has a non-negative
SampleOffset. A recorder that started before frame 0 never triggers the bug.

### Fix

Sign-extend `hi` before multiplying:

```lua
function M.read_be64(bytes, pos)
    if pos + 7 > #bytes then return nil end
    local hi = M.read_be32(bytes, pos)
    local lo = M.read_be32(bytes, pos + 4)
    if not hi or not lo then return nil end
    if hi >= 2147483648 then hi = hi - 4294967296 end  -- two's-complement sign-extend
    return hi * 4294967296 + lo
end
```

Existing callers that use `read_be64` for unsigned fields (field_count,
duration, version) are unaffected — those values are never negative.

### Follow-up

Add a test case with a negative-SampleOffset fixture (or synthesize a blob with
known negative offset) so a regression can't re-enter silently.

---

## Bug 2 — `partition_candidates` rejects files with small negative TC offset

**File:** `src/lua/core/media_relinker.lua` — `partition_candidates`

```lua
local offset = cand_tc - ref_tc
if offset >= 0 and offset < 90000 * 24 then
    partial_fit[#partial_fit + 1] = cand
else
    dropped[...]  -- "not a trim of the original"
end
```

**Impact:** `Number Not.wav` — 2 entries rejected.

### Root cause

| | Samples |
|---|---|
| Stored TC (MST × 48 000) | 81 770 |
| Probed BWF `time_reference` | 80 640 |
| Offset (`cand − ref`) | **−1 130** |

Guard `offset >= 0` fails → file dropped as "not a trim of the original" even
though the filename matches and the content is present.

The −1130 sample (~23 ms) gap is Resolve's trimmed-export BWF behavior: the
exported WAV's `time_reference` is slightly earlier than the MST-derived origin
JVE stored during DRP import. The guard assumes trimming only goes forward
(trimmed file can only start ≥ original TC). That assumption is wrong.

### Reachability (verified 2026-06-19)

This branch (`media_relinker.lua:1106`, `elseif cand.probe_result`) is reached
ONLY when the viable extent-containment branch above it (`:1100`) did not pass —
i.e. extents are absent, or containment failed. So the guard only bites when
JVE can't already prove coverage. When it does bite, dropping the candidate
outright (vs. demoting to `partial_fit`) suppresses the partial-coverage note
that would otherwise explain the deficit.

### Two candidate fixes — needs a decision

**Option A (heuristic, as originally sketched):** widen the guard to a bounded
negative tolerance.

```lua
local NEGATIVE_TC_TOLERANCE = 48000  -- 1 s
if offset > -NEGATIVE_TC_TOLERANCE and offset < 90000 * 24 then
```

A magic tolerance is exactly the "near-boundary heuristic" CLAUDE.md warns
against — it patches the symptom.

**Option B (architectural):** drop the offset-sign gate entirely in this branch.
A filename match already establishes relatedness; `check_extent_containment` /
`partial_coverage` downstream are the authority on whether the file actually
backs the clip. Treat any filename-matched, TC-bearing candidate as
`partial_fit` and let coverage decide — removing the heuristic rather than
tuning it.

### Blocked on

1. **Repro:** the −1130 numbers came from Joe's live trimmed media, which is not
   a checked-in fixture. A TDD regression needs either that file or a synthesized
   negative-`time_reference` WAV.
2. **Domain:** is a candidate whose TC starts *before* the stored origin a valid
   relink target at all, or correctly rejected? (Why does Resolve's trimmed WAV
   export carry an earlier `time_reference`?) — Joe's call.

---

## Bug 3 — "short at head" on `A023_10251352_C026.mov` — REAL JVE BUG (freeze-frame retime decode)

**Earlier verdicts retracted (twice).** I first called it "not a bug / Resolve
trim limitation", then mis-identified an unrelated sound edit on C033. Both wrong.
The actual reported partial is **C026**, and tracing its clips to the DRP `<In>`
ground truth + the importer's own `source_in` log pins a real JVE defect.

### What the relink reported vs. what JVE imported

C026's `extent_start` is dragged to `origin+23` by two stacked V1/V4 clips at
timeline 193818, while the trim starts at `origin+370`. `370 − 23 = 347` = the
reported head shortfall. The DRP `<In>` and the importer log expose why:

| Clip (Sm2Ti DbId) | DRP `<In>` | importer log | JVE `source_in` | correct? |
|---|---|---|---|---|
| 1222af80 (V) | 89975 | `in_off=23 dur=-1 spd=0.000 retime(2kf)` | 1248385 (origin+23) | **NO — 347 f low, negative dur** |
| f37c0aa4 (V, dup) | 89975 | same | 1248385 | **NO** |
| f5672a38 (V) | 370 | `in_off=370 spd=1.000 no-retime` | 1248732 | yes |
| 5f703f45 (V) | 545 | `in_off=545 spd=1.000 no-retime` | 1248907 | yes |

The two bad clips are **freeze frames** (`spd=0.000`). Their MediaTimemapBA is a
FLAT curve (`YMin=YMax=14.8 s = source frame 370 = TC 1248732 = the trim start`).

### Root cause (code-confirmed)

`drp_binary.decode_media_timemap` (drp_binary.lua:710-726) accepts a curve only
when its keyframes are FORWARD (`first.y≈0 → last.y≈YMax`) or REVERSE
(`first.y≈YMax → last.y≈0`). A flat freeze (`first.y≈last.y≈YMax`) satisfies
neither → **keyframes discarded**. The importer fallback
(drp_importer.lua:1452-1457) then synthesizes a from-ORIGIN ramp
`{(0,0),(1e9, 1e9·YMax/XMax)}` (speed ≈ 0.00025); evaluating `<In>=89975` on that
ramp lands source frame **23** instead of the held **370** → `source_in` 347 f
low, and `source_out < source_in` (`dur=-1`, a malformed clip).

That wrong-low `source_in` drags the relink source extent 347 f before the
trim's real start → the spurious "partial / short at head" against media Resolve
made to match. Correct behavior: a freeze holds source frame 370, so
`source_in = 1248362 + 370 = 1248732` (= trim start) → relinks clean.

### Status: already root-caused, **blocked on Joe**

This is the bug tracked in `todo_023_retime_freeze_frame_source_in` (it names this
exact clip and the 347 f figure). The fix is known — in `decode_media_timemap`,
accept the freeze case (`YMin≈YMax`) and KEEP the flat keyframes — but it is
blocked on two decisions only Joe can make:

1. **Freeze source-span model.** A flat curve gives `in_frame = out_frame = 370`
   → `source_duration = 0` (`source_in == source_out`). The schema allows it, but
   does the renderer/decoder handle a 0-source-duration hold, or should a freeze
   be `source_out = source_in + 1` (read one frame, hold it)? Playback/model call.
2. **DRT export round-trip risk.** Touching the `decode_media_timemap` consistency
   check affects golden-round-trip tests (`test_drt_reverse_mtba_golden`,
   `test_drt_reverse_clip_roundtrip`) — export must still round-trip.

TDD plan when unblocked: build the A023 freeze clip (flat blob + `<In>=89975`),
assert `source_in == 1248732` and a sane `source_out` per the chosen model; re-run
the golden DRT tests.

---

## Other findings (not JVE bugs)

| Finding | Explanation |
|---------|-------------|
| 15 "not found" files | VFX renders, MXF raws, WAVs genuinely absent from search directory |
| `End Credit Scroll-V2-2048.tif` duration unreadable | Still image — EMP returns `has_video` with no duration. Now handled in the working tree: `probe_result_from_emp_info` sets `duration_frames = 1` (mirrors `Media.classify_is_still`), so the still is relinkable. Covered by `tests/synthetic/integration/test_relink_still_image.lua`. |

---

## Evidence quality

| Claim | Basis |
|-------|-------|
| Bug 1 fixed | `git show 7f9f9701` — `read_be64_signed` + `test_drp_binary_signed_offset.lua` |
| `partition_candidates` offset guard — code confirmed | Read `media_relinker.lua:1116-1128`; branch reachability verified (`:1100` viable path must miss first) |
| Bug 2 −1130 numbers | From the prior live relink report; NOT reproduced from a checked-in fixture this session |
| Bug 3 = legitimate J-cut (Candidate B) | **Verified** — `--test` diagnostic on `anamnesis-gold-timeline.drp`: C033 audio clip `src=[1280250..]` maps exactly (`delta=0`) 855 f before video `src=[1281105..]`; C031 9-f J-cut; same-range MOVs show audio==video |
