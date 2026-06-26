# Contract — DRT/DRP Members per Gap

For each gap: the `.drp`/`.drt` member(s) authored, the **Resolve-authored fixture** the
bytes derive from (FR-020), and the **byte-shape assertion** that gates it (member-
extraction idiom, research D8 — `fixture.unzip_member` + needle/count/length, NOT a
whole-file `==`). Every gap's test is written RED first (Constitution III).

| Gap / FR | Authored member(s) | Source fixture + phase0 § | Byte-shape assertion (RED→GREEN) |
|----------|--------------------|---------------------------|-----------------------------------|
| #1 audio TC / source range (FR-001/002/003) | `SeqContainer/*` `Sm2TiAudioClip` `<In>`, `MediaStartTime` | `retime-test.drt` §C; `media:get_audio_start_tc` | audio `<In>` = sample-accurate fractional (`int|hex_LE_double`); video `<In>` = whole frame = `source_in − start_tc_frame`. No content shift. |
| #2 Sm2MpAudioClip (FR-004/005/006) | `MediaPool/.../Sm2MpAudioClip.xml` | `resolve_authored_full.drp` §K2 | exactly one `Sm2MpAudioClip` per standalone audio media; child order matches; file-specific fields = media's (path/rate/channels/dur); fixed bytes = fixture. `.wav` accepted; bad type loud-fails (`pcall`). |
| #3 routing (FR-007/008/009) | timeline clip `VirtualAudioTrackBA`, `MediaTrackIdx` | §F (embedded/linked/standalone forms) | `MediaTrackIdx` per relationship (not constant 0); `VirtualAudioTrackBA` matches §F form for mono/stereo/synced. |
| #4 arbitrary video (FR-010/011/012) | plaintext-XML hex siblings: `<Geometry>` (Resolution = BE int64 w×h), `<TracksBA>` (embedded audio), `<Clip>` (path + codec `f5`), `<Time>` (rate/dur) — NOT the zstd `<FieldsBlob>` | gold `000_master clips/MpFolder.xml` (decoded D1); `<Time>`/`<Clip>` already authored | non-A005 video item carries its own resolution (`%016x%016x` w×h, the seq-resolution form), codec (from `media.codec`, not hard-coded `avc1`/`AAC`), embedded-audio, path; encode-and-substitute into the plaintext blob; fixed bytes unchanged; Resolve online. **Codec fold-in:** DRP importer extended to read `<Clip>` `f5` → `media.codec` (was empty); RED test asserts a non-h264 item authors its real four-CC. |
| #5 synced linkage (FR-013/014) | `Sm2MpVideoClip.FieldsBlob` linkage region | `synced clip example.drp` / A005 §J/§K4 (**D1 decode gate**) | synced WAV appears as virtual track N of the video item; round-trips which audio↔which video↔which track; **synthesized** not verbatim. Undecoded → loud fail. |
| markers (FR-015/016) | project.xml `Sm2TiItemLockableBlob/FieldsBlob` | `markers_16color_edge.drp` §E | one lockable blob per clip marker; NAME/NOTE/KEYWORD/color at §E offsets; 16-color enum honored. |
| regression (FR-022) | full A005 `.drp` | (current output) | A005 re-exported via general paths == current bytes (per-member). |
| acceptance interim (FR-021) | full gold `.drt`, non-synced subset | `anamnesis-gold-timeline.drp` | round-trip self-validation passes + per-member byte-shape for video/audio/range/routing on every non-synced clip. |
| acceptance full (FR-021) | full gold `.drt` incl. synced | `anamnesis-gold-timeline.drp` | interim + synced groups round-trip. Gated on D1. |

Notes:
- Tests use `synthetic.helpers.drt_spike_fixture` (`build_*_payload`, `unzip_member`,
  `plain_count`) — same harness as existing `test_drt_writer_*.lua`. No live Resolve.
- "Fixed where format is fixed" (FR-005/021): assert file-specific fields are *derived
  from media*, fixed-form fields *match the fixture* — never assert a derived field equals
  a fixture's literal value (that would re-introduce the borrow bug).
