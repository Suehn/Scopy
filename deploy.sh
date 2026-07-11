#!/bin/bash

# Scopy 快速部署脚本
# 编译到独立的 Xcode DerivedData，然后部署到 /Applications
#
# 用法:
#   ./deploy.sh              # Debug 版本
#   ./deploy.sh release                 # Release 版本
#   ./deploy.sh clean                   # 清理后重新部署 Debug
#   ./deploy.sh release --no-launch     # 部署 Release 但不启动应用

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$SCRIPT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
CONFIGURATION="Debug"
DO_CLEAN=false
LAUNCH_APP=true
XCODE_DERIVED_DATA="${SCOPY_XCODE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Scopy-Deploy}"

case "$XCODE_DERIVED_DATA" in
    /*) ;;
    *)
        echo "SCOPY_XCODE_DERIVED_DATA 必须是绝对路径: $XCODE_DERIVED_DATA" >&2
        exit 2
        ;;
esac
if [[ "$XCODE_DERIVED_DATA" == "/" || "$XCODE_DERIVED_DATA" == "$HOME" || "$XCODE_DERIVED_DATA" == "$PROJECT_DIR" ]]; then
    echo "拒绝使用不安全的 DerivedData 路径: $XCODE_DERIVED_DATA" >&2
    exit 2
fi

# 解析参数
for argument in "$@"; do
    case "$argument" in
        clean)
            DO_CLEAN=true
            ;;
        release|Release)
            CONFIGURATION="Release"
            ;;
        debug|Debug)
            CONFIGURATION="Debug"
            ;;
        --no-launch)
            LAUNCH_APP=false
            ;;
        *)
            echo "未知参数: $argument" >&2
            echo "用法: ./deploy.sh [debug|release] [clean] [--no-launch]" >&2
            exit 2
            ;;
    esac
done

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   Scopy 快速部署脚本${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "配置: ${YELLOW}$CONFIGURATION${NC}"
echo -e "项目路径: ${YELLOW}$PROJECT_DIR${NC}"
echo -e "输出目录: ${YELLOW}$XCODE_DERIVED_DATA/Build/Products${NC}"

VERSION_ARGS="$(bash "$PROJECT_DIR/scripts/version.sh" --xcodebuild-args 2>/dev/null || true)"
if [[ -n "${VERSION_ARGS}" ]]; then
    echo -e "版本参数: ${YELLOW}${VERSION_ARGS}${NC}"
fi
echo ""

# Step 1: 清理 (可选)
if [ "$DO_CLEAN" = true ]; then
    echo -e "${BLUE}[1/6]${NC} 清理项目..."
    rm -rf "$XCODE_DERIVED_DATA"
    xcodebuild clean -project Scopy.xcodeproj -scheme Scopy -configuration "$CONFIGURATION" \
        -derivedDataPath "$XCODE_DERIVED_DATA" > /dev/null 2>&1 || true
    echo -e "${GREEN}✓ 清理完成${NC}"
    echo ""
fi

# Step 2: 生成项目
echo -e "${BLUE}[2/6]${NC} 生成 Xcode 项目..."
cd "$PROJECT_DIR"
if ! xcodegen generate > /dev/null 2>&1; then
    echo -e "${RED}✗ xcodegen 失败${NC}"
    echo "    请确保安装了 xcodegen: brew install xcodegen"
    exit 1
fi
echo -e "${GREEN}✓ 项目生成完成${NC}"
echo ""

# Step 3: 创建 Xcode DerivedData 目录
echo -e "${BLUE}[3/6]${NC} 准备构建目录..."
mkdir -p "$XCODE_DERIVED_DATA"
echo -e "${GREEN}✓ Xcode DerivedData 目录就绪${NC}"
echo ""

# Step 4: 编译应用
echo -e "${BLUE}[4/6]${NC} 编译应用 ($CONFIGURATION 模式)..."
BUILD_LOG="$XCODE_DERIVED_DATA/deploy-${CONFIGURATION}.log"
if ! xcodebuild build \
    -project Scopy.xcodeproj \
    -scheme Scopy \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$XCODE_DERIVED_DATA" \
    ${VERSION_ARGS} \
    > "$BUILD_LOG" 2>&1; then
    echo -e "${RED}✗ 编译失败${NC}"
    echo "    日志: $BUILD_LOG"
    echo "    最后 80 行:"
    tail -n 80 "$BUILD_LOG"
    exit 1
fi
echo -e "${GREEN}✓ 编译成功${NC}"
echo ""

# Step 5: 验证应用位置
echo -e "${BLUE}[5/6]${NC} 验证应用位置..."

# 应用构建到显式 DerivedData，避免与 SwiftPM `.build` 及文件同步元数据互相污染。
BUILD_APP="$XCODE_DERIVED_DATA/Build/Products/$CONFIGURATION/Scopy.app"
if [ ! -d "$BUILD_APP" ]; then
    echo -e "${RED}✗ 应用包不存在: $BUILD_APP${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 应用已构建: $BUILD_APP${NC}"
echo ""

# Step 6: 部署到 /Applications
echo -e "${BLUE}[6/6]${NC} 部署应用到 /Applications..."

# 关闭运行中的应用
killall Scopy 2>/dev/null || true
sleep 0.5

# 备份旧版本
if [ -d /Applications/Scopy.app ]; then
    rm -rf /Applications/Scopy_backup.app
    mv /Applications/Scopy.app /Applications/Scopy_backup.app
    echo -e "${YELLOW}  → 旧版本已备份到 Scopy_backup.app${NC}"
fi

# 复制新应用
cp -r "$BUILD_APP" /Applications/

# 检查复制结果
if [ ! -d /Applications/Scopy.app ]; then
    echo -e "${RED}✗ 复制失败${NC}"
    # 恢复备份
    if [ -d /Applications/Scopy_backup.app ]; then
        mv /Applications/Scopy_backup.app /Applications/Scopy.app
        echo -e "${YELLOW}  → 已恢复备份版本${NC}"
    fi
    exit 1
fi

echo -e "${GREEN}✓ 应用已部署${NC}"
echo ""

# 显示结果
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}✓ 部署成功！${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# 显示构建信息
echo -e "📂 文件位置:"
echo -e "  ${YELLOW}项目构建: $BUILD_APP${NC}"
echo -e "  ${YELLOW}已安装: /Applications/Scopy.app${NC}"
echo ""

# 应用大小
if [ -d "/Applications/Scopy.app" ]; then
    APP_SIZE=$(du -sh /Applications/Scopy.app | cut -f1)
    echo -e "📊 应用大小: ${YELLOW}$APP_SIZE${NC}"
fi

echo ""
echo -e "🚀 快速命令:"
echo -e "  ${YELLOW}启动应用${NC}:      open /Applications/Scopy.app"
echo -e "  ${YELLOW}运行测试${NC}:      xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests"
echo -e "  ${YELLOW}打开项目${NC}:      open Scopy.xcodeproj"
echo ""

# 询问是否立即启动
if [ "$LAUNCH_APP" = true ]; then
    read -p "是否现在启动应用? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open /Applications/Scopy.app
        echo -e "${GREEN}✓ 应用已启动${NC}"
    fi
fi
