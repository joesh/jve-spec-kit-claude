# Quickstart — Full-Fidelity DRT Export Acceptance

Validates the feature end-to-end via the headless test path (no live Resolve, per the
contract rule). Each step maps to acceptance scenarios in `spec.md` and the byte-shape
assertions in `contracts/drt-members.md`.

## Prereqs
- Built editor: `cd build && make jve -j4` (or full `make -j4` for the gate).
- Fixtures present (de-evict iCloud first if needed —
  `cat "tests/fixtures/resolve/anamnesis-gold-timeline.drp" >/dev/null`).
- Tests run via the binding harness: `cd tests && luajit test_harness.lua synthetic/binding/test_drt_writer_<x>.lua`.

## Step 1 — Standalone audio exports (no crash) [Scenario 1, FR-001/002/004]
A sequence whose only media is a stereo `.wav` with a real TC origin.
- **Run:** the gap-#1 + gap-#2 byte-shape tests.
- **Pass:** export succeeds (no `payload_builder:150` assert); the `.drt` contains exactly
  one `Sm2MpAudioClip` for the wav; its `<In>`/`MediaStartTime` address the same audio
  content (sample-accurate); audio item online.

## Step 2 — Arbitrary video + standalone audio, each its own descriptors [Scenario 2, FR-010]
- **Run:** gap-#4 test on a non-A005 video + the gap-#2 audio item.
- **Pass:** every media item carries its **own** path/native-rate/resolution/codec/duration/
  embedded-audio (encode-and-substituted into its plaintext `<Geometry>`/`<TracksBA>`/
  `<Clip>`/`<Time>` descriptors, NOT the zstd FieldsBlob; codec four-CC driven by
  `media.codec`, not the hard-coded `avc1`/`AAC`) — none borrows A005's; Resolve treats all
  online.

## Step 3 — Channel routing preserved [Scenario 4, FR-007/008/009]
- **Run:** gap-#3 test across mono / stereo / synced clips.
- **Pass:** per-clip `MediaTrackIdx` + `VirtualAudioTrackBA` match the §F form for the
  relationship (embedded ch / linked synced / standalone) — not a constant mono→A1.

## Step 4 — Clip markers travel [FR-015/016]
- **Run:** markers byte-shape test.
- **Pass:** one `Sm2TiItemLockableBlob` per clip marker, NAME/NOTE/KEYWORD/color at §E
  offsets, 16-color enum honored. (Sequence markers absent by design — out of scope.)

## Step 5 — INTERIM GATE: non-synced gold subset [FR-021 interim]
- **Run:** export `anamnesis-gold-timeline.drp`'s non-synced clips; round-trip self-validate
  + per-member byte-shape.
- **Pass:** every non-synced video/audio clip online, correct source range + routing;
  round-trip validator green. **Gaps #1–4 + markers are demonstrably done here, independent
  of gap #5.**

## Step 6 — Synced V↔A linkage [Scenario 3, FR-013/014]  *(gated on Phase-0 D1 decode)*
- **Run:** gap-#5 test on a synced group.
- **Pass:** the synced WAV appears as a virtual track of the video's media-pool item, routed
  to the correct channel, round-tripping which audio↔which video↔which track — synthesized,
  not verbatim. **If D1 has not decoded the linkage region, a synced clip MUST loud-fail
  here (no fake sync).**

## Step 7 — FULL GATE: whole gold timeline [Scenario 5, FR-021]
- **Run:** export the full gold timeline (incl. synced groups); round-trip + byte-shape.
- **Pass:** Steps 5 + 6 across the entire timeline. This is the definition of done.

## Step 8 — Regression: A005 unchanged [FR-022]
- **Run:** re-export the single A005 test clip through the general paths.
- **Pass:** byte-identical (per member) to current output. Confirms the general path
  reproduces A005 and the old borrow/mono special-cases were deleted, not bypassed.

## Failure paths to exercise [FR-019, 2.32]
- Audio media with no TC origin → producer asserts with `media.id` (`pcall`, actionable).
- Synced clip while D1 undecoded → consumer loud-fails (no fallback).
- Unhandled audio type / compound clip / unexportable clip → loud fail naming it
  (compound is out of scope — must fail, never export wrong).

## Gate command
`make -j4` (the authority) must be green — includes the new `test_drt_writer_*` byte-shape
tests and the round-trip validator. Live-Resolve import is an optional manual spot-check only.
