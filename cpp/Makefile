# Target names are the same in every language directory of this repository.
.PHONY: build test lint format examples asan clean

BUILD ?= build

build:
	cmake -S . -B $(BUILD) -DCMAKE_BUILD_TYPE=Debug
	cmake --build $(BUILD) -j

test: build
	ctest --test-dir $(BUILD) --output-on-failure

lint:
	clang-format --dry-run --Werror $(shell git ls-files '*.cpp' '*.hpp')

format:
	clang-format -i $(shell git ls-files '*.cpp' '*.hpp')

examples: build
	$(BUILD)/examples/decode_summary ../tests/conformance/data/OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio.4dgs

# The leak and the out-of-bounds read are the two bugs a binding over an FFI boundary is
# exposed to, so they get their own build directory rather than a flag somebody remembers.
asan:
	cmake -S . -B $(BUILD)-asan -DCMAKE_BUILD_TYPE=Debug -DFOURDGS_ASAN=ON
	cmake --build $(BUILD)-asan -j
	ctest --test-dir $(BUILD)-asan --output-on-failure

clean:
	rm -rf $(BUILD) $(BUILD)-asan
