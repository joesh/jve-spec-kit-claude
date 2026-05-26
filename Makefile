# Root Makefile wrapper - forwards commands to build directory
# This allows running `make` from the project root

BUILD_DIR = build

.PHONY: all build clean install help configure reconfigure luacheck nav-index test \
        smoke smoke-coverage smoke-template jve

# Default target: lint, build, and run all tests.
#
# Pipeline:
#   - luacheck runs in the background alongside the C++ build (~8s wall
#     overlapped, ~0s added).
#   - Tests run in two phases after build completes:
#     (A) lua + binding in parallel — both CPU-bound but short; max ≈ 12s.
#     (B) integration alone — its perf-sensitive batches assert on
#         wall-clock latency (p95 cadence ≤ 80ms); under parallel load the
#         thresholds flake. Dedicated CPU keeps them stable.
#   - Structuring A → B (not everything in parallel) avoids the ~30s
#     slowdown that N-way parallelism otherwise costs the perf batches.
all: configure
	@luacheck src tests > .luacheck.log 2>&1 & \
	 LUACHECK_PID=$$!; \
	 $(MAKE) -C $(BUILD_DIR) --no-print-directory; \
	 wait $$LUACHECK_PID; LUACHECK_RC=$$?; \
	 if [ $$LUACHECK_RC -ne 0 ]; then cat .luacheck.log; rm -f .luacheck.log; exit $$LUACHECK_RC; fi; \
	 rm -f .luacheck.log
	@$(MAKE) -C $(BUILD_DIR) lua_tests binding_tests --no-print-directory -j2
	@$(MAKE) -C $(BUILD_DIR) integration_tests --no-print-directory
	@python3 tests/smoke/runner/coverage.py --axis keymap

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

# ---- Smoke (spec 020 Phase 1) ----
# Long-lived JVE + external Python runner. See
# specs/020-debug-terminal/phase1-test-overhaul.md.

# Static coverage audit — every registered command / keymap entry /
# menu item has a corresponding test. No JVE launch; fast (<1s).
smoke-coverage:
	@python3 tests/smoke/runner/coverage.py

# Build the Anamnesis template .jvp that smoke tests copy per-case.
# Idempotent — re-runs only when the DRP fixture hash changes (or --force).
smoke-template: build
	@python3 tests/smoke/runner/build_template.py

# Run the Phase A/B/C smoke suite via stdlib unittest discovery.
# Requires: built JVEEditor binary + smoke-template up to date.
smoke: build
	@python3 -m unittest discover -s tests/smoke/cases -p "test_*.py" -v

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
	@echo "  nav-index    - Generate navigation indexes (ctags, symbols.json, commands.json)"
	@echo "  smoke        - Run smoke suite (long-lived JVE + Python runner)"
	@echo "  smoke-template - (Re)build Anamnesis .jvp template smoke tests copy from"
	@echo "  smoke-coverage - Audit: every command/keymap/menu entry has a test"
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Example usage:"
	@echo "  make            - Build and run all tests"
	@echo "  make clean      - Clean and rebuild"
	@echo "  make test       - Build and run tests"
	@echo "  make nav-index  - Generate navigation indexes"
