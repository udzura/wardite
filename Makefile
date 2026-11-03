SPINEL ?= spinel
SPINELFLAGS ?= -O2
RUBY ?= ruby
BUILD_DIR ?= build

.PHONY: spinel spinel-test

# Wardite's annotations target rbs-inline. Preserve Ruby's integer arithmetic
# for the masks and intermediate results used by the Wasm numeric operations.
spinel:
	mkdir -p $(BUILD_DIR)
	$(SPINEL) -I lib --strict-require --no-inline-rbs --int-overflow=promote $(SPINELFLAGS) exe/wardite -o $(BUILD_DIR)/wardite

spinel-test: spinel
	WARDITE_SPINEL_BIN="$(abspath $(BUILD_DIR)/wardite)" $(RUBY) -Ilib:test test/e2e/spinel_test.rb
