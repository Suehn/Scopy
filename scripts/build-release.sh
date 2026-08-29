#!/bin/bash
# Scopy Release 构建脚本
# 构建 Release 版本并打包为 .dmg
#
# 用法:
#   ./scripts/build-release.sh
#
# 说明:
#   - v0.43.15 起，发布版本号以 git tag 为单一事实来源（详见 doc/current/release-runbook.md）
#   - 本脚本会从当前 HEAD tag 解析版本并注入 MARKETING_VERSION/CURRENT_PROJECT_VERSION

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
APP_NAME="Scopy"
XCODE_DERIVED_DATA="${SCOPY_XCODE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Scopy-Release}"
BUILD_DIR="$XCODE_DERIVED_DATA/Build/Products/Release"
DMG_DIR=".build/dmg"
BUILD_LOG="$XCODE_DERIVED_DATA/build-release.log"

case "$XCODE_DERIVED_DATA" in
    /*) ;;
    *)
        echo "SCOPY_XCODE_DERIVED_DATA must be an absolute path: $XCODE_DERIVED_DATA" >&2
        exit 2
        ;;
esac
if [[ "$XCODE_DERIVED_DATA" == "/" || "$XCODE_DERIVED_DATA" == "$HOME" || "$XCODE_DERIVED_DATA" == "$PROJECT_DIR" ]]; then
    echo "Refusing unsafe DerivedData path: $XCODE_DERIVED_DATA" >&2
    exit 2
fi

TAG_ON_HEAD="$(bash scripts/version.sh --tag 2>/dev/null || true)"
if [[ -z "${TAG_ON_HEAD}" ]] || [[ "$(git rev-list -n 1 "${TAG_ON_HEAD}" 2>/dev/null || true)" != "$(git rev-parse HEAD)" ]]; then
    echo -e "${RED}✗ 当前 HEAD 没有可用的 release tag（vX.Y.Z）${NC}"
    echo -e "${YELLOW}  建议：make tag-release && git push --follow-tags origin main${NC}"
    exit 1
fi

VERSION="${TAG_ON_HEAD#v}"
VERSION_ARGS="$(bash scripts/version.sh --xcodebuild-args 2>/dev/null || true)"
if [[ "${VERSION_ARGS}" != *"MARKETING_VERSION=${VERSION}"* ]]; then
    echo -e "${RED}✗ version.sh 与 release tag 解析不一致：${VERSION_ARGS}${NC}"
    exit 1
fi
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH=".build/${DMG_NAME}"
SHA_FILE="${DMG_PATH}.sha256"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   Scopy Release 构建脚本${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "版本: ${YELLOW}${TAG_ON_HEAD}${NC}"
echo -e "输出: ${YELLOW}${DMG_PATH}${NC}"
echo ""

# Step 1: 验证仓库内 MarkdownPreview 发布资产
echo -e "${BLUE}[1/6]${NC} 验证 MarkdownPreview 发布资产..."
if ! make markdown-assets-gate; then
    echo -e "${RED}✗ MarkdownPreview 发布资产不是同一锁定版本${NC}"
    echo "    renderer source、IIFE、sidecar、KaTeX CSS/fonts 与 manifest 必须全部同步"
    exit 1
fi
echo -e "${GREEN}✓ MarkdownPreview 发布资产验证完成${NC}"

# Step 2: 生成项目
echo -e "${BLUE}[2/6]${NC} 生成 Xcode 项目..."
if ! xcodegen generate > /dev/null 2>&1; then
    echo -e "${RED}✗ xcodegen 失败${NC}"
    echo "    请确保安装了 xcodegen: brew install xcodegen"
    exit 1
fi
echo -e "${GREEN}✓ 项目生成完成${NC}"

# Step 3: 构建 Release
echo -e "${BLUE}[3/6]${NC} 构建 Release 版本..."
mkdir -p "$XCODE_DERIVED_DATA"
if ! xcodebuild -project Scopy.xcodeproj -scheme Scopy -configuration Release \
    -derivedDataPath "$XCODE_DERIVED_DATA" build ${VERSION_ARGS} > "$BUILD_LOG" 2>&1; then
    echo -e "${RED}✗ 构建失败${NC}"
    echo "    Log: $BUILD_LOG"
    echo "    Last 80 lines:"
    tail -n 80 "$BUILD_LOG"
    exit 1
fi
echo -e "${GREEN}✓ 构建成功${NC}"

# Step 4: 验证应用与最终资源副本
echo -e "${BLUE}[4/6]${NC} 验证应用与最终 MarkdownPreview 资源..."
if [ ! -d "${BUILD_DIR}/${APP_NAME}.app" ]; then
    echo -e "${RED}✗ 应用不存在: ${BUILD_DIR}/${APP_NAME}.app${NC}"
    exit 1
fi
BUILT_ASSET_ROOT="${BUILD_DIR}/${APP_NAME}.app/Contents/Resources/MarkdownPreview"
if ! node Tools/MarkdownRenderer/scripts/verify-assets.mjs --asset-root "$BUILT_ASSET_ROOT"; then
    echo -e "${RED}✗ 最终应用内 MarkdownPreview 资源验证失败${NC}"
    exit 1
fi
BUILT_RESOURCE_ROOT="${BUILD_DIR}/${APP_NAME}.app/Contents/Resources"
for duplicate in katex.min.css scopy-unified-renderer.iife.js scopy-unified-renderer.iife.js.sha256; do
    if [ -e "${BUILT_RESOURCE_ROOT}/${duplicate}" ]; then
        echo -e "${RED}✗ 检测到扁平化的重复 MarkdownPreview 资源: ${duplicate}${NC}"
        exit 1
    fi
done
if find "$BUILT_RESOURCE_ROOT" -maxdepth 1 -name 'KaTeX_*' -print -quit | grep -q .; then
    echo -e "${RED}✗ 检测到扁平化的重复 KaTeX 字体${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 应用及最终 MarkdownPreview 资源已验证${NC}"

# Step 5: 创建 DMG
echo -e "${BLUE}[5/6]${NC} 创建 DMG..."

# 清理旧文件
rm -rf "$DMG_DIR"
rm -f "$DMG_PATH" "$SHA_FILE"

# 创建临时目录并复制应用
mkdir -p "$DMG_DIR"
cp -r "${BUILD_DIR}/${APP_NAME}.app" "$DMG_DIR/"

# 创建 DMG
if ! hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null 2>&1; then
    echo -e "${RED}✗ DMG 创建失败${NC}"
    exit 1
fi

# 清理临时目录
rm -rf "$DMG_DIR"

echo -e "${GREEN}✓ DMG 创建成功${NC}"

# Step 6: 计算 SHA256
echo -e "${BLUE}[6/6]${NC} 计算 SHA256..."
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
printf '%s  %s\n' "$SHA256" "$DMG_NAME" > "$SHA_FILE"
echo -e "${GREEN}✓ SHA256 计算完成${NC}"

# 显示结果
echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}✓ Release 构建完成！${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "📦 DMG 文件: ${YELLOW}${DMG_PATH}${NC}"
echo -e "📊 文件大小: ${YELLOW}$(du -h "$DMG_PATH" | cut -f1)${NC}"
echo -e "🔐 SHA256:   ${YELLOW}${SHA256}${NC}"
echo -e "🧾 SHA 文件: ${YELLOW}${SHA_FILE}${NC}"
echo ""
echo -e "下一步:"
echo -e "  1. 在 GitHub 创建 Release (tag: ${TAG_ON_HEAD})"
echo -e "  2. 上传 ${DMG_PATH} 和 ${SHA_FILE}"
echo -e "  3. 更新 Homebrew Cask（Homebrew/homebrew-cask 或自有 tap）中的 sha256"
echo ""
