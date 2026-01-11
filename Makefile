# Scopy Makefile
# 符合 v0.md 的构建和测试流程

.PHONY: all setup build run clean xcode test test-unit test-perf test-perf-heavy test-snapshot-perf test-tsan test-strict coverage benchmark test-flow test-flow-quick health-check
.PHONY: snapshot-perf-db bench-snapshot-search
.PHONY: tag-release push-release release-validate release-bump-patch

VERSION_ARGS := $(shell bash scripts/version.sh --xcodebuild-args 2>/dev/null)
LOG_DIR := logs

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
build: setup
	@echo "Building Scopy..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build $(VERSION_ARGS)

# 构建 Release 版本
release: setup
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
	rm -rf build/
	rm -rf DerivedData/
	rm -rf Scopy.xcodeproj

# 快速构建（跳过 xcodegen 如果项目已存在）
quick-build:
	@if [ ! -f "Scopy.xcodeproj/project.pbxproj" ]; then \
		$(MAKE) setup; \
	fi
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build $(VERSION_ARGS)

# =================== 测试命令 ===================

# 运行所有测试
test: setup
	@echo "Running all tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-resultBundlePath $(LOG_DIR)/TestResults.xcresult \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test.log

# 仅运行单元测试（排除性能测试）
test-unit: setup
	@echo "Running unit tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests \
		-skip-testing:ScopyTests/IntegrationTests \
		-skip-testing:ScopyTests/PerformanceTests \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-unit.log

# 运行性能测试
test-perf: setup
	@echo "Running performance tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/PerformanceTests \
		OTHER_SWIFT_FLAGS='$$(inherited) -DSCOPY_PERF_TESTS' \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-perf.log

# 运行重负载性能测试（更慢）
test-perf-heavy: setup
	@echo "Running heavy performance tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/PerformanceTests \
		OTHER_SWIFT_FLAGS='$$(inherited) -DSCOPY_PERF_TESTS -DSCOPY_HEAVY_PERF_TESTS' \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-perf-heavy.log

# 运行基于真实快照 DB 的端到端性能测试（需先 make snapshot-perf-db）
test-snapshot-perf: setup
	@echo "Running snapshot performance tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/SnapshotPerformanceTests \
		OTHER_SWIFT_FLAGS='$$(inherited) -DSCOPY_SNAPSHOT_PERF_TESTS' \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-snapshot-perf.log

# Thread Sanitizer (requires hosted test bundle mode)
test-tsan: setup
	@echo "Running Thread Sanitizer tests..."
	@mkdir -p $(LOG_DIR)
	ENABLE_THREAD_SANITIZER=YES xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme ScopyTSan \
		-destination 'platform=macOS' \
		-only-testing:ScopyTSanTests \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-tsan.log

# Swift 6 Strict Concurrency regression (tests target only)
test-strict: setup
	@echo "Running Strict Concurrency tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests \
		-skip-testing:ScopyTests/IntegrationTests \
		-skip-testing:ScopyTests/PerformanceTests \
		SWIFT_STRICT_CONCURRENCY=complete \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/strict-concurrency-test.log

# 运行集成测试
test-integration: setup
	@echo "Running integration tests..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/IntegrationTests \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/test-integration.log

# 生成测试覆盖率报告
coverage: setup
	@echo "Running tests with coverage..."
	@mkdir -p $(LOG_DIR)
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-enableCodeCoverage YES \
		-resultBundlePath $(LOG_DIR)/CoverageResults.xcresult \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/coverage.log
	@echo ""
	@echo "Coverage report generated at $(LOG_DIR)/CoverageResults.xcresult"
	@echo "View with: xcrun xccov view --report $(LOG_DIR)/CoverageResults.xcresult"

# 运行基准测试
benchmark: setup
	@echo "Running benchmarks..."
	@echo "This will take a few minutes..."
	@mkdir -p $(LOG_DIR)
	RUN_PERF_TESTS=1 xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/PerformanceTests \
		$(VERSION_ARGS) \
		2>&1 | tee $(LOG_DIR)/benchmark-output.log
	@echo ""
	@echo "Benchmark results saved to $(LOG_DIR)/benchmark-output.log"

# =================== 测试流程自动化 ===================

# 完整测试流程（杀进程 → 编译 → 安装 → 启动 → 健康检查）
test-flow:
	@bash scripts/test-flow.sh

# 快速测试流程（跳过编译）
test-flow-quick:
	@bash scripts/test-flow.sh --skip-build

# 仅运行健康检查
health-check:
	@bash scripts/health-check.sh

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
	@for dir in Scopy/Services Scopy/Protocols Scopy/Views Scopy/Observables; do \
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

# =================== 帮助 ===================

# 帮助信息
help:
	@echo "Scopy Build System"
	@echo ""
	@echo "Build Commands:"
	@echo "  make setup        - Install dependencies and generate Xcode project"
	@echo "  make xcode        - Generate and open Xcode project"
	@echo "  make build        - Build the application (Debug)"
	@echo "  make release      - Build the application (Release)"
	@echo "  make run          - Build and run the application"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make quick-build  - Build without regenerating project"
	@echo ""
	@echo "Test Commands:"
	@echo "  make test         - Run all tests"
	@echo "  make test-unit    - Run unit tests only"
	@echo "  make test-perf    - Run performance tests"
	@echo "  make test-perf-heavy - Run heavy perf tests"
	@echo "  make test-snapshot-perf - Run snapshot perf tests"
	@echo "  make test-integration - Run integration tests"
	@echo "  make test-strict  - Run Strict Concurrency regression"
	@echo "  make coverage     - Run tests with coverage report"
	@echo "  make benchmark    - Run full benchmark suite"
	@echo ""
	@echo "Test Flow Automation:"
	@echo "  make test-flow    - Full test flow (kill → build → install → launch → health check)"
	@echo "  make test-flow-quick - Quick test flow (skip build)"
	@echo "  make health-check - Run health checks only"
	@echo ""
	@echo "Development:"
	@echo "  make format       - Format code (requires swift-format)"
	@echo "  make lint         - Lint code (requires swiftlint)"
	@echo "  make stats        - Show project statistics"
	@echo ""
	@echo "Release:"
	@echo "  make tag-release  - Tag HEAD from doc/implementation/README.md index"
	@echo "  make push-release - Push main + current tag"
	@echo ""
	@echo "Requirements:"
	@echo "  - Xcode 15.0+"
	@echo "  - macOS 14.0+"
	@echo "  - Homebrew (for xcodegen installation)"

# =================== Release Helpers ===================

tag-release:
	@bash scripts/release/tag-from-doc.sh

push-release:
	@bash scripts/release/push-main.sh
	@echo ""
	@echo "Performance Targets (v0.md):"
	@echo "  - Search ≤5k items: P95 ≤ 50ms"
	@echo "  - Search 10k-100k: P95 ≤ 150ms"
	@echo "  - Debounce: 150-200ms"

release-validate:
	@bash scripts/release/validate-release-docs.sh

release-bump-patch:
	@bash scripts/release/bump-version.sh --patch
