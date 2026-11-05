SPINEL ?= spinel
SPINELFLAGS ?= -O2
RUBY ?= ruby
BUILD_DIR ?= build

.PHONY: spinel spinel-test

# Keep inline RBS and the compiler's default integer overflow checks enabled.
spinel:
	mkdir -p $(BUILD_DIR)
	$(SPINEL) -I lib --strict-require $(SPINELFLAGS) exe/wardite -o $(BUILD_DIR)/wardite

spinel-test: spinel
	WARDITE_SPINEL_BIN="$(abspath $(BUILD_DIR)/wardite)" $(RUBY) -Ilib:test -e 'Dir["test/e2e/spinel*_test.rb"].each { |path| require_relative path }'
