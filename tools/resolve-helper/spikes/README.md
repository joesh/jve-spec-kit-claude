# Resolve-helper spikes

One-shot investigation scripts that drive real Resolve to answer a
question the spec couldn't settle on paper. Output goes into
`specs/023-resolve-color-bridge/phase0-findings.md` per task spec.

**Artifact location:** spike outputs go in `tests/fixtures/resolve/`
(co-located with the source-of-truth Resolve fixtures — kitchen-sink,
empty-reference, retime-test, etc.). JVE-regenerated artifacts are
gitignored there via `tests/fixtures/resolve/.gitignore`; the committed
Resolve-authored fixtures remain source-of-truth. The `/tmp/` path was
used briefly during the initial spike but doesn't survive a macOS
reboot — in-repo gives reproducible regeneration after any restart.

## T008 — canonical-shape DRT round-trip (Resolve-acceptance)

Once the canonical `drt_writer` lands, every JVE-exported DRP should
ride a Resolve File > Import > Project round-trip cleanly. Author the
test archive + probe:

```
# 1. Author the JVE-side DRP (single A005 clip with a known DbId)
./build/bin/jve.app/Contents/MacOS/jve --test \
    "$(pwd)/tools/resolve-helper/spikes/t008_author.lua"
# Produces tests/fixtures/resolve/jve_authored_single_clip.drp

# 2. In Resolve: File > Import > Project... > <repo>/tools/resolve-helper/
#    tests/fixtures/resolve/jve_authored_single_clip.drp
#    The .drp extension routes Resolve to the project importer (which
#    reads the SeqContainer XMLs); .drt extension would route to the
#    timeline importer (FCPXML/EDL-style) and produce an empty stub
#    timeline named after the file.

# 3. Probe — finds the imported timeline by name, dumps every *Id*
#    accessor on the clip, PASSes if the JVE-written DbId is found.
python3 tools/resolve-helper/spikes/t008_probe_canonical.py
```

## T008 — identity carrier survival

**Question:** when JVE authors a DRT carrying a known `clip.id`, which
carrier field survives a Resolve DRP-import round-trip byte-clean?
Candidates: `Sm2Ti*.DbId` attr, `<Name>` text, `<LinkedItemSync>`.

### Run

```
# 1. Author the spike DRT (3 clips × every candidate carrier)
luajit tools/resolve-helper/spikes/t008_author_drt.lua

# 2. In Resolve: File > Import > Timeline... > /tmp/jve/t008_identity.drt
#    (Resolve must be running; External Scripting enabled in Preferences.)

# 3. Probe via the Python API
python3 tools/resolve-helper/spikes/t008_probe.py
```

The probe prints a per-item table of which Resolve API field exposed
which sentinel (`JVE_<CARRIER>_<n>`), then a summary verdict for each
carrier. Append the verdict to `phase0-findings.md` and tick T008 in
`tasks.md`.

### Carriers and how the probe reads them

| Carrier | Author location | Read via Resolve API |
|---|---|---|
| `DBID` | `Sm2Ti*Clip.DbId` attr | `TimelineItem.GetUniqueId()`, or `MediaPoolItem.GetUniqueId()` if Resolve promoted it upstream |
| `NAME` | `<Name>` text | `TimelineItem.GetName()` |
| `LIS`  | `<LinkedItemSync>` text | *(writer-stubbed; not emitted today)* |

If `DBID` or `NAME` survives, that's the join field for T024
`SendToResolve` and downstream identity-ledger work. If neither does,
plumb `<LinkedItemSync>` through `drt_writer.build_clip_xml` and re-run.

### Why three sentinels in one archive (not three archives)

Joe drives Resolve by hand. Each variant = one File>Import click + one
probe run. Three carriers + three sentinels in a single archive = one
import, one probe, unambiguous attribution by sentinel format —
minimises UI overhead, no chance of two variants colliding.
