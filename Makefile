# Root Makefile wrapper - forwards commands to build directory
# This allows running `make` from the project root

BUILD_DIR = build

.PHONY: all build clean install help configure reconfigure luacheck nav-index

# Default target: lint then build
all: configure luacheck
	@$(MAKE) -C $(BUILD_DIR) --no-print-directory

# Build only, skip linting
build: configure
	@$(MAKE) -C $(BUILD_DIR) --no-print-directory

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
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Example usage:"
	@echo "  make            - Build and run all tests"
	@echo "  make clean      - Clean and rebuild"
	@echo "  make test       - Build and run tests"
	@echo "  make nav-index  - Generate navigation indexes"
