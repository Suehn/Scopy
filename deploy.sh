#!/bin/bash

# Scopy 快速部署脚本
# 编译到 .build 目录，然后部署到 /Applications
#
# 用法:
#   ./deploy.sh              # Debug 版本
#   ./deploy.sh release      # Release 版本
#   ./deploy.sh clean        # 清理后重新部署
#   ./deploy.sh --no-launch  # 部署但不启动应用

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
CONFIGURATION="${1:-Debug}"
DO_CLEAN=false
LAUNCH_APP=true

# 解析参数
case "$1" in
    clean)
        CONFIGURATION="Debug"
        DO_CLEAN=true
        ;;
    release)
        CONFIGURATION="Release"
        ;;
    --no-launch)
        CONFIGURATION="Debug"
        LAUNCH_APP=false
        ;;
esac

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   Scopy 快速部署脚本${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "配置: ${YELLOW}$CONFIGURATION${NC}"
echo -e "项目路径: ${YELLOW}$PROJECT_DIR${NC}"
echo -e "输出目录: ${YELLOW}$PROJECT_DIR/.build${NC}"
echo ""

# Step 1: 清理 (可选)
if [ "$DO_CLEAN" = true ]; then
    echo -e "${BLUE}[1/6]${NC} 清理项目..."
    rm -rf "$PROJECT_DIR/.build"
    xcodebuild clean -scheme Scopy -configuration "$CONFIGURATION" > /dev/null 2>&1 || true
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

# Step 3: 创建 .build 目录
echo -e "${BLUE}[3/6]${NC} 准备构建目录..."
mkdir -p "$PROJECT_DIR/.build"
echo -e "${GREEN}✓ .build 目录就绪${NC}"
echo ""

# Step 4: 编译应用
echo -e "${BLUE}[4/6]${NC} 编译应用 ($CONFIGURATION 模式)..."
if ! xcodebuild build \
    -scheme Scopy \
    -configuration "$CONFIGURATION" \
    > /dev/null 2>&1; then
    echo -e "${RED}✗ 编译失败${NC}"
    echo "    运行以下命令查看详情:"
    echo "    xcodebuild build -scheme Scopy -configuration $CONFIGURATION"
    exit 1
fi
echo -e "${GREEN}✓ 编译成功${NC}"
echo ""

# Step 5: 验证应用位置
echo -e "${BLUE}[5/6]${NC} 验证应用位置..."

# 应用直接构建到 .build/$CONFIGURATION/Scopy.app (由 project.yml 的 BUILD_DIR 设置)
BUILD_APP="$PROJECT_DIR/.build/$CONFIGURATION/Scopy.app"
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
