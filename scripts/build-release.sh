#!/bin/bash
# Scopy Release 构建脚本
# 构建 Release 版本并打包为 .dmg
#
# 用法:
#   ./scripts/build-release.sh           # 使用默认版本 0.18.0
#   ./scripts/build-release.sh 0.19.0    # 指定版本号

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$SCRIPT_DIR/.."
cd "$PROJECT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
VERSION="${1:-0.18.0}"
APP_NAME="Scopy"
BUILD_DIR=".build/Release"
DMG_DIR=".build/dmg"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   Scopy Release 构建脚本${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "版本: ${YELLOW}${VERSION}${NC}"
echo -e "输出: ${YELLOW}.build/${DMG_NAME}${NC}"
echo ""

# Step 1: 生成项目
echo -e "${BLUE}[1/5]${NC} 生成 Xcode 项目..."
if ! xcodegen generate > /dev/null 2>&1; then
    echo -e "${RED}✗ xcodegen 失败${NC}"
    echo "    请确保安装了 xcodegen: brew install xcodegen"
    exit 1
fi
echo -e "${GREEN}✓ 项目生成完成${NC}"

# Step 2: 构建 Release
echo -e "${BLUE}[2/5]${NC} 构建 Release 版本..."
if ! xcodebuild -scheme Scopy -configuration Release build > /dev/null 2>&1; then
    echo -e "${RED}✗ 构建失败${NC}"
    echo "    运行以下命令查看详情:"
    echo "    xcodebuild -scheme Scopy -configuration Release build"
    exit 1
fi
echo -e "${GREEN}✓ 构建成功${NC}"

# Step 3: 验证应用
echo -e "${BLUE}[3/5]${NC} 验证应用..."
if [ ! -d "${BUILD_DIR}/${APP_NAME}.app" ]; then
    echo -e "${RED}✗ 应用不存在: ${BUILD_DIR}/${APP_NAME}.app${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 应用已构建${NC}"

# Step 4: 创建 DMG
echo -e "${BLUE}[4/5]${NC} 创建 DMG..."

# 清理旧文件
rm -rf "$DMG_DIR"
rm -f ".build/${DMG_NAME}"

# 创建临时目录并复制应用
mkdir -p "$DMG_DIR"
cp -r "${BUILD_DIR}/${APP_NAME}.app" "$DMG_DIR/"

# 创建 DMG
if ! hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    ".build/${DMG_NAME}" > /dev/null 2>&1; then
    echo -e "${RED}✗ DMG 创建失败${NC}"
    exit 1
fi

# 清理临时目录
rm -rf "$DMG_DIR"

echo -e "${GREEN}✓ DMG 创建成功${NC}"

# Step 5: 计算 SHA256
echo -e "${BLUE}[5/5]${NC} 计算 SHA256..."
SHA256=$(shasum -a 256 ".build/${DMG_NAME}" | awk '{print $1}')
echo -e "${GREEN}✓ SHA256 计算完成${NC}"

# 显示结果
echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}✓ Release 构建完成！${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "📦 DMG 文件: ${YELLOW}.build/${DMG_NAME}${NC}"
echo -e "📊 文件大小: ${YELLOW}$(du -h ".build/${DMG_NAME}" | cut -f1)${NC}"
echo -e "🔐 SHA256:   ${YELLOW}${SHA256}${NC}"
echo ""
echo -e "下一步:"
echo -e "  1. 在 GitHub 创建 Release (tag: v${VERSION})"
echo -e "  2. 上传 .build/${DMG_NAME}"
echo -e "  3. 更新 homebrew-scopy/Casks/scopy.rb 中的 sha256"
echo ""
