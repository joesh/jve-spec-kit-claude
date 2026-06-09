# Phase 1 — Test Overhaul (continuation of spec 020)

**Status**: Draft (2026-05-21). Sibling doc to `spec.md`; spec.md is the debug-terminal primitive (Phase 0, landed), this is its first consumer (Phase 1).

---

## Why this exists

Phase 0 shipped the debug terminal: long-running JVE accepts a Unix-socket connection, evaluates Lua, returns formatted results. That primitive solves three problems the existing test suite has:

1. **QShortcut activation gap.** `JVEEditor --test` boots Lua + Qt6 in-process but synthetic key events (`QApplication::sendEvent`, `QTest::keyClick`, even `CGEventPost` from inside) do not activate registered `QShortcut` objects — Qt's `QShortcutMap` requires spontaneous events from a foregrounded source process. Confirmed 2026-05-20. Hence the silent regression class (`I`, `E`, plain `Comma`/`Period` dead in the running app while 60+ executor tests stayed green). Driving from a separate process with real OS-level input solves it.
2. **Bring-up tax per test.** Every existing `tests/integration/test_*_smoke.lua` runs `JVEEditor --test` once, exits, repeats — Qt init + EMP + lua bootstrap re-paid per test. Suite-wide that's seconds-to-minutes of dead time. One long-lived JVE amortizes the bring-up across the whole suite.
3. **Mis-labelled "smoke" tests.** Per the rule pinned in `feedback_smoke_tests_real_keypress_only.md`, smoke = real OS input through the full activation surface. Most existing `tests/integration/test_*_smoke.lua` are pure-luajit data-layer tests with `smoke` in the filename. They're valuable Integration tests; they don't earn the smoke label.

This doc fixes all three.

---

## Test taxonomy

Six tiers, named for what they exercise, not for filename convention. Each tier picks a host process, a database posture, a Qt posture, and a target time budget.

| Tier | Host | Database | Qt | Time | What it covers |
|---|---|---|---|---|---|
| **Unit** | `luajit` | none | none | < 50 ms | One function, pure data. Math, parsers, formatters. |
| **Module** | `luajit` | tmp SQLite | none | < 100 ms | One module's public API, no cross-module wiring. |
| **Command** | `luajit` | tmp SQLite + real `command_manager` | none | < 200 ms | Executor + undoer round-trip via real command pipeline; no UI. |
| **Integration** | `luajit` | tmp SQLite | none | < 500 ms | Multi-module wiring (importer → resolver → renderer math; signal cascades). No real widgets. |
| **Binding** | `JVEEditor --test` | tmp SQLite (or seeded `.jvp`) | real Qt6 process | 1–5 s | Real widget creation, Qt signal/slot wiring, `qt_*` binding return values. Process exits when script returns. **Does not activate QShortcuts** — that's Smoke's job. |
| **Smoke** | **long-lived `JVEEditor --control-socket`** driven by external Python runner | Anamnesis template copy per test | real Qt6, foregrounded | 100 ms – 2 s per case once JVE is up | Real OS keypress / mouse / menu → full activation surface → state queried via socket. The only tier that proves the keymap → QShortcut → focus cascade actually works. |

The two practical tier boundaries:

- **Unit / Module / Command / Integration** stay on `luajit`. Fast iteration, no Qt, no process startup cost. Most tests live here. These are the tiers `make -j4` exercises today and will continue to.
- **Binding / Smoke** require real Qt. Binding uses one-shot `--test` (still fine for "does this widget instantiate"); Smoke uses long-lived control-socket + external runner (required for "does this key actually fire").

---

## Long-lived runner — architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  tests/live/runner/runner.py                                   │
│  ────────────────────────────────                               │
│  • Launches JVEEditor --control-socket /tmp/jve_test.sock once. │
│  • Foregrounds via `osascript -e 'tell app "jve" to       │
│    activate'` before any keypress test.                         │
│  • For each test:                                               │
│      1. socket.eval("OpenProject(<fresh Anamnesis copy>)")      │
│      2. test body — socket.eval(...) + cliclick/osascript +     │
│         socket.eval("return <state-query>")                     │
│      3. assertions on returned values                           │
│  • Tears JVE down at suite end (or on fatal corruption).        │
└─────────────────────────────────────────────────────────────────┘
              │  Unix-domain socket, newline-framed                │
              ▼                                                    │
┌─────────────────────────────────────────────────────────────────┐
│  JVEEditor (one process for the whole suite)                    │
│  ──────────────────────────────────────────                     │
│  DebugTerminal (spec.md FR-001..010) — single client.           │
│  Foregrounded. Real keymap, real QShortcuts, real focus.        │
└─────────────────────────────────────────────────────────────────┘
              ▲                                                    │
              │  Real OS-level input                               │
              │  • cliclick (key + mouse) for sub-second cases     │
              │  • osascript for menu invocation when keymap path  │
              │    isn't the thing under test                      │
              │  Issued from runner.py via subprocess.run().       │
              └────────────────────────────────────────────────────┘
```

The runner is one Python script (`tests/live/runner/runner.py`) plus a small library of per-test cases (`tests/live/test_*.py`). JVE itself is stock — no test code in the binary, no test-only modes beyond the existing `--control-socket` flag.

### Reset between tests

`project_changed` is already a fan-out signal with registered listeners at priorities 10/15/20/40/50 (playback_controller, offline_frame_cache, media_cache, timeline_state, source_viewer_state + timeline_panel + project_browser + layout + sequence_monitor). Reset = open a fresh project. No new mechanism.

```python
def before_each(self, test_id):
    src = self.fixtures.anamnesis_template     # read-only
    dst = self.scratch_dir / f"{test_id}.jvp"  # writable copy
    shutil.copy(src, dst)
    self.eval(f'require("core.open_project").execute({{ project_path = "{dst}" }})')
```

Cost: one file copy (~few MB) + one project-open (~tens of ms). That replaces a full process spawn + Qt init + binding registration (~seconds). Two-orders-of-magnitude speedup on suite wall time.

### Real keypress delivery

**macOS Accessibility prerequisite.** Whatever process spawns the runner (Terminal, iTerm, your IDE, ssh shell) needs to be granted **Accessibility** permission in *System Settings → Privacy & Security → Accessibility*. Without it macOS refuses the keystroke event with osascript error `1002` ("not allowed to send keystrokes"). The runner detects this and raises with the fix location, so the first run on a new machine surfaces the requirement immediately.

**Delivery via `osascript keystroke` is sufficient** once JVE is a proper macOS .app bundle (see CMakeLists.txt `MACOSX_BUNDLE TRUE` + main.cpp `setActivationPolicy:Regular` + `activateIgnoringOtherApps:YES`). Pre-bundle, JVE was a raw binary at the default Prohibited policy; macOS refused to deliver synthetic events to it and `osascript … keystroke` dropped on the floor regardless of frontmost manipulation. Post-bundle, JVE is recognised as a foreground-policy app and the same osascript path delivers real OS-level events that fire Qt's QShortcuts exactly like physical keystrokes. Empirically verified 2026-05-24 via an in-process Qt KeyStateWatcher seeing the events.

```python
def key(self, combo):       # e.g. "Cmd+Z", "Shift+I"
    keystroke = _combo_to_osascript_keystroke(combo)
    subprocess.run(["osascript", "-e",
                    f'tell application "System Events" to {keystroke}'],
                   check=True)
```

**Mouse clicks: cliclick, not osascript** (revised 2026-05-30). The original spec said osascript was sufficient. It is not, once the command-completion barrier (above) is in place: osascript's `tell System Events to click at {x,y}` posts the CGEvent and then BLOCKS waiting for the frontmost app to acknowledge — when JVE is mid-command (which becomes the common case immediately after the barrier returns), the ack stalls and osascript times out at 5 s. vm10 measured 72 × 5 s click timeouts on a 153-test run (~360 s of pure wall-time waste).

`cliclick c:x,y` calls `CGEventCreateMouseEvent` + `CGEventPost(kCGHIDEventTap, …)` directly — the event drops into the HID queue and cliclick returns. No daemon, no ack-wait. Latency ≈ 5 ms. Install via Homebrew (`brew install cliclick`); the runner resolves the binary at module-load time (`/opt/homebrew/bin/cliclick` on Apple Silicon, `/usr/local/bin/cliclick` on Intel, or `JVE_SMOKE_CLICLICK` override) and raises a clear install-hint error if absent.

Keystrokes stay on osascript: cliclick's key support is limited to plain chars + a small set of named keys, and ack-wait is not a problem in practice for keystrokes (osascript key timeouts in vm10: 3-4 vs 72 for clicks). Mixed-tool delivery — clicks via cliclick, keys via osascript — is the supported model.

**Coexistence with concurrent user input — two supported paths.** macOS keystrokes go to the OS-level frontmost app with no per-process targeting. Two collision directions matter:

  1. **Test → user**: if anything other than JVE is frontmost when `key()` fires, the keystroke lands in the user's app (e.g., a Cmd+F press opens the user's IDE Find dialog).
  2. **User → test**: if the user types while JVE is frontmost for a press, their keystroke is fed to JVE, potentially firing a different binding mid-test.

We tried an in-process per-press grab-press-restore (commits 766fb954..e4ccd679, reverted 2026-05-25): single-osascript sandwich captured the prior frontmost, grabbed JVE, fired the keystroke, restored. Three sequential refinements (200 ms delays → 0 ms → asymmetric 0/20 ms with per-press capture) reduced overhead to ~3 s on a 138-keystroke suite. The remaining problems made it unusable: the restore worked for some target apps (Finder) but silently dropped for others (ghostty/terminal-class) without a clear pattern, and the residual focus blink was perceptually jarring even at 20-30 ms windows. The grab approach was a stopgap and is gone.

The two supported execution environments are now:

  * **Host, JVE frontmost, hands-off keyboard.** Best for ad-hoc single-test debugging — quick to spin up, no extra setup. The user must not touch the keyboard while smoke runs; if they do, their keys feed into JVE and may collide with the test under way. Run length should be bounded (one test, not a full suite) so the hands-off window stays short.
  * **UTM macOS guest with captured keyboard.** Best for full suites or parallel use. JVE + runner live inside the guest; the host's keyboard input feeds the host's apps. The guest's keyboard capture (Ctrl+Option to release) means the user can flip in and out of the guest at will without collision. See the VM-guest runbook below.

[memory/feedback_smoke_tests_real_keypress_only.md] documents why bypassing real keystrokes (in-process synthetic events, CGEventPostToPid) is not an option — Qt's QShortcut activation requires spontaneous events from a foregrounded source process.

Menu invocation goes through `osascript` (`tell app "System Events" to click menu item ...`) when the test is asserting the menu surface itself rather than the keybinding.

### UI action → command-completion barrier (1:1)

Joe contract (2026-05-29): every UI action provokes a command. Once the root command completes, the UI is ready for the next action. The harness enforces this 1:1 by snapshotting a monotonic counter before every input and blocking until it bumps.

JVE side: `core.command_manager` exposes `get_top_level_event_count()`. The counter bumps on the trailing edge of each top-level `end_command_event` (covers `execute` / `execute_interactive`) and on `undo_interactive` / `redo_interactive` (which bypass the begin/end envelope). Nested executes inside a single user-visible action do NOT bump — one user action, one bump.

Wait is fully **event-driven**: one socket round-trip, no polling on either side, no spinning in Lua. The protocol gets a dedicated verb `WAIT_BUMP <snap> <timeout_ms>` that the debug terminal routes directly (NOT as a Lua expression):

- If `command_manager.get_top_level_event_count() > snap` already, the terminal replies `true,<count>` immediately.
- Otherwise it parks the wait: stores `(snap, m_client)`, arms a single-shot `QTimer` for `timeout_ms`, and returns to the Qt event loop **without writing a reply**. Qt processes events normally — clicks/keys dispatch, commands run, listeners fire, etc.
- When `command_manager` next bumps the counter (trailing edge of `end_command_event` / `undo_interactive` / `redo_interactive`), it invokes `_jve_on_top_level_event(count)` — a C function the debug terminal registered as a Lua global at start. That C function calls `DebugTerminal::notifyTopLevelEventBumped(count)`; if there's a pending wait and the new count exceeds the snap, it writes `true,<count>` and cancels the timer.
- If the timer fires first, the terminal writes `false,<count>` and clears the pending state.

Either way, exactly ONE line comes back per WAIT_BUMP — the same shape every other `eval()` reply has, so the harness uses the existing read path.

Two prior attempts taught the design: client-side polling (2026-05-29 vm9) added ~75% suite wall time from per-poll socket round-trips. Server-side Lua spin pumping events in a `while` loop (2026-05-30) made JVE beachball — the Lua call holds the main thread for the duration of the spin, so other Qt-mainloop work can't interleave. The deferred-reply design avoids both: the wait happens entirely in Qt event-loop machinery (`QTimer`, signal/slot) with no Lua-side blocking and no client-side iteration.

Harness side: `JVERunner.get_command_count()` reads the counter via Lua eval (unchanged). `JVERunner.wait_for_command_after(snap, timeout=0.5)` sends the `WAIT_BUMP` line and parses the reply. Both `key()` and `click_clip()` apply this barrier automatically. Raw `click()` does NOT — callers that send non-commanding input (dialog button, focus-only click) skip the barrier.

Single-flight: at most one WAIT_BUMP at a time per connection (matches the single-client protocol invariant). A second WAIT_BUMP while one is pending fails loudly with an ERROR reply rather than queuing or silently overwriting.

`key()` accepts `expect_command=False` for inputs that intentionally do not reach JVE — the canonical case is keystrokes typed INTO a frontmost macOS native dialog (e.g. NSOpenPanel's Cmd+Shift+G "Go to folder" prompt, the typed path, and the dialog's Return → Open button). The OS dialog consumes the key; JVE never sees it and no command fires. Callers using that path must do their own wait-for-result polling (see `pick_file_in_open_dialog`'s post-dialog responsiveness loop). The default stays `expect_command=True` so an accidental lost keystroke surfaces as a barrier timeout, not as a mystery downstream assertion.

Replaces the prior 50 ms post-input `time.sleep`. The sleep was a guess; the barrier observes the actual completion event, so tests no longer race in-flight dispatch and there is no silent-failure mode (an input that fires no command surfaces as a `wait_for_command_after` timeout, not as a mystery assertion downstream).

### UTM macOS guest runbook (isolated execution path)

Setup is one-time. The guest is **runtime-only** — it does NOT build JVE. The host builds (faster CPU, deps already present, no virtio/rsync cache hazards on the cmake tree); the host-built **self-contained** `jve.app` is pushed to the guest, and the guest just executes the smokes. The `.app` carries everything JVE needs at runtime: Qt frameworks (via macdeployqt), `src/lua` + `keymaps` + `resources` bundled into `Contents/Resources/` by a CMake `POST_BUILD` rsync step, and the one required Lua C module (`lxp.so` / LuaExpat) copied into `Contents/Resources/lua_modules/` and added to `package.cpath` by `ResourcePaths::setupLuaPackagePaths`. Only the Python smoke runner and DRP fixtures are pushed alongside — they live outside the .app because they drive it, not because the app needs them. This avoids duplicating the C++/Qt toolchain inside the guest and sidesteps an earlier path (2026-05-25) where guest-side cmake state got corrupted by stale shared-FS state.

**One-time guest setup.**

1. **Install UTM on the host.** `brew install --cask utm` (or download from getutm.app).
2. **Create the guest VM.** UTM → Create New → Virtualize → macOS → "Download a preinstalled image" picks the latest Apple-supplied IPSW from the gallery (no Apple-ID required). Allocate ≥4 GB RAM, ≥40 GB disk, ≥2 CPU cores — runtime-only is far less demanding than the original build-in-guest plan.
3. **Boot, install macOS, create a user account.** Standard installer flow. Skip iCloud sign-in (not needed; reduces guest noise). Disable screen sleep so the guest doesn't lock mid-suite.
4. **Inside the guest: install runtime deps only.** Self-contained `.app` (macdeployqt-bundled Qt frameworks) means no Qt/cmake/compiler in the guest:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install python@3 luajit
   brew install --cask ghostty  # or whatever terminal you use
   ```
   (`luajit` only if a smoke shells out to standalone Lua; in-process the bundled LuaJIT is fine. `python@3` is the smoke runner.)

   **Blackmagic RAW SDK** — required separately. `src/editor_media_platform/src/impl/braw_decode.cpp` hardcodes the dispatch path `/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries`, so the guest needs the same package installed in the same place. Download the Blackmagic RAW installer from blackmagicdesign.com (free; registration may be required) and run it inside the guest. Verify with `ls "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/BlackmagicRawAPI.framework"`. Without this, any smoke that touches a BRAW media file fails with a dispatch-load error.
5. **Set `JVE_SMOKE_IN_VM=1` in the guest's shell config** (`~/.zshrc` or equivalent). This flag does two things in the guest, both of which depend on the "no competing apps on the guest desktop" invariant: (a) skips the host-only window-tuck that hides JVE in the bottom-right corner — tucking is pointless in the VM and just makes JVE harder to see; (b) skips the runner's `osascript "tell System Events to set frontmost"` foregrounding call, because `main.cpp`'s `activateIgnoringOtherApps:YES` already makes JVE frontmost at launch and nothing in the VM can steal focus from it.

   The second point matters operationally: it means **no Accessibility permission is needed** in the guest. The host setup requires Accessibility for the terminal because the host has competing apps and the runner needs `System Events` to re-foreground; the guest does not. As a bonus, this lets the entire smoke suite run over `ssh` (sshd has no Accessibility and should never have it).
6. **Host: enable Remote Login on the guest.** System Settings → General → Sharing → Remote Login ON. Note the guest's hostname (default `joes-virtual-machine.local`) and the bridge IP (`192.168.64.x`).
7. **Host: generate an SSH key + push it to the guest.** One-time:
   ```bash
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/jve_vm -C jve-vm-sync
   ssh-copy-id -i ~/.ssh/jve_vm.pub joe@joes-virtual-machine.local
   ```
   (Or paste the pubkey from `cat ~/.ssh/jve_vm.pub` into the guest's `~/.ssh/authorized_keys` — clipboard sharing makes this easy once you've installed UTM guest tools.)
8. **First push from host.** Build on the host as usual, then push the bundle + smoke runner to the guest:
   ```bash
   # On host:
   make -j4                  # produces self-contained build/bin/jve.app
   scripts/sync-to-vm.sh     # pushes .app + tests/live + DRP fixtures
   # In guest:
   cd ~/jve && python3 -m pytest tests/live/cases/
   ```
   Per-edit loop is host-edit → `make jve -j4` → `sync-to-vm.sh` → guest pytest. Lua-only edits still require `make jve -j4` because the CMake post-build rsync re-bundles `src/lua` into `jve.app/Contents/Resources/` — the .app being self-contained is the whole point, so there is no shortcut path that ships loose Lua to the guest.

   **Why rsync the artifact, not virtiofs/SMB the source?** UTM directory-share (virtiofs) and SMB both serve stale host-modified files to the guest in practice — virtiofs's cache=auto mode doesn't reliably invalidate on host writes (no cache=none knob exposed by Apple's `mount_virtiofs` or by UTM), and macOS's SMB client caches aggressively. Two iterations (2026-05-25) hit "host edit not visible in guest" stalls on both. rsync eliminates the shared-filesystem layer entirely. See `scripts/sync-to-vm.sh` for the exact includes/excludes.

**Per-run loop (post-setup).**

* Edit code on the host as usual. Rebuild if C++ changed (`make jve -j4`); skip if Lua-only.
* Push: `scripts/sync-to-vm.sh` from the host.
* Inside the guest terminal:
  ```bash
  cd ~/jve && python3 -m pytest tests/live/cases/
  ```
* Use the UTM guest window for runs you want to watch; capture-keyboard mode (Ctrl+Option to release) lets the guest fully own input without any chance of leakage to the host. Click anywhere outside the guest window OR hit Ctrl+Option to release the keyboard back to the host.

**Why this works where the in-process grab didn't.** macOS keystroke routing is per-bootstrap-namespace. The guest's WindowServer has its own frontmost concept entirely independent of the host's; UTM's keyboard-capture API plugs the host's HID stream into the guest's input system only while the guest window is focused-and-captured. There is no shared global frontmost between host and guest, so collision is structurally impossible — not "small with mitigations" like the grab approach.

### Wire protocol

Re-using spec.md's existing framing — newline-delimited Lua, newline-delimited response, `jve> ` prompt. Python side:

```python
def eval(self, lua_chunk):
    self.sock.sendall(lua_chunk.encode() + b"\n")
    return self._read_until_prompt()  # accumulates until "\njve> "
```

Returns the formatted-value line (or `ERROR: …`). Test code parses with `repr`-style ad-hoc — no JSON layer. The repr cap from spec.md FR-005 (32 table entries, 3 depth levels, 256-char strings) is the contract the runner reads against.

For state queries beyond the cap (a 500-clip sequence's full clip list), tests `return` an iterable shape that the runner can fetch chunked:

```python
n = int(self.eval("return #clips"))
for i in range(1, n + 1):
    yield self.eval(f"return clips[{i}].id")
```

Single client, synchronous, one request → one response. No subscriptions, no streaming.

---

## Runner language — Python

stdlib `socket` (AF_UNIX, SOCK_STREAM) + `subprocess` (osascript; cliclick as future fast-path) + stdlib `unittest` covers everything. Zero new install on a typical dev mac — no `pip install`, no virtualenv. unittest test classes are pytest-discoverable as-is, so a future move to pytest stays a one-line `pip install` away. Considered Lua: keeps one-language discipline but `osascript` shell-out plus socket framing in pure LuaJIT is unergonomic, and the test fixture file (`anamnesis-gold-timeline.drp`) is binary-handled by external tools anyway. Python pays for itself in test-author ergonomics.

Boundary: Python lives only under `tests/live/runner/` and `tests/live/test_*.py`. JVE never imports Python. No build dependency. Runner ships as a Python script; CI installs `cliclick` from Homebrew on macOS runners.

---

## Test lifecycle

```python
class JVESmokeSuite:
    @classmethod
    def setUpClass(cls):
        cls.jve = launch_jve(socket_path="/tmp/jve_test.sock")
        cls.jve.wait_for_socket(timeout=10)
        cls.jve.foreground()                  # osascript activate
        cls.fixtures = Fixtures(anamnesis_template_path)

    def setUp(self):
        scratch = self.fixtures.fresh_copy(self.id())   # /tmp/jve_smoke_<test>/A.jvp
        self.jve.eval(f'require("core.open_project").execute({{ project_path = "{scratch}" }})')
        self.jve.foreground()                  # in case a prior test focus-stole

    def test_extend_edit_E_key(self):
        # Position selection on an out-edge.
        self.jve.eval('require("ui.timeline.timeline_state").set_selected_edges({{clip_id="c1", edge_type="out", trim_type="ripple"}})')
        # Move playhead to a known frame.
        self.jve.eval('require("core.command_manager").execute("MovePlayhead", {_positional={"100f"}})')
        # Press E for real.
        self.jve.key("e")
        # Black-box assertion — clip duration changed.
        new_dur = int(self.jve.eval('return require("models.clip").load("c1").duration'))
        self.assertEqual(new_dur, 100 - clip_start_pre)

    @classmethod
    def tearDownClass(cls):
        cls.jve.shutdown()
```

### Startup readiness gate

`JVERunner.start()` does NOT return as soon as the debug socket appears. The `QLocalServer` starts listening early in JVE startup — before Qt's first paint + layout pass completes. On the VM that gap is ~99 ms, during which the video panel widget shifts ~48 px down once. A `click_clip()` computed in that pre-jump window lands off the clip after the shift (no clean detection from inside the test — the click fires `DeselectAll` on the empty space it hits, the command-completion barrier sees the bump, and the next key press operates on empty selection).

`start()` therefore polls `video_widget`'s global Y until two consecutive 50 ms samples agree before returning. Adds ~100-200 ms once per JVE process. Hard-failures (3 s) with a clear diagnostic if the layout doesn't settle.

The cleaner long-term fix is JVE-side — defer `m_server->listen()` until the main window's first layout pass settles (most readable: a Lua trigger from `ui/layout.lua` after `event_loop_start`). Tracked at [memory/todo_jve_socket_accept_after_layout.md].

### Failure isolation

If a test corrupts JVE state badly enough that the next `OpenProject` can't recover (assertion in a non-pcall'd panel handler, hung modal, etc.), the runner notices (eval times out or returns ERROR repeatedly) and respawns JVE. A single-test failure does not poison the rest of the suite.

Timeout: 5 s per `eval` is generous (most return in < 50 ms). A single eval timeout → kill JVE immediately and mark the current test errored; the next test's `setUpClass`/`_ensure_runner` respawns a clean process. (Previously specified as "three consecutive timeouts"; revised 2026-05-25 because once an eval times out, the runner is in an unknown state — the pending Lua chunk may still complete and corrupt the next read's framing. One-shot kill is simpler and avoids the framing race; transient slowness is rare enough in practice that the lost retries cost nothing.)

---

## Fixtures — Anamnesis

`tests/fixtures/resolve/anamnesis-gold-timeline.drp` (small, lots of clips, both V+A) is the canonical template. The runner imports it once on suite start, saves as `/tmp/jve_smoke_template.jvp`, and copies that .jvp per test. Avoids paying DRP-import cost per test.

```python
def build_template():
    scratch = "/tmp/jve_smoke_build.jvp"
    jve = launch_jve(socket_path="/tmp/jve_smoke_build.sock")
    jve.eval(f'create_empty_project("{scratch}")')
    jve.eval(f'require("core.commands.import_resolve_drp").execute({{ drp_path="{anamnesis_drp}", project_path="{scratch}" }})')
    jve.shutdown()
    return scratch  # = template for all smoke runs
```

Built once per CI run, cached across local dev runs (invalidate on DRP fixture changes via hash).

The larger `anamnesis joe edit.drp` template is available for tests that need many sequences / tabs; opt-in via test class attribute.

---

## Per-existing-test recategorization

Every file in `tests/integration/test_*_smoke.lua` was audited against the new taxonomy. Most are mislabelled (no Qt, no real input — they're Integration). The actual Smoke tier starts empty; Phase C builds it from real user journeys.

| Existing file | Real tier | Notes |
|---|---|---|
| `test_001_m1_foundation_smoke.lua` | **Integration** | Pure SQLite round-trip; no Qt. Rename to drop `_smoke`, move to `tests/integration/` (already there). |
| `test_003_find_smoke.lua` | **Module** | `query_engine` + `find_state` black-box. No real Find dialog. |
| `test_004_keyboard_arch_smoke.lua` | **Module** | Registry loads TOML, exposes bindings — data only. Real keypress coverage moves to new Smoke test. |
| `test_005_gap_as_clip_smoke.lua` | **Integration** | Resolver output for gap-spanning ranges. |
| `test_006_per_sequence_undo_smoke.lua` | **Command** | Two-sequence undo stack independence; no UI. |
| `test_007_waveform_smoke.lua` | **Unit** | `visible_source_range` math. Trivially small. |
| `test_008_bounded_edit_region_smoke.lua` | **Integration** | Edit-cost perf; SQL + command_manager, no widgets. |
| `test_009_drp_file_original_tc_smoke.lua` | **Module** | Schema column accepts independent value. |
| `test_010_no_active_sequence_smoke.lua` | **Integration** | timeline_state + persistence — touches `ui.layout` import paths but doesn't drive widgets. |
| `test_012_inspector_clip_smoke.lua` | **Module** | `inspectable.clip` adapter shape. |
| `test_013_nested_placement_smoke.lua` | **Integration** | Drag → master resolver chain; no real Qt drag. |
| `test_014_two_phase_project_switch_smoke.lua` | **Integration** | Signal sequencer ordering; binding tier optional. |
| `test_018_t054_overwrite_audio_audible_smoke.lua` | **Binding** | Needs real EMP/TMB/audio. Stays in `JVEEditor --test`. |
| `tests/test_dsl_roll_smoke.lua` | **Command** | DSL → command_manager → undo round-trip. |
| `tests/test_smoke_run_app.sh` | **Binding** | Smoke-launches JVE and checks it doesn't crash on boot. Already process-spawn; leave as a shell-based binding test or fold into Phase A. |
| `tests/binding/test_019_source_viewer_integration.lua` | **Integration** | Self-labelled "NOT a smoke test by the strict definition" — accurate. |

Mechanical action: rename to drop `_smoke` suffix, move into matching folder (`tests/{unit,module,command,integration,binding}/`). One commit per tier batch.

---

## Coverage axes — three orthogonal surfaces

The suite must cover three independent things. A single test typically hits one axis well and the others incidentally; the CI guards enforce that each axis is exhaustively covered.

### Axis 1 — every registered command

`src/lua/core/command_registry.lua` is the canonical surface for everything the editor can do. Every entry has a test at the appropriate tier:

- **Pure-data command** (no UI side-effects beyond persisted model state) → Command tier. Executor happy-path + undoer round-trip + at least one error path (per CLAUDE.md NSF). Black-box: load via `Clip.load` / `Sequence.load` after execute and assert the model.
- **Interactive command** (the kind you bind to a key or menu) → Command tier as above PLUS Smoke coverage of at least one invocation surface (key or menu) that reaches it. Catches the dispatch-chain regressions that drove this whole arc.
- **Non-undoable command** (`SPEC.undoable = false`) — same as above minus the undo half.

CI guard `tests/live/runner/coverage.py` walks `command_registry.lua` + `src/lua/core/commands/`, then matches against test files under `tests/command/` (canonical) **or** `tests/test_<snake>.lua` / `tests/test_<snake>_*.lua` (legacy variant naming, accepted during the migration window). Missing → fail. Once the reorg moves all legacy variants into `tests/command/`, the legacy path falls out of the matcher.

### Axis 2 — every keymap entry

Already covered above as Phase A. Each `(combo, scope)` pair in `keymaps/default.jvekeys` gets a Smoke test that physically presses the key and asserts the model side-effect. `check_keymap_coverage.py` enforces.

### Axis 3 — every menu item

Phase B. Each menu entry gets a Smoke test that drives the menu via `osascript`. `check_menu_coverage.py` enforces.

The three guards run in `make smoke-coverage` and gate CI.

---

## Real editor workflows — Phase C, not deferred

End-to-end user journeys are the part of this overhaul that catches the regression class neither axis 1/2/3 nor unit tests reach: **interactions across multiple subsystems where each subsystem's local test passes but their composition is wrong**. Examples that have bitten this codebase:

- DRP import + sequence_monitor playhead → start-boundary assert on first navigate (TSO 2026-05-20).
- Source viewer load + engine bind + first jog → engine-state mismatch with view (fixed in 019 by parking engine at clip.source_in).
- I/O key wiring → command dispatched correctly in isolation, did nothing in the real app for two weeks (motivated this entire spec).

Journey tests are written from the **user's** perspective — what would the user notice if this broke? They are NOT exhaustive parameter-space tests of individual commands; they are end-to-end domain assertions ("after this sequence of inputs, the timeline shows X" / "the source viewer plays Y" / "the saved project reopens to Z").

### Initial journey list

Each is one test file. Black-box. Real OS input through cliclick + osascript; state queried via socket. List is starting set, not exhaustive — additions land per-feature.

1. **Cold-boot → empty welcome → new project → first edit.** Click "New Project", pick a name, drop a media file in the browser, drag to V1, save, reopen, the clip is there with the right source range.
2. **DRP import end-to-end.** File → Import → pick anamnesis DRP. Wait for the import. Tab count matches DRP's `<Timelines>`. Clip count on the gold sequence matches the DRP's `<Clips>`. Open one clip, scrub, audio is audible.
3. **Three-point edit from source viewer.** Shift+F to load a timeline clip into the source viewer, Mark IN (I), navigate (Right arrow), Mark OUT (O), focus timeline, press Insert key — clip lands at playhead with the marked source range.
4. **Trim cycle.** Select clip out-edge, press E to extend to playhead, press Cmd+Z to undo, press Cmd+Shift+Z to redo. All three model states match what the user would see in the timeline (durations + sequence_start values).
5. **Ripple vs Overwrite trim discrimination.** Toggle trim mode, perform the same I-key trim, observe model differs (ripple shifts downstream; overwrite absorbs neighbors).
6. **Relink.** Import a project, move the source media to a new path, click Relink, point at the new path, playback resumes at the same source frame.
7. **Nested sequence round-trip.** Select clips, "Nest into new sequence", double-click the nest, edit inside, navigate back via tab, parent reflects edits on reopen.
8. **Multi-tab project state persistence.** Open 3 sequences as tabs, set distinct playheads and marks per tab, close project, reopen, all three tabs restored with their per-tab playhead and marks.
9. **Cross-rate edit (Insert 24fps source into 25fps sequence).** Three-point Insert with rate mismatch lands exact-integer durations; the cross-rate ghost mark displays without asserting (FR-036/037/038 + the floor-mode ghost).
10. **Undo isolation across sequences.** Edit in A, switch to B, edit in B, switch back to A, undo — only A's cursor walks.

Phase C kicks off in parallel with Phase A Tier 1; the two share the runner and fixtures. A journey test catches what 50 isolated tests miss.

---

## Phases

### Phase A — Binding-test stubs for every keymap entry

`keymaps/default.jvekeys` has ~80 active bindings. One binding test per key (or per chord), ordered by frequency-of-use. Each test:

1. Launch via long-lived runner.
2. Open Anamnesis copy with a known selection / playhead state seeded.
3. Press the real key via cliclick.
4. Assert the model side-effect domain-style (clip moved, mark set, panel focus changed) — NOT internal call counts.

Order:
1. **Tier 1 (this week)** — keys with confirmed silent-regression history: `I`, `O`, `E`, plain `Comma`, plain `Period`, `Shift+,`, `Shift+.`, `Shift+F`, double-click, `Grave`.
2. **Tier 2** — transport: `Space`, `J`/`K`/`L`, `Home`/`End`, `Left`/`Right`, `Up`/`Down`.
3. **Tier 3** — edits: `B` (blade), `T` (roll), `[`/`]`/`'`, `Delete`/`Backspace`, `Cmd+X`/`C`/`V`.
4. **Tier 4** — long-tail: every remaining binding, mechanical pass.

A keymap entry without a corresponding binding test → CI fail. See **CI guard** below.

### Phase B — Menu-item coverage

Every entry in `src/lua/ui/menus/*` exercised via `osascript`-driven menu click. Same runner; same assertion shape.

Deferred until Phase A is at least Tier 1+2 — the keymap path catches most regressions and is the primary user surface.

### Phase C — User-journey Smoke tests

Real end-to-end flows. Examples:

1. **Open project → load clip in source viewer → set marks → Insert → save → reopen → playhead at edit point.**
2. **Import DRP → confirm clip count + tab count match Resolve's EDL export.**
3. **Relink against trimmed media → playback resumes at correct source frame.**
4. **Open clip in source viewer (Shift+F) → trim via I → undo restores both clip and playhead.**
5. **Nest selection into new sequence → double-click nest → editing nested sequence reflects in parent on reopen.**

Each journey = one test file. Black-box: assert what the user would see, not which internal functions ran.

---

## CI guard

`tests/live/runner/check_keymap_coverage.py` walks `keymaps/default.jvekeys`, parses every binding, and checks that `tests/live/test_keymap_*.py` contains at least one test referencing each `(combo, scope)` pair. Missing → exit non-zero. Wired into `make -j4` so regressions don't merge.

Similar guard for menu coverage in Phase B.

---

## Files to create

```
tests/live/runner/runner.py                     [NEW] launcher + socket client + helpers
tests/live/runner/cliclick.py                   [NEW] key/mouse translation layer
tests/live/runner/fixtures.py                   [NEW] Anamnesis template build + per-test copy
tests/live/runner/check_keymap_coverage.py      [NEW] CI guard
tests/live/runner/conftest.py                   [NEW] pytest setUp/tearDown wiring
tests/live/test_keymap_*.py                     [NEW] Phase A binding tests
tests/live/test_menu_*.py                       [NEW] Phase B menu tests
tests/live/test_journey_*.py                    [NEW] Phase C user-journey tests
tests/{unit,module,command,integration,binding}/ [REORG] new tier folders; existing _smoke.lua files moved per table above
specs/020-debug-terminal/phase1-test-overhaul.md [THIS DOC]
Makefile / build/CMakeLists                      [MODIFIED] new `make smoke` target — sets up Anamnesis template, runs pytest
README.md                                        [MODIFIED] dev-onboarding update for the new test tiers
```

`make -j4` runs Unit/Module/Command/Integration/Binding (existing behavior). `make smoke` is opt-in (Phase A bring-up is non-trivial). CI runs both.

---

## Acceptance Criteria

- [ ] One long-lived JVE serves the entire smoke suite; no per-test process spawn for the common case.
- [ ] **Axis 1 — every command in `command_registry.lua` has a Command-tier test** (executor + undoer + at least one error path); interactive commands additionally have at least one Smoke invocation surface.
- [ ] **Axis 2 — every `(combo, scope)` in `keymaps/default.jvekeys` has a Smoke test** that physically presses the key and asserts a domain-level outcome.
- [ ] **Axis 3 — every menu item has a Smoke test** that drives the menu via osascript.
- [ ] Phase A Tier 1 keys (`I`/`O`/`E`/`Comma`/`Period`/`Shift+F`/double-click/`Grave`) pinned by real-keypress tests that fail when the dispatch chain is broken.
- [ ] Phase C journey tests #1–#5 (cold boot, DRP import, three-point edit, trim cycle, ripple/overwrite discrimination) pass against the long-lived runner.
- [ ] Existing mislabelled `*_smoke.lua` files renamed + moved per the recategorization table.
- [ ] `make smoke` green on a fresh clone + Homebrew `cliclick`.
- [ ] `make smoke-coverage` fails CI when a registered command, keymap entry, or menu item is added without a corresponding test.
- [ ] Per-test wall time < 200 ms (excluding suite-start bring-up) for keypress smokes; < 2 s for journey smokes.

---

## Out of scope (explicit)

- **Cross-platform smoke.** Linux + Windows runners possible (QLocalServer works, real-input drivers differ). Defer until dev moves off macOS.
- **Parallel smoke runs.** Single long-lived JVE is single-client. Parallelism would need a per-shard JVE, which re-introduces bring-up cost. Defer.
- **Replacing `make -j4`.** Unit/Module/Command/Integration stay luajit; that's the fast inner loop. Smoke is a separate gate, not a replacement.
- **Recording / replaying sessions.** No event log, no time-travel debug. Out of scope for v1.
- **GUI test recorder.** Tests are written by hand. Recording is a possible later add but the unergonomic part is selectors and assertions, not the typing.

---

## Open questions

- ~~**Anamnesis template construction**~~ — **Resolved 2026-05-21**. Headless callers (build script, binding/integration tests) use `open_project._convert_drp_to_jvp(drp, jvp)` — the same primitive `OpenProject` drives once the user has picked a destination through its conversion dialog. Single-project .jvp in one pass; no placeholder. The convert orchestration was moved out of `drp_importer` (which is now format-knowledge only — `parse_drp_file`, `derive_project_settings`, `import_into_project`, `extract_tab_state`, `pick_majority_audio_sample_rate`) into `open_project.lua`, where it lives next to `resolve_format` and shares the DB-lifecycle ownership the command already had. The underscore-prefix on the test alias matches the existing fcp7-importer convention. `ImportResolveProject` is for *merging into an existing project*; a separate hardening change refuses it against a non-empty .jvp so the misuse that triggered this work fails loudly next time.


- **`cliclick` vs `osascript` for keys.** `cliclick` is faster + cleaner per-keystroke; `osascript` handles modifier combos that cliclick sometimes mis-encodes. Default = `cliclick`, fallback table for known cliclick gaps. *Recommendation: start cliclick-only, add fallbacks as bugs surface.*
- **Anamnesis template invalidation.** Hash the DRP fixture; rebuild template when hash changes. Manual rebuild via `make smoke-template`. *Recommendation: yes, hash-based; cheap.*
- **Eval timeout default.** 5 s is comfortable but a slow CI runner might hit it. *Recommendation: 5 s local, 15 s CI via env var.*
- **What about Wayland / non-foregrounded macOS sessions?** Headless CI runners need a windowed session. *Recommendation: CI requires a logged-in graphical session (macOS Catalina+ supports this via UI test runners); document the setup.*
- **Do we want the existing `_smoke.lua` files renamed in one commit or per tier?** Renaming touches imports / test runner globs. *Recommendation: per-tier batch (5 commits) — keeps diff reviewable.*

---

## Cross-references

- `specs/020-debug-terminal/spec.md` — the debug-terminal primitive (Phase 0).
- `feedback_smoke_tests_real_keypress_only.md` (memory) — the rule this plan implements.
- `feedback_test_with_editor.md` (memory) — `--test` mode usage for Binding tier.
- `feedback_always_run_smoke_test.md` (memory) — workflow rule: if a spec mentions a smoke test, write + run it.
- `feedback_tests_from_domain.md` (memory) — domain-behavior assertions, not implementation tracing.
