.PHONY: all build clean test test-rom python-stage wheels

BUILD ?= build
PYTHON ?= python3

# Hatch reads VERSION from the env at wheel-build time (see
# [tool.hatch.version] in python/pyproject.toml). Default to a dev marker
# for local builds; CI overrides with the pushed tag.
VERSION ?= 0.0.0.dev0
export VERSION

# Native library build (cmake/ninja)
all: build

$(BUILD)/build.ninja:
	cmake -S . -B $(BUILD) -G Ninja -DCMAKE_BUILD_TYPE=Release

build: $(BUILD)/build.ninja
	ninja -C $(BUILD) kintsuki

# Python wheel staging — copies the freshly built native library into the
# place the wheel imports it from.
python-stage: build
	mkdir -p python/src/kintsuki/_lib
	@LIB_DIR=$(BUILD)/ares/target-kintsuki; \
	if [ -f $$LIB_DIR/libkintsuki.dylib ]; then \
	  cp $$LIB_DIR/libkintsuki.dylib python/src/kintsuki/_lib/; \
	elif [ -f $$LIB_DIR/libkintsuki.so ]; then \
	  cp $$LIB_DIR/libkintsuki.so python/src/kintsuki/_lib/; \
	else \
	  echo "no libkintsuki found in $$LIB_DIR" >&2; exit 1; \
	fi

# Assemble the CI test ROM (a816 must be on PATH).
test-rom: python/tests/asm/test_rom.sfc

python/tests/asm/test_rom.sfc: python/tests/asm/test_rom.s
	a816 -f sfc -o $@ $<

# Full test cycle: build native lib, stage into wheel, build test ROM, pytest.
test: python-stage test-rom
	cd python && KINTSUKI_TEST_ROM=$(CURDIR)/python/tests/asm/test_rom.sfc \
	  $(PYTHON) -m pytest tests/ -v

# Build a Python wheel with the staged libkintsuki bundled in. Default
# platform tag is what hatch infers (py3-none-any); CI retags the wheel
# per platform with `python -m wheel tags --platform-tag ...`.
wheels: python-stage
	rm -rf python/dist
	cd python && hatch build -t wheel

clean:
	rm -rf $(BUILD)
	rm -f python/tests/asm/test_rom.sfc
	rm -f python/src/kintsuki/_lib/libkintsuki.*
