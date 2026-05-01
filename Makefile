.PHONY: all build clean test test-rom python-stage

BUILD ?= build
PYTHON ?= python3

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

clean:
	rm -rf $(BUILD)
	rm -f python/tests/asm/test_rom.sfc
	rm -f python/src/kintsuki/_lib/libkintsuki.*
