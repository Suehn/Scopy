#!/bin/bash
# Scopy Release 构建脚本
# 构建 Release 版本并打包为 .dmg
#
# 用法:
#   ./scripts/build-release.sh
#
# 说明:
#   - v0.43.15 起，发布版本号以 git tag 为单一事实来源（详见 DEPLOYMENT.md）
#   - 本脚本会从当前 HEAD tag 解析版本并注入 MARKETING_VERSION/CURRENT_PROJECT_VERSION

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
APP_NAME="Scopy"
BUILD_DIR=".build/Release"
DMG_DIR=".build/dmg"

TAG_ON_HEAD="$(git tag --points-at HEAD --list 'v[0-9]*' --sort=v:refname | grep -v '^v0\\.18\\.' | tail -n 1 || true)"
if [[ -z "${TAG_ON_HEAD}" ]]; then
    echo -e "${RED}✗ 当前 HEAD 没有可用的 release tag（vX.Y.Z）${NC}"
    echo -e "${YELLOW}  建议：make tag-release && git push --follow-tags origin main${NC}"
    exit 1
fi

VERSION="${TAG_ON_HEAD#v}"
VERSION_ARGS="$(bash scripts/version.sh --xcodebuild-args 2>/dev/null || true)"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   Scopy Release 构建脚本${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "版本: ${YELLOW}${TAG_ON_HEAD}${NC}"
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
if ! xcodebuild -scheme Scopy -configuration Release build ${VERSION_ARGS} > /dev/null 2>&1; then
    echo -e "${RED}✗ 构建失败${NC}"
    echo "    运行以下命令查看详情:"
    echo "    xcodebuild -scheme Scopy -configuration Release build ${VERSION_ARGS}"
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
echo -e "  1. 在 GitHub 创建 Release (tag: ${TAG_ON_HEAD})"
echo -e "  2. 上传 .build/${DMG_NAME}"
echo -e "  3. 更新 Homebrew Cask（Homebrew/homebrew-cask 或自有 tap）中的 sha256"
echo ""
