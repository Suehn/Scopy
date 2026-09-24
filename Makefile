# Scopy Makefile: build, test, measurement, and release entry points (see doc/current/development-guide.md).

.PHONY: all setup build release run clean quick-build xcode help stats format lint
.PHONY: test-unit test-strict test-tsan test-snapshot-perf-release test-tooling
.PHONY: snapshot-perf-db bench-snapshot-search perf-search-warm-load perf-scroll-tools perf-scroll-wheel perf-search-type perf-capture
.PHONY: perf-frontend-profile perf-frontend-profile-smoke perf-frontend-profile-standard perf-frontend-profile-full
.PHONY: tag-release push-release release-validate release-bump-patch test-release-policy docs-validate
.PHONY: markdown-renderer-deps markdown-assets-sync markdown-assets-verify test-markdown-renderer-assets markdown-assets-gate

VERSION_ARGS := $(shell bash scripts/version.sh --xcodebuild-args 2>/dev/null)
LOG_DIR := logs

# Each Swift-flag variant gets its own DerivedData so switching between plain builds,
# strict concurrency, sanitizers, and perf defines never invalidates another variant's
# incremental state. Isolate explicit paths by checkout as well: simultaneous
# worktrees must never contend for the same build database or test products.
# Plain build/test/test-unit share Xcode's default, project-path-scoped DerivedData.
CHECKOUT_ID := $(shell printf '%s' '$(CURDIR)' | shasum | cut -c1-12)
DERIVED_DATA_BASE := $(HOME)/Library/Developer/Xcode/DerivedData/Scopy-$(CHECKOUT_ID)
FRONTEND_PROFILE_SMOKE_ARGS := --skip-setup --repeats 1 --duration 3 --min-samples 50
FRONTEND_PROFILE_STANDARD_ARGS := --skip-setup --repeats 1 --duration 6 --min-samples 120
FRONTEND_PROFILE_FULL_ARGS := --repeats 3 --duration 10 --min-samples 260

# 默认目标
all: build

# 安装依赖（xcodegen）
setup:
	@echo "Installing xcodegen if not present..."
	@which xcodegen > /dev/null || brew install xcodegen
	@bash scripts/xcodegen-generate-if-needed.sh

# 生成 Xcode 项目
xcode: setup
	open Scopy.xcodeproj

# 构建项目
build: markdown-assets-verify setup
	@echo "Building Scopy..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build $(VERSION_ARGS)

# 构建 Release 版本
release: markdown-assets-gate setup
	@echo "Building Scopy (Release)..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release build $(VERSION_ARGS)

# 构建并运行
run: build
	@echo "Running Scopy..."
	@open "build/Debug/Scopy.app" 2>/dev/null || \
		open "$$(xcodebuild -project Scopy.xcodeproj -scheme Scopy -showBuildSettings | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Scopy.app"

# 清理构建产物
clean:
	@echo "Cleaning..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy clean 2>/dev/null || true
	rm -rf .build/ $(DERIVED_DATA_BASE)

# 快速构建（跳过 xcodegen 如果项目已存在）
quick-build: markdown-assets-verify
	@if [ ! -f "Scopy.xcodeproj/project.pbxproj" ]; then \
		$(MAKE) setup; \
	fi
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build $(VERSION_ARGS)

# =================== 测试命令 ===================


# Unit tests: every ScopyTests class, including the product-setting and polling tests.
test-unit: markdown-assets-verify setup
	@echo "Running unit tests..."
	@mkdir -p $(LOG_DIR)
	bash -o pipefail -c 'xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination platform=macOS \
		-only-testing:ScopyTests \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-unit.log'




# 运行 release 配置的快照性能校验（ScopyBench + 阈值断言）
test-snapshot-perf-release: setup
	@echo "Running snapshot performance tests (Release benchmark)..."
	@mkdir -p $(LOG_DIR)
	bash -o pipefail -c 'set -euo pipefail; \
		DB_PATH="$${SCOPY_SNAPSHOT_DB_PATH:-perf-db/clipboard.db}"; \
		if [ "$${DB_PATH#/}" = "$$DB_PATH" ]; then DB_PATH="$(CURDIR)/$$DB_PATH"; fi; \
		if [ ! -f "$$DB_PATH" ]; then echo "Missing snapshot DB at $$DB_PATH. Run: make snapshot-perf-db or set SCOPY_SNAPSHOT_DB_PATH"; exit 1; fi; \
		CMD_TARGET="$${SCOPY_SNAPSHOT_RELEASE_CMD_P95_MS:-50}"; \
		CM_TARGET="$${SCOPY_SNAPSHOT_RELEASE_CM_P95_MS:-20}"; \
		{ \
			echo "Snapshot release bench env: DB=$$DB_PATH cmdTarget=$$CMD_TARGET cmTarget=$$CM_TARGET"; \
			swift build -c release --product ScopyBench > $(LOG_DIR)/scopybench.release.build.log 2>&1; \
			./.build/release/ScopyBench --layer service --db "$$DB_PATH" --mode fuzzyPlus --sort relevance --query cmd --iters 30 --warmup 20 --json > $(LOG_DIR)/snapshot-release-cmd.jsonl; \
			./.build/release/ScopyBench --layer engine --db "$$DB_PATH" --mode fuzzyPlus --sort relevance --query cm --prepare-short-index --iters 30 --warmup 3 --json > $(LOG_DIR)/snapshot-release-cm.jsonl; \
			./.build/release/ScopyBench --layer service --db "$$DB_PATH" --mode fuzzyPlus --sort relevance --query cm --iters 1 --warmup 0 --json > $(LOG_DIR)/snapshot-release-cm-cold.jsonl; \
			CMD_P95=$$(python3 scripts/extract_p95.py $(LOG_DIR)/snapshot-release-cmd.jsonl) || (echo "Failed to parse cmd p95 from $(LOG_DIR)/snapshot-release-cmd.jsonl" && exit 1); \
			CM_P95=$$(python3 scripts/extract_p95.py $(LOG_DIR)/snapshot-release-cm.jsonl) || (echo "Failed to parse cm p95 from $(LOG_DIR)/snapshot-release-cm.jsonl" && exit 1); \
			CM_COLD=$$(python3 scripts/extract_p95.py $(LOG_DIR)/snapshot-release-cm-cold.jsonl) || (echo "Failed to parse cold cm latency from $(LOG_DIR)/snapshot-release-cm-cold.jsonl" && exit 1); \
			echo "Release bench: cmd p95=$$CMD_P95 ms (target $$CMD_TARGET), prepared cm p95=$$CM_P95 ms (target $$CM_TARGET), cold cm observed=$$CM_COLD ms"; \
			awk -v actual="$$CMD_P95" -v target="$$CMD_TARGET" "BEGIN { exit (actual <= target) ? 0 : 1 }"; \
			awk -v actual="$$CM_P95" -v target="$$CM_TARGET" "BEGIN { exit (actual <= target) ? 0 : 1 }"; \
		} 2>&1 | tee $(LOG_DIR)/test-snapshot-perf-release.log'


# Thread Sanitizer (requires hosted test bundle mode)
test-tsan:
	@mkdir -p $(LOG_DIR)
	@OS_VERSION="$$(sw_vers -productVersion)"; \
	OS_BUILD="$$(sw_vers -buildVersion)"; \
	XCODE_BUILD="$$(xcodebuild -version | awk '/Build version/ { print $$3 }')"; \
	case "$$OS_VERSION:$$XCODE_BUILD" in \
		26.*:17C52) \
		printf '%s\n' "SKIPPED: Apple hosted TSan runtime crashes on macOS $$OS_VERSION ($$OS_BUILD) with Xcode 26.2 ($$XCODE_BUILD)." | tee $(LOG_DIR)/test-tsan.log; \
		;; \
		*) \
		$(MAKE) setup; \
		echo "Running Thread Sanitizer tests..."; \
		bash -o pipefail -c 'ENABLE_THREAD_SANITIZER=YES xcodebuild test \
			-project Scopy.xcodeproj \
			-scheme ScopyTSan \
			-destination platform=macOS \
			-only-testing:ScopyTSanTests \
			-derivedDataPath $(DERIVED_DATA_BASE)/Scopy-TSan \
			$(VERSION_ARGS) \
			2>&1 | tee $(LOG_DIR)/test-tsan.log'; \
		;; \
	esac

# Swift 6 Strict Concurrency regression (tests target only)
test-strict: markdown-assets-verify setup
	@echo "Running Strict Concurrency tests..."
	@mkdir -p $(LOG_DIR)
	bash -o pipefail -c 'xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination platform=macOS \
		-only-testing:ScopyTests \
		-derivedDataPath $(DERIVED_DATA_BASE)/Scopy-Strict \
		SWIFT_STRICT_CONCURRENCY=complete \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/strict-concurrency-test.log'




# =================== 测试流程自动化 ===================





test-tooling:
	@python3 -m unittest discover -s scripts/tests -p 'test_*.py'

# MarkdownPreview 的 renderer、KaTeX CSS/fonts、sidecar 与 manifest 必须来自同一锁定资产集。
# Reinstall the renderer's npm dependencies whenever the lockfile changed since the last install.
markdown-renderer-deps:
	@lock="$$(shasum Tools/MarkdownRenderer/package-lock.json | cut -c1-40)"; \
	stamp=Tools/MarkdownRenderer/node_modules/.scopy-lock-sha; \
	test -d Tools/MarkdownRenderer/node_modules/katex -a "$$(cat $$stamp 2>/dev/null)" = "$$lock" \
		|| { npm ci --prefix Tools/MarkdownRenderer && echo "$$lock" > $$stamp; }

markdown-assets-sync: markdown-renderer-deps
	@npm run sync:katex-assets --prefix Tools/MarkdownRenderer

markdown-assets-verify: markdown-renderer-deps
	@npm run verify:assets --prefix Tools/MarkdownRenderer

test-markdown-renderer-assets:
	@cd Tools/MarkdownRenderer && node --test test/asset-contract.test.js

markdown-assets-gate:
	@npm ci --prefix Tools/MarkdownRenderer
	@cd Tools/MarkdownRenderer && node --test test/asset-contract.test.js
	@npm run verify:assets --prefix Tools/MarkdownRenderer

# =================== 开发工具 ===================

# 代码格式化（如果安装了 swift-format）
format:
	@which swift-format > /dev/null && \
		swift-format -i -r Scopy/ ScopyTests/ || \
		echo "swift-format not installed. Run: brew install swift-format"

# 代码检查（如果安装了 swiftlint）
lint:
	@which swiftlint > /dev/null && \
		swiftlint --path Scopy/ || \
		echo "swiftlint not installed. Run: brew install swiftlint"

# 查看项目统计
stats:
	@echo "=== Scopy Project Statistics ==="
	@echo ""
	@echo "Source files:"
	@find Scopy -name "*.swift" | wc -l | xargs echo "  Swift files:"
	@find Scopy -name "*.swift" -exec cat {} \; | wc -l | xargs echo "  Total lines:"
	@echo ""
	@echo "Test files:"
	@find ScopyTests -name "*.swift" 2>/dev/null | wc -l | xargs echo "  Test files:"
	@find ScopyTests -name "*.swift" 2>/dev/null -exec cat {} \; | wc -l | xargs echo "  Total lines:"
	@echo ""
	@echo "By directory:"
	@for dir in Scopy/Application Scopy/Infrastructure Scopy/Services Scopy/Views Scopy/Observables; do \
		if [ -d "$$dir" ]; then \
			count=$$(find "$$dir" -name "*.swift" -exec cat {} \; | wc -l); \
			echo "  $$dir: $$count lines"; \
		fi; \
	done

# =================== 性能测试辅助 ===================

# 拷贝真实数据库快照到仓库（用于本地真实性能测试；文件已在 .gitignore 中忽略）
snapshot-perf-db:
	@bash scripts/snapshot-perf-db.sh

# 用 perf-db/clipboard.db 运行 release 级搜索基准（更贴近真实体验）
bench-snapshot-search:
	@test -f perf-db/clipboard.db || (echo "Missing perf snapshot DB. Run: make snapshot-perf-db" && exit 1)
	@echo "Running ScopyBench (release) on perf snapshot..."
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzyPlus --sort relevance --query cm --iters 30 --warmup 20
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzyPlus --sort relevance --query '数学' --iters 30 --warmup 20
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzyPlus --sort relevance --query cmd --iters 30 --warmup 20
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzyPlus --sort relevance --query cm --force-full-fuzzy --iters 30 --warmup 20
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzy --sort relevance --query abc --force-full-fuzzy --iters 30 --warmup 20
	@swift run -c release ScopyBench --db perf-db/clipboard.db --mode fuzzy --sort relevance --query cmd --force-full-fuzzy --iters 30 --warmup 20

# 测量 full-index warm-load latency 与 peak RSS
perf-search-warm-load:
	@bash scripts/perf-search-warm-load.sh


# 前端 scroll/profile 真实性能审计（默认开发用轻量 smoke）
perf-frontend-profile: perf-frontend-profile-smoke

# 轻量 smoke：日常开发默认（最快）
perf-frontend-profile-smoke:
	@bash scripts/perf-frontend-profile.sh $(FRONTEND_PROFILE_SMOKE_ARGS)

# 标准档：提交前验证（统计更稳）
perf-frontend-profile-standard:
	@bash scripts/perf-frontend-profile.sh $(FRONTEND_PROFILE_STANDARD_ARGS)

# 全量档：发布前基准（最慢，结果最稳定）
perf-frontend-profile-full:
	@bash scripts/perf-frontend-profile.sh $(FRONTEND_PROFILE_FULL_ARGS)

perf-scroll-tools:
	@bash scripts/perf-scroll/build-tools.sh

# Real-input scroll profile against the Release app: make perf-scroll-wheel LABEL=name [DURATION=12]
perf-scroll-wheel: perf-scroll-tools
	@APP="$$(xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Scopy.app"; \
	python3 scripts/perf-scroll/profile_scroll.py "$$APP" "$${LABEL:-wheel}" --mode wheel --duration "$${DURATION:-12}" --sample

# Real-input clipboard-capture profile against the Release app: make perf-capture LABEL=name [SCENARIO=text|rich|image] [COUNT=10] [INTERVAL=1] [SIZE=n]
perf-capture: perf-scroll-tools
	@APP="$$(xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Scopy.app"; \
	python3 scripts/perf-scroll/profile_capture.py "$$APP" "$${LABEL:-capture}" --scenario "$${SCENARIO:-text}" --count "$${COUNT:-10}" --interval "$${INTERVAL:-1}" $${SIZE:+--size "$$SIZE"} --sample

# Real-input search-typing profile against the Release app: make perf-search-type LABEL=name [QUERY=cm] [RATE=8]
perf-search-type: perf-scroll-tools
	@APP="$$(xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Scopy.app"; \
	python3 scripts/perf-scroll/profile_search.py "$$APP" "$${LABEL:-search}" --query "$${QUERY:-cm}" --rate "$${RATE:-8}" --sample



# =================== 帮助 ===================

# 帮助信息
help:
	@echo "Scopy"
	@echo ""
	@echo "Build:"
	@echo "  make setup        - Install xcodegen if missing and generate the Xcode project"
	@echo "  make build        - Build Debug (also verifies the Markdown renderer assets)"
	@echo "  make release      - Build Release"
	@echo "  make run          - Build and launch the Debug app"
	@echo "  make quick-build  - Build without regenerating the project"
	@echo "  make xcode        - Generate and open the Xcode project"
	@echo "  make clean        - Remove SwiftPM and DerivedData outputs (keeps the tracked project)"
	@echo ""
	@echo "Required gates:"
	@echo "  make test-unit    - All ScopyTests classes"
	@echo "  make test-strict  - Unit tests under strict concurrency; any Swift warning fails"
	@echo "  make test-tsan    - Hosted ThreadSanitizer test bundle"
	@echo "  make test-tooling - Project generation, worktree isolation, and script checks"
	@echo "  make docs-validate / make release-validate / make test-release-policy"
	@echo "  make markdown-assets-verify - Verify renderer bundle, CSS, fonts, and manifest atomically"
	@echo ""
	@echo "Measurement (local, needs perf-db and a quiet desktop; see the development guide):"
	@echo "  make snapshot-perf-db            - Copy the live database into perf-db/"
	@echo "  make test-snapshot-perf-release  - Backend search latency gate on the snapshot"
	@echo "  make bench-snapshot-search       - ScopyBench runs without thresholds"
	@echo "  make perf-search-warm-load       - Full-index warm-load latency and peak RSS"
	@echo "  make perf-scroll-wheel / perf-search-type / perf-capture - Real-input Release profiles"
	@echo "  make perf-frontend-profile[-smoke|-standard|-full] - XCUITest callback-cadence profile (blocked on hosts without automation access)"
	@echo ""
	@echo "Release:"
	@echo "  make tag-release  - Tag HEAD from doc/meta/release-current.yml"
	@echo "  make push-release - Push main and the current tag"
	@echo "  make release-bump-patch - Bump the patch version in the release metadata"
	@echo ""
	@echo "Development:"
	@echo "  make format / make lint / make stats"
	@echo "  make markdown-assets-sync - Sync locked KaTeX CSS/fonts without rebuilding the renderer"

# =================== Release Helpers ===================

tag-release: markdown-assets-gate
	@bash scripts/release/tag-from-doc.sh

push-release: markdown-assets-gate
	@bash scripts/release/push-main.sh

release-validate:
	@bash scripts/release/validate-release-docs.sh

test-release-policy:
	@python3 -m unittest discover -s scripts/release/tests -p 'test_validate_workflow_tag_policy.py'

docs-validate:
	@bash scripts/docs/validate-docs.sh

release-bump-patch:
	@bash scripts/release/bump-version.sh --patch
