VERSION ?= 0.0.0.dev0
V = 0
Q = $(if $(filter 1,$V),,@)

M = $(shell if [ "$$(tput colors 2> /dev/null || echo 0)" -ge 8 ]; then printf "\033[34;1m▶\033[0m"; else printf "▶"; fi)

BUILD ?= build
PYTHON ?= python3

export VERSION

.SUFFIXES:
.PHONY: all
all: | build wheels  ## Build the native library and the python wheel

# Standard targets

.PHONY: build
build: $(BUILD)/build.ninja  ## Build libkintsuki.dylib / .so via cmake + ninja
	$(Q) ninja -C $(BUILD) kintsuki

$(BUILD)/build.ninja:
	$(Q) cmake -S . -B $(BUILD) -G Ninja -DCMAKE_BUILD_TYPE=Release

.PHONY: python-stage
python-stage: build  ## Copy libkintsuki + ares System pak into the wheel
	$(Q) mkdir -p python/src/kintsuki/_lib
	$(Q) LIB_DIR=$(BUILD)/ares/target-kintsuki; \
	if [ -f $$LIB_DIR/libkintsuki.dylib ]; then \
	  cp $$LIB_DIR/libkintsuki.dylib python/src/kintsuki/_lib/; \
	elif [ -f $$LIB_DIR/libkintsuki.so ]; then \
	  cp $$LIB_DIR/libkintsuki.so python/src/kintsuki/_lib/; \
	else \
	  echo "no libkintsuki found in $$LIB_DIR" >&2; exit 1; \
	fi
	$(Q) rm -rf "python/src/kintsuki/_lib/System"
	$(Q) mkdir -p "python/src/kintsuki/_lib/System"
	$(Q) cp -R "ares/ares/System/Super Famicom" "python/src/kintsuki/_lib/System/"

.PHONY: dev-deps
dev-deps:  ## Sync dev environment via uv (kintsuki + a816 + pytest)
	$(Q) cd python && uv sync --group dev

.PHONY: test-rom
test-rom: python/tests/asm/test_rom.sfc  ## Assemble the CI test ROM via a816

python/tests/asm/test_rom.sfc: python/tests/asm/test_rom.s | dev-deps
	$(Q) cd python && uv run a816 -f sfc \
	  -o tests/asm/test_rom.sfc tests/asm/test_rom.s

.PHONY: tests
tests: python-stage test-rom; $(info $(M) Running tests...) @  ## Run pytest against the staged wheel + test ROM
	$(Q) cd python && KINTSUKI_TEST_ROM=$(CURDIR)/python/tests/asm/test_rom.sfc \
	  uv run pytest tests/ -v

.PHONY: wheels
wheels: python-stage  ## Build a python wheel (py3-none-any; CI retags per platform)
	$(Q) rm -rf python/dist
	$(Q) cd python && hatch build -t wheel

.PHONY: clean
clean: ## Cleanup build artifacts
	$(info $(M) cleaning ...)
	$(Q) rm -rf $(BUILD)
	$(Q) rm -f python/tests/asm/test_rom.sfc
	$(Q) rm -f python/src/kintsuki/_lib/libkintsuki.*
	$(Q) rm -rf python/dist

.PHONY: help
help: ## Display help
	@grep -hE '^[ a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-17s\033[0m %s\n", $$1, $$2}'
