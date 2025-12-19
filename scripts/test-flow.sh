#!/bin/bash
# Scopy 测试流程自动化脚本
# 功能: 杀进程 → 编译 → 安装 → 启动 → 健康检查
# 使用: bash scripts/test-flow.sh [--skip-build] [--verbose]

set -e

# =================== 配置 ===================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Scopy"
INSTALL_PATH="/Applications/Scopy.app"
BUILD_CONFIG="Debug"
BACKUP_PATH="/tmp/Scopy-backup-$(date +%s).app"

# =================== 日志函数 ===================

log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_error() { echo "❌ $1" >&2; }
log_warn() { echo "⚠️  $1"; }

# =================== 步骤 1: 杀掉所有 Scopy 进程 ===================

kill_existing_processes() {
    log_info "Killing existing Scopy processes..."

    # 查找所有 Scopy 进程
    PIDS=$(pgrep -f "Scopy.app/Contents/MacOS/Scopy" || true)

    if [ -z "$PIDS" ]; then
        log_info "No existing Scopy processes found"
        return 0
    fi

    log_info "Found processes: $PIDS"

    # 尝试优雅关闭 (SIGTERM)
    echo "$PIDS" | xargs kill -TERM 2>/dev/null || true
    sleep 2

    # 检查是否仍在运行
    PIDS=$(pgrep -f "Scopy.app/Contents/MacOS/Scopy" || true)
    if [ -n "$PIDS" ]; then
        log_warn "Processes still running, force killing..."
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi

    # 最终验证
    PIDS=$(pgrep -f "Scopy.app/Contents/MacOS/Scopy" || true)
    if [ -n "$PIDS" ]; then
        log_error "Failed to kill processes: $PIDS"
        return 1
    fi

    log_success "All Scopy processes terminated"
}

# =================== 步骤 2: 备份现有应用 ===================

backup_existing_app() {
    if [ -d "$INSTALL_PATH" ]; then
        log_info "Backing up existing app to $BACKUP_PATH..."
        cp -r "$INSTALL_PATH" "$BACKUP_PATH"
        log_success "Backup created"
    else
        log_info "No existing app to backup"
    fi
}

# =================== 步骤 3: 编译应用 ===================

build_app() {
    if [ "$SKIP_BUILD" = "true" ]; then
        log_warn "Skipping build (--skip-build flag)"
        return 0
    fi

    log_info "Building Scopy..."
    cd "$PROJECT_DIR"

    # 确保 xcodegen 项目最新
    if [ ! -f "Scopy.xcodeproj/project.pbxproj" ]; then
        log_info "Generating Xcode project..."
        xcodegen generate
    fi

    # 编译
    log_info "Running xcodebuild..."
    xcodebuild -project Scopy.xcodeproj \
               -scheme Scopy \
               -configuration "$BUILD_CONFIG" \
               build \
               > /tmp/scopy-build.log 2>&1

    # 检查编译结果
    if [ $? -ne 0 ]; then
        log_error "Build failed! Check /tmp/scopy-build.log for details"
        tail -20 /tmp/scopy-build.log
        return 1
    fi

    log_success "Build succeeded"
}

# =================== 步骤 4: 安装到 /Applications/ ===================

install_app() {
    log_info "Installing Scopy to $INSTALL_PATH..."

    # 查找编译产物
    BUILD_DIR=$(xcodebuild -project "$PROJECT_DIR/Scopy.xcodeproj" \
                           -scheme Scopy \
                           -configuration "$BUILD_CONFIG" \
                           -showBuildSettings 2>/dev/null \
                           | grep "CONFIGURATION_BUILD_DIR" \
                           | head -1 \
                           | awk '{print $3}')

    if [ -z "$BUILD_DIR" ]; then
        log_error "Failed to determine build directory"
        return 1
    fi

    log_info "Build directory: $BUILD_DIR"

    if [ ! -d "$BUILD_DIR/Scopy.app" ]; then
        log_error "Build product not found at $BUILD_DIR/Scopy.app"
        return 1
    fi

    # 删除旧应用
    if [ -d "$INSTALL_PATH" ]; then
        log_info "Removing old app..."
        rm -rf "$INSTALL_PATH"
    fi

    # 复制新应用
    log_info "Copying new app..."
    cp -r "$BUILD_DIR/Scopy.app" "$INSTALL_PATH"

    # 验证安装
    if [ ! -d "$INSTALL_PATH" ]; then
        log_error "Installation failed"
        return 1
    fi

    log_success "App installed to $INSTALL_PATH"
}

# =================== 步骤 5: 启动应用 ===================

launch_app() {
    log_info "Launching Scopy with real service..."

    # 使用真实服务（非 Mock）
    USE_MOCK_SERVICE=0 "$INSTALL_PATH/Contents/MacOS/Scopy" > /tmp/scopy-launch.log 2>&1 &
    APP_PID=$!

    log_info "App launched with PID: $APP_PID"
    echo "$APP_PID" > /tmp/scopy-test-pid

    # 等待应用启动
    sleep 3

    # 检查进程是否仍在运行
    if ! ps -p $APP_PID > /dev/null 2>&1; then
        log_error "App crashed immediately after launch"
        log_error "Launch log:"
        cat /tmp/scopy-launch.log
        return 1
    fi

    log_success "App is running (PID: $APP_PID)"
}

# =================== 步骤 6: 运行健康检查 ===================

run_health_checks() {
    log_info "Running health checks..."

    if [ ! -f "$PROJECT_DIR/scripts/health-check.sh" ]; then
        log_warn "Health check script not found, skipping..."
        return 0
    fi

    bash "$PROJECT_DIR/scripts/health-check.sh"
}

# =================== 回滚函数 ===================

rollback() {
    log_warn "Rolling back due to failure..."

    # 杀掉测试进程
    if [ -f /tmp/scopy-test-pid ]; then
        PID=$(cat /tmp/scopy-test-pid)
        if [ -n "$PID" ]; then
            log_info "Killing test process (PID: $PID)..."
            kill -9 $PID 2>/dev/null || true
        fi
        rm /tmp/scopy-test-pid
    fi

    # 恢复备份
    if [ -d "$BACKUP_PATH" ]; then
        log_info "Restoring from backup..."
        rm -rf "$INSTALL_PATH"
        cp -r "$BACKUP_PATH" "$INSTALL_PATH"
        log_success "Backup restored"
    fi
}

# =================== 清理函数 ===================

cleanup() {
    # 清理备份
    if [ -d "$BACKUP_PATH" ]; then
        log_info "Cleaning up backup..."
        rm -rf "$BACKUP_PATH"
    fi

    # 清理临时文件
    rm -f /tmp/scopy-build.log
    rm -f /tmp/scopy-launch.log
}

# =================== 主流程 ===================

main() {
    echo "================================"
    log_info "Starting Scopy test flow..."
    echo "================================"

    # 解析参数
    SKIP_BUILD=false
    VERBOSE=false
    for arg in "$@"; do
        case $arg in
            --skip-build)
                SKIP_BUILD=true
                ;;
            --verbose)
                VERBOSE=true
                set -x
                ;;
            *)
                log_error "Unknown argument: $arg"
                echo "Usage: $0 [--skip-build] [--verbose]"
                exit 1
                ;;
        esac
    done

    # 设置错误处理（遇到错误自动回滚）
    trap 'rollback; exit 1' ERR

    # 执行步骤
    kill_existing_processes
    backup_existing_app
    build_app
    install_app
    launch_app
    run_health_checks

    # 成功后清理
    cleanup

    echo "================================"
    log_success "Test flow completed successfully!"
    echo "================================"
    log_info "App is running at $INSTALL_PATH"
    log_info "PID: $(cat /tmp/scopy-test-pid 2>/dev/null || echo 'N/A')"
    log_info ""
    log_info "Next steps:"
    log_info "  - Test the app manually"
    log_info "  - Run: make test"
    log_info "  - Kill app: pkill -9 Scopy"
}

# 执行主流程
main "$@"
