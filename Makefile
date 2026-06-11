# Root Makefile wrapper - forwards commands to build directory
# This allows running `make` from the project root

BUILD_DIR = build

# ---- Per-checkout serialization ------------------------------------------------
# Two parallel Claude sessions in the SAME checkout would race on
# build/CMakeFiles state AND on the shared VM staging tree under
# scripts/_run_in_vm.sh (~/jve-* there) — observed as cmake artifact
# collisions on the host and SQLite "disk I/O error" on schema apply in
# the VM. Serialize via an atomic mkdir lock keyed by checkout path.
# Sessions in DIFFERENT checkouts hash to different locks and stay
# parallel.
LOCK_FILE := /tmp/jve-make-$(shell printf "%s" "$(CURDIR)" | shasum | cut -c 1-8).lock

ifndef JVE_MAKE_LOCKED
.PHONY: __lock_dispatcher
__lock_dispatcher:
	@$(CURDIR)/scripts/with_make_lock.sh $(LOCK_FILE) $(MAKE) JVE_MAKE_LOCKED=1 $(MAKECMDGOALS)

%: __lock_dispatcher
	@:

.DEFAULT_GOAL := __lock_dispatcher
else

.PHONY: all build clean install help configure reconfigure luacheck nav-index test \
        smoke smoke-coverage smoke-template jve lint scan install-hooks

# Default target: lint, build, and run all tests.
#
# Pipeline:
#   - luacheck runs in the background alongside the C++ build (~8s wall
#     overlapped, ~0s added).
#   - Tests run in two phases after build completes:
#     (A) lua + binding + helper (Python, offline-pure, <1s) in
#         parallel — all CPU-bound but short; max ≈ 12s.
#     (B) integration alone — its perf-sensitive batches assert on
#         wall-clock latency (p95 cadence ≤ 80ms); under parallel load the
#         thresholds flake. Dedicated CPU keeps them stable.
#   - Structuring A → B (not everything in parallel) avoids the ~30s
#     slowdown that N-way parallelism otherwise costs the perf batches.
# Fast-path: if `.last-clean-make` is newer than every input the full
# pipeline consumes, the previous green run still proves the tree is
# clean — skip lint+build+tests entirely. Shares the freshness
# comparator with hooks/pre-commit via scripts/check_clean_make.sh so
# the two gates can't drift. Sibling Claude sessions sharing the
# checkout benefit too: whichever one finishes `make -j4` first
# refreshes the marker, and the others' pre-commit gates pass without
# re-running anything.
all: configure
	@if { find src -type f \( -name '*.cpp' -o -name '*.mm' -o -name '*.h' -o -name '*.hpp' -o -name '*.lua' \) -print0; \
	      find tests -type f -name '*.lua' -not -path '*/autogen/*' -print0; \
	      find tools/resolve-helper -type f -name '*.py' -print0; \
	      find keymaps -type f -print0 2>/dev/null; \
	      find . -maxdepth 2 -name 'CMakeLists.txt' -not -path '*/build/*' -print0; \
	      printf 'Makefile\0'; \
	    } | scripts/check_clean_make.sh 2>/dev/null; then \
		echo "make: .last-clean-make newer than every source — nothing to do."; \
		exit 0; \
	fi
	@luacheck src tests > .luacheck.log 2>&1 & \
	 LUACHECK_PID=$$!; \
	 $(MAKE) -C $(BUILD_DIR) --no-print-directory; \
	 wait $$LUACHECK_PID; LUACHECK_RC=$$?; \
	 if [ $$LUACHECK_RC -ne 0 ]; then cat .luacheck.log; rm -f .luacheck.log; exit $$LUACHECK_RC; fi; \
	 rm -f .luacheck.log
	@$(MAKE) -C $(BUILD_DIR) lua_tests binding_tests helper_tests --no-print-directory -j3
	@$(MAKE) -C $(BUILD_DIR) integration_tests --no-print-directory
	@python3 tests/live/runner/coverage.py --axis keymap
	@touch .last-clean-make

# Build only (C++ compile + link, no tests, no lint)
build: configure
	@$(MAKE) -C $(BUILD_DIR) --no-print-directory

# Build just the jve executable + re-bundle its Resources (skips tests
# + lint). UI-iteration target. Forwards to bundle_runtime_tree, which
# transitively builds jve and then rsyncs src/lua + keymaps + resources
# + menus.xml into the .app — so Lua-only edits actually reach the
# bundled app on this fast path (POST_BUILD alone wouldn't fire when
# nothing links).
jve: configure
	@$(MAKE) -C $(BUILD_DIR) bundle_runtime_tree --no-print-directory

# Clean build artifacts
clean:
	@if [ -d "$(BUILD_DIR)" ]; then \
		$(MAKE) -C $(BUILD_DIR) clean --no-print-directory; \
	fi

# Install artifacts
install:
	@$(MAKE) -C $(BUILD_DIR) install --no-print-directory

# Run luacheck
luacheck:
	@luacheck src tests

# Run the anti-pattern linter (R001-R008) across all source.
# Per-rule docs: scripts/lint_anti_patterns.md. Exit 1 on any violation.
# Also wired into:
#   • .claude/hooks/lint_anti_patterns_post_edit.sh (in-session)
#   • .git/hooks/pre-commit (blocks new violations)
lint:
	@scripts/lint_anti_patterns.sh --all

# Clang static analyzer (scan-build). Slow (~10 min); run before merging
# substantial C++ changes, NOT in the per-edit loop. Uses isolated build-scan/
# tree so the normal build/ remains incremental. Exits 1 if issues found.
scan:
	@scripts/run_scan_build.sh

# ---- Smoke (spec 020 Phase 1) ----
# Long-lived JVE + external Python runner. See
# specs/020-debug-terminal/phase1-test-overhaul.md.

# Static coverage audit — every registered command / keymap entry /
# menu item has a corresponding test. No JVE launch; fast (<1s).
smoke-coverage:
	@python3 tests/live/runner/coverage.py

# Build the Anamnesis template .jvp that smoke tests copy per-case.
# Idempotent — re-runs only when the DRP fixture hash changes (or --force).
smoke-template: build
	@python3 tests/live/runner/build_template.py

# Run the Phase A/B/C smoke suite via stdlib unittest discovery.
# Requires: built JVEEditor binary + smoke-template up to date.
smoke: build
	@python3 -m unittest discover -s tests/live/cases -p "test_*.py" -v

# Configure CMake (automatic)
configure:
	@if [ ! -f "$(BUILD_DIR)/Makefile" ]; then \
		cmake -S . -B $(BUILD_DIR); \
	fi

# Force reconfiguration
reconfigure:
	@rm -f $(BUILD_DIR)/Makefile
	@cmake -S . -B $(BUILD_DIR)

# ---- Navigation indexes ----
# Generate ctags + JSON navigation indexes via CMake
nav-index:
	@$(MAKE) -C $(BUILD_DIR) nav-index --no-print-directory

# Point this clone's git hooks at the tracked hooks/ directory so the
# lint-allow gate (and any future shared hooks) fire for everyone.
# Idempotent. Run once per fresh clone / worktree.
install-hooks:
	@git config core.hooksPath hooks
	@echo "git hooks → $$(git config core.hooksPath)"

help:
	@echo ""
	@echo "Available targets:"
	@echo "  all          - Run luacheck then build (default)"
	@echo "  build        - Build only, skip linting"
	@echo "  clean        - Clean build artifacts"
	@echo "  install      - Install built artifacts"
	@echo "  configure    - Configure CMake (automatic)"
	@echo "  reconfigure  - Force CMake reconfiguration"
	@echo "  luacheck     - Run Lua lint (luacheck) across src/tests"
	@echo "  lint         - Anti-pattern lint (R001-R0NN; scripts/lint_anti_patterns.md)"
	@echo "  scan         - clang static analyzer (scan-build); slow, pre-merge only"
	@echo "  nav-index    - Generate navigation indexes (ctags, symbols.json, commands.json)"
	@echo "  smoke        - Run smoke suite (long-lived JVE + Python runner)"
	@echo "  smoke-template - (Re)build Anamnesis .jvp template smoke tests copy from"
	@echo "  smoke-coverage - Audit: every command/keymap/menu entry has a test"
	@echo "  install-hooks - Point git at the tracked hooks/ dir (once per clone)"
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Example usage:"
	@echo "  make            - Build and run all tests"
	@echo "  make clean      - Clean and rebuild"
	@echo "  make test       - Build and run tests"
	@echo "  make nav-index  - Generate navigation indexes"

endif  # JVE_MAKE_LOCKED
