.PHONY: all
all: release

# ----------------------------------------------------------------------------
# Swift
# ----------------------------------------------------------------------------

SWIFT_FILES = Sources Tests Fuzz Package.swift

.PHONY: debug
debug:
	swift build

# OSATOOL_SAMPLES and OSATOOL_APPLE_TOOLS are read from the environment (see README.md).
.PHONY: test
test:
	swift test

.PHONY: format
format:
	swiftformat $(SWIFT_FILES) --verbose

.PHONY: lint
lint:
	swiftformat $(SWIFT_FILES) --lint

.PHONY: clean
clean:
	swift package clean

# ----------------------------------------------------------------------------
# Xcode
# ----------------------------------------------------------------------------

PRODUCT_NAME = osatool
PACKAGE_NAME = $(PRODUCT_NAME)-Package
CONFIG_PATH ?= $(PRODUCT_NAME).xcconfig
XCODE_FLAGS = -xcconfig $(CONFIG_PATH) -destination platform=macOS

INSTALL_PATH ?= /usr/local/bin/
ARCHIVE_PATH  = /tmp/$(PRODUCT_NAME).zip

.PHONY: release
release: xcode
	xcodebuild build -scheme $(PRODUCT_NAME) $(XCODE_FLAGS) -configuration Release

.PHONY: xcode-debug
xcode-debug: xcode
	xcodebuild build -scheme $(PRODUCT_NAME) $(XCODE_FLAGS) -configuration Debug

.PHONY: xcode-test
xcode-test: xcode
	xcodebuild test -scheme $(PACKAGE_NAME) $(XCODE_FLAGS)

.PHONY: xcode-clean
xcode-clean: xcode
	xcodebuild clean -scheme $(PRODUCT_NAME) $(XCODE_FLAGS) -alltargets
	rm -rf /tmp/$(PRODUCT_NAME).dst

.PHONY: install
install: release
	cp /tmp/$(PRODUCT_NAME).dst/usr/local/bin/$(PRODUCT_NAME) $(INSTALL_PATH)

.PHONY: zip
zip: release
	rm -f $(ARCHIVE_PATH)
	zip -j $(ARCHIVE_PATH) /tmp/$(PRODUCT_NAME).dst/usr/local/bin/$(PRODUCT_NAME) LICENSE NOTICE

# ----------------------------------------------------------------------------
# Setup dependencies
# ----------------------------------------------------------------------------

.PHONY: xcode
xcode:
	xcode-select --print-path
	xcodebuild -runFirstLaunch

.PHONY: brew
brew: xcode
	[ -f /etc/paths.d/*brew ] \
	|| /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
	&& eval "$$(/usr/libexec/path_helper)" \
	&& ( HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_OFFLINE=1 brew bundle check --no-upgrade --file Brewfile || brew bundle --file Brewfile )

# ----------------------------------------------------------------------------
# Fuzzing (see README.md and Scripts/fuzz.sh)
# ----------------------------------------------------------------------------

FUZZ_SECONDS ?= 900
FUZZ_FLAGS ?=

# Compiled scripts: disassemble and decompile.
.PHONY: fuzz
fuzz:
	Scripts/fuzz.sh scripts -max_total_time=$(FUZZ_SECONDS) $(FUZZ_FLAGS)

# The files `osatool learn` reads.
.PHONY: fuzz-terminology
fuzz-terminology:
	Scripts/fuzz.sh terminology -max_total_time=$(FUZZ_SECONDS) $(FUZZ_FLAGS)

.PHONY: fuzz-clean
fuzz-clean:
	rm -rf .build-fuzz

# ----------------------------------------------------------------------------
# Housekeeping
# ----------------------------------------------------------------------------

# Kept: the local Xcode settings, and what the fuzzer found and gathered.
.PHONY: distclean
distclean: clean xcode-clean fuzz-clean
	git clean -dx --force --exclude local.xcconfig --exclude Fuzz/artifacts --exclude Fuzz/corpus --exclude Fuzz/corpus-terminology
