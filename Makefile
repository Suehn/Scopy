# Scopy Makefile
# 符合 v0.md 的构建和测试流程

.PHONY: all setup build run clean xcode test test-unit test-perf test-tsan coverage benchmark test-flow test-flow-quick health-check

# 默认目标
all: build

# 安装依赖（xcodegen）
setup:
	@echo "Installing xcodegen if not present..."
	@which xcodegen > /dev/null || brew install xcodegen
	@echo "Generating Xcode project..."
	xcodegen generate

# 生成 Xcode 项目
xcode: setup
	open Scopy.xcodeproj

# 构建项目
build: setup
	@echo "Building Scopy..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build

# 构建 Release 版本
release: setup
	@echo "Building Scopy (Release)..."
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release build

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
	xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Debug build

# =================== 测试命令 ===================

# 运行所有测试
test: setup
	@echo "Running all tests..."
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-resultBundlePath TestResults.xcresult \
		2>&1 | tee test.log

# 仅运行单元测试（排除性能测试）
test-unit: setup
	@echo "Running unit tests..."
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/StorageServiceTests \
		-only-testing:ScopyTests/SearchServiceTests \
		-only-testing:ScopyTests/ClipboardMonitorTests \
		2>&1 | tee test-unit.log

# 运行性能测试
test-perf: setup
	@echo "Running performance tests..."
	RUN_PERF_TESTS=1 xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/PerformanceTests \
		2>&1 | tee test-perf.log

# Thread Sanitizer (requires hosted test bundle mode)
test-tsan: setup
	@echo "Running Thread Sanitizer tests..."
	ENABLE_THREAD_SANITIZER=YES xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme ScopyTSan \
		-destination 'platform=macOS' \
		-only-testing:ScopyTSanTests \
		2>&1 | tee test-tsan.log

# 运行集成测试
test-integration: setup
	@echo "Running integration tests..."
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/IntegrationTests \
		2>&1 | tee test-integration.log

# 生成测试覆盖率报告
coverage: setup
	@echo "Running tests with coverage..."
	xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-enableCodeCoverage YES \
		-resultBundlePath CoverageResults.xcresult \
		2>&1 | tee coverage.log
	@echo ""
	@echo "Coverage report generated at CoverageResults.xcresult"
	@echo "View with: xcrun xccov view --report CoverageResults.xcresult"

# 运行基准测试
benchmark: setup
	@echo "Running benchmarks..."
	@echo "This will take a few minutes..."
	RUN_PERF_TESTS=1 xcodebuild test \
		-project Scopy.xcodeproj \
		-scheme Scopy \
		-destination 'platform=macOS' \
		-only-testing:ScopyTests/PerformanceTests \
		2>&1 | tee benchmark-output.log
	@echo ""
	@echo "Benchmark results saved to benchmark-output.log"

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
	@echo "  make test-integration - Run integration tests"
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
	@echo "Requirements:"
	@echo "  - Xcode 15.0+"
	@echo "  - macOS 14.0+"
	@echo "  - Homebrew (for xcodegen installation)"
	@echo ""
	@echo "Performance Targets (v0.md):"
	@echo "  - Search ≤5k items: P95 ≤ 50ms"
	@echo "  - Search 10k-100k: P95 ≤ 150ms"
	@echo "  - Debounce: 150-200ms"
