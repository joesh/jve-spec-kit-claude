JOBS ?= 4

all:
	@mkdir -p build
	cmake -S . -B build
	+cmake --build build -- -j$(JOBS)

test:
	@mkdir -p build
	cmake -S . -B build
	+cmake --build build -- -j$(JOBS)
	cd build && ctest $(ARGS)
