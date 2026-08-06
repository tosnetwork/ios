SHELL := /bin/sh

.PHONY: \
	locale \
	analytics \
	format \
	hooks \
	setup \
	tonconnect_generate \
	compile \
	test \
	test_all \
	test_tos_live \
	test_ui

locale:
	@scripts/require_tool.sh swiftgen "brew install swiftgen"
	swiftgen config run --config "./LocalPackages/TKLocalize/codegen/swiftgen.yml"

analytics:
	@scripts/analytics/sync_models.sh

format:
	@scripts/require_tool.sh swiftformat "brew install swiftformat"
	swiftformat --config "./.swiftformat" "."

hooks:
	@scripts/hooks/setup_hooks.sh

setup:
	@scripts/setup.sh

tonconnect_generate:
	@scripts/tonconnect_apigen/generate_api.sh

# Build

BUILD_DIR := ./build

compile:
	@scripts/require_tool.sh xcbeautify "brew install xcbeautify"
	mkdir -p $(BUILD_DIR)
	echo 'building Tonkeeper...' && \
		set -o pipefail; \
		HOME=$(BUILD_DIR)/codex_home \
		SWIFTPM_CACHE_PATH=$(BUILD_DIR)/swiftpm-cache \
		SWIFTPM_CONFIG_DIR=$(BUILD_DIR)/swiftpm-config \
		CLANG_MODULE_CACHE_PATH=$(BUILD_DIR)/clang-module-cache \
		CLONED_SOURCE_PACKAGES_DIR=$(BUILD_DIR)/SourcePackages \
		xcodebuild \
		-project Tonkeeper.xcodeproj \
		-scheme Tonkeeper \
		-configuration TonkeeperDebug \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		-clonedSourcePackagesDirPath $(BUILD_DIR)/SourcePackages \
		build | xcbeautify

# Test

TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
TEST_ONLY ?=
TEST_BUILD_DIR ?= $(BUILD_DIR)
TEST_BUILD_ROOT := $(abspath $(TEST_BUILD_DIR))

test: test_all

test_all:
	$(MAKE) test_core_swift
	$(MAKE) test_tron_swift
	$(MAKE) test_tkcryptokit
	$(MAKE) test_tkcore_package
	$(MAKE) test_tklocalize_package
	$(MAKE) test_tkchart_package

test_project_scheme:
	@scripts/require_tool.sh xcbeautify "brew install xcbeautify"
	@mkdir -p $(TEST_BUILD_ROOT) \
		$(TEST_BUILD_ROOT)/codex_home \
		$(TEST_BUILD_ROOT)/swiftpm-cache \
		$(TEST_BUILD_ROOT)/swiftpm-config \
		$(TEST_BUILD_ROOT)/clang-module-cache \
		$(TEST_BUILD_ROOT)/SourcePackages
	@test -n "$(SCHEME)" || (echo "SCHEME is required"; exit 1)
	@echo 'running $(SCHEME) tests...' && \
		set -o pipefail; \
		HOME=$(TEST_BUILD_ROOT)/codex_home \
		SWIFTPM_CONFIG_DIR=$(TEST_BUILD_ROOT)/swiftpm-config \
		CLANG_MODULE_CACHE_PATH=$(TEST_BUILD_ROOT)/clang-module-cache \
		xcodebuild \
		-project Tonkeeper.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(TEST_DESTINATION)' \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		-skipPackageUpdates \
		-derivedDataPath $(TEST_BUILD_ROOT)/DerivedData-tests/$(SCHEME) \
		-clonedSourcePackagesDirPath $(TEST_BUILD_ROOT)/SourcePackages \
		-packageCachePath $(TEST_BUILD_ROOT)/swiftpm-cache \
		SWIFT_SUPPRESS_WARNINGS=NO \
		test $(if $(TEST_ONLY),-only-testing:$(TEST_ONLY),) | xcbeautify

test_core_swift: SCHEME=WalletCore
test_core_swift: test_project_scheme

test_tron_swift_package: SCHEME=TronSwift
test_tron_swift_package: test_project_scheme

test_tkcore_package: SCHEME=TKCore
test_tkcore_package: test_project_scheme

test_tklocalize_package: SCHEME=TKLocalize
test_tklocalize_package: test_project_scheme

test_tkchart_package: SCHEME=TKChart
test_tkchart_package: test_project_scheme

test_core_components: SCHEME=WalletCore
test_core_components: TEST_ONLY=CoreComponentsTests
test_core_components: test_project_scheme

test_keeper_core: SCHEME=WalletCore
test_keeper_core: TEST_ONLY=KeeperCoreTests
test_keeper_core: test_project_scheme

test_tos_live: SCHEME=WalletCore
test_tos_live: TEST_ONLY=KeeperCoreTests/TOSRPCLiveIntegrationTests
test_tos_live: test_project_scheme

test_ui: SCHEME=TOSWalletUITests
test_ui: test_project_scheme

test_wallet_core: SCHEME=WalletCore
test_wallet_core: TEST_ONLY=WalletCoreTests
test_wallet_core: test_project_scheme

test_tron_swift: SCHEME=TronSwift
test_tron_swift: TEST_ONLY=TronSwift-Tests
test_tron_swift: test_project_scheme

test_tkcryptokit: SCHEME=TronSwift
test_tkcryptokit: TEST_ONLY=TKCryptoKit-Tests
test_tkcryptokit: test_project_scheme

test_tkcore: SCHEME=TKCore
test_tkcore: TEST_ONLY=TKCoreTests
test_tkcore: test_project_scheme

test_tklocalize: SCHEME=TKLocalize
test_tklocalize: TEST_ONLY=TKLocalizeTests
test_tklocalize: test_project_scheme

test_tkchart: SCHEME=TKChart
test_tkchart: TEST_ONLY=TKChartTests
test_tkchart: test_project_scheme
