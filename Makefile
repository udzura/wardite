SPINEL ?= spinel
SPINELFLAGS ?= -O2
RUBY ?= ruby
BUILD_DIR ?= build
ZIG ?= zig
ZIG_GLIBC ?= 2.28
ZIG_MACOS ?= 13.0
ZIG_JOBS ?= 8
ZIG_TARGETS ?= aarch64-macos x86_64-linux aarch64-linux

.PHONY: spinel spinel-test spinel-zig

# Keep inline RBS and the compiler's default integer overflow checks enabled.
spinel:
	mkdir -p $(BUILD_DIR)
	$(SPINEL) -I lib --strict-require $(SPINELFLAGS) exe/wardite -o $(BUILD_DIR)/wardite

spinel-test: spinel
	WARDITE_SPINEL_BIN="$(abspath $(BUILD_DIR)/wardite)" $(RUBY) -Ilib:test -e 'Dir["test/e2e/spinel*_test.rb"].each { |path| require_relative path }'

spinel-zig:
	ZIG="$(ZIG)" $(RUBY) scripts/build_spinel_zig.rb "$(MAKE)" "$(BUILD_DIR)" "$(ZIG_GLIBC)" "$(ZIG_MACOS)" "$(ZIG_JOBS)" "$(SPINELFLAGS)" $(ZIG_TARGETS)
