all:
	@mkdir -p build
	cmake -S . -B build
	cmake --build build -- $(MAKEFLAGS)

test:
	@mkdir -p build
	cmake -S . -B build
	cmake --build build -- $(MAKEFLAGS)
	cd build && ctest $(ARGS)
