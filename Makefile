JOBS ?= 4
# Prefer an explicit -j flag from the invoking make (e.g. `make -j8`).
# If not provided, fall back to JOBS (defaults to 4).
MAKE_NPROC := $(patsubst -j%,%,$(firstword $(filter -j%,$(MAKEFLAGS))))
PARALLEL ?= $(if $(MAKE_NPROC),$(MAKE_NPROC),$(JOBS))

all:
	@mkdir -p build
	cmake -S . -B build
	+cmake --build build --parallel $(PARALLEL)

test:
	@mkdir -p build
	cmake -S . -B build
	+cmake --build build --parallel $(PARALLEL)
	cd build && ctest $(ARGS)
