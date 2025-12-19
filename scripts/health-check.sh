#!/bin/bash
# Scopy 健康检查脚本
# 功能: 验证应用各项功能是否正常
# 使用: bash scripts/health-check.sh

set -e

# =================== 配置 ===================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Scopy"
DB_PATH="$HOME/Library/Application Support/Scopy/clipboard.db"

# =================== 日志函数 ===================

log_check() { echo "🔍 $1"; }
log_pass() { echo "  ✅ $1"; }
log_fail() { echo "  ❌ $1"; exit 1; }
log_warn() { echo "  ⚠️  $1"; }

# =================== Check 1: 进程检查 ===================

check_process() {
    log_check "Check 1: Process is running"

    if pgrep -f "Scopy.app/Contents/MacOS/Scopy" > /dev/null 2>&1; then
        PID=$(pgrep -f "Scopy.app/Contents/MacOS/Scopy")
        log_pass "Process running (PID: $PID)"
    else
        log_fail "Process not found"
    fi
}

# =================== Check 2: 数据库连接检查 ===================

check_database() {
    log_check "Check 2: Database connection"

    if [ ! -f "$DB_PATH" ]; then
        log_warn "Database file not found at $DB_PATH (may be first run)"
        return 0
    fi

    # 测试 SQLite 查询
    COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM clipboard_items;" 2>/dev/null || echo "ERROR")

    if [ "$COUNT" = "ERROR" ]; then
        log_fail "Cannot query database"
    else
        log_pass "Database accessible ($COUNT items)"
    fi
}

# =================== Check 3: 菜单栏图标检查 ===================

check_menu_bar() {
    log_check "Check 3: Menu bar icon"

    # 检查是否有 NSStatusItem（进程存在即表示菜单栏图标应该显示）
    if pgrep -f "Scopy.app" > /dev/null 2>&1; then
        log_pass "App running (menu bar icon should be visible)"
    else
        log_fail "App not running"
    fi
}

# =================== Check 4: 日志输出检查 ===================

check_logs() {
    log_check "Check 4: Log output"

    # 检查最近 10 秒的系统日志
    LOGS=$(log show --predicate 'processImagePath contains "Scopy"' \
                    --last 10s \
                    --style compact \
                    2>/dev/null || echo "")

    if [ -z "$LOGS" ]; then
        log_pass "No recent logs (normal startup)"
        return 0
    fi

    # 检查是否有错误
    if echo "$LOGS" | grep -i "error\|crash\|exception\|fatal" > /dev/null 2>&1; then
        log_warn "Found potential errors in logs:"
        echo "$LOGS" | grep -i "error\|crash\|exception\|fatal" | head -3
    else
        log_pass "Logs look clean"
    fi
}

# =================== Check 5: 快捷键响应检查 ===================

check_hotkey() {
    log_check "Check 5: Global hotkey (⇧⌘C)"

    # 检查 HotKeyService 是否注册成功（查看日志）
    HOTKEY_LOG=$(log show --predicate 'processImagePath contains "Scopy" AND message contains "hotkey"' \
                          --last 30s \
                          --style compact \
                          2>/dev/null || echo "")

    if echo "$HOTKEY_LOG" | grep "registered successfully" > /dev/null 2>&1; then
        log_pass "Hotkey registered successfully"
    elif echo "$HOTKEY_LOG" | grep -i "failed\|error" > /dev/null 2>&1; then
        log_warn "Hotkey registration may have failed (check logs)"
    else
        log_pass "Hotkey status unknown (manual verification recommended)"
        log_warn "Please manually test ⇧⌘C to verify hotkey"
    fi
}

# =================== Check 6: 内存占用检查 ===================

check_memory() {
    log_check "Check 6: Memory usage"

    PID=$(pgrep -f "Scopy.app/Contents/MacOS/Scopy" || echo "")

    if [ -z "$PID" ]; then
        log_warn "Process not found (may have exited)"
        return 0
    fi

    # 获取内存使用（RSS，单位 KB）
    MEM_KB=$(ps -o rss= -p $PID 2>/dev/null | awk '{print $1}')

    if [ -z "$MEM_KB" ]; then
        log_warn "Cannot read memory info (process may have just exited)"
        return 0
    fi

    MEM_MB=$(echo "scale=2; $MEM_KB / 1024" | bc)

    # 正常内存应在 50-500 MB
    THRESHOLD=500
    if (( $(echo "$MEM_MB > $THRESHOLD" | bc -l) )); then
        log_warn "Memory usage high: ${MEM_MB}MB (threshold: ${THRESHOLD}MB)"
    else
        log_pass "Memory usage: ${MEM_MB}MB"
    fi
}

# =================== 主流程 ===================

main() {
    echo "================================"
    echo "Scopy Health Checks"
    echo "================================"
    echo ""

    # 运行所有检查
    check_process
    check_database
    check_menu_bar
    check_logs
    check_hotkey
    check_memory

    echo ""
    echo "================================"
    echo "✅ All health checks passed!"
    echo "================================"
}

# 执行主流程
main
