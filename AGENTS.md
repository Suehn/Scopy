# Repository Guidelines

## AI Coding Workflow（Codex / Claude Code）

### 真实约束（不要猜）

- 以 `project.yml` 为单一事实来源：`SWIFT_VERSION` / `MACOSX_DEPLOYMENT_TARGET` / `xcodeVersion`；除非明确要求，不要改这些基线。
- 引入新系统 API（例如 macOS 26 / Liquid Glass）必须 `if #available` + fallback；把可用性封装在组件/适配层，避免业务逻辑散落条件分支。

### 权威上下文（防幻觉）

- 不要凭记忆编 Apple / Swift API：先用 MCP `cupertino` 搜索/阅读 Apple 文档或 sample code，确认**精确签名**与平台可用性再落代码。
- 文档仍以编译器为裁判：写完立刻本地编译/测试，不留“占位实现”。

### 验证闭环（改代码后必跑）

- 基线：`make build` + `make test-unit`
- 并发/actor/线程相关：额外跑 `make test-strict`；需要时跑 `make test-tsan`
- 热键相关：自查 `/tmp/scopy_hotkey.log`（按下仅触发一次，且包含 `updateHotKey()`）
- 注意：`make build/test*` 会触发 `make setup`；若缺 `xcodegen` 可能会尝试 `brew install xcodegen`，在无法联网或未授权时先询问。

## 必读文档

- 行为准则要同时参考 @CLAUDE.md 的说法准则
- 启动前依次阅读：`doc/implementation/README.md`（当前状态）、`doc/implementation/CHANGELOG.md`（近期改动）、`doc/specs/v0.md`（规格）。
- CLAUDE 约定：完成开发必须更新版本文档、索引、CHANGELOG；性能/部署变更需写入 `DEPLOYMENT.md`，含环境与具体数值。

## 项目结构

- 源码：`Scopy/`（入口 `main.swift` → `ScopyApp`，`AppDelegate` 管窗口/热键）。
- 服务：`Scopy/Services/`（HotKeyService、ClipboardMonitor、StorageService、SearchService）。
- 状态与协议：`Scopy/Observables/`，`Scopy/Protocols/`。
- 测试：`ScopyTests/`，`ScopyUITests/`。
- 文档：`doc/implementation/`（版本/变更）、`doc/specs/v0.md`（规格）。
- 脚本：`deploy.sh`，`Makefile`。

## 构建与开发

- Debug 构建：`make build`（推荐）或 `./deploy.sh`
- Release 构建：`make release` 或 `./deploy.sh release`
- 仅编译不启动：`./deploy.sh --no-launch`
- 生成工程（需要时）：`bash scripts/xcodegen-generate-if-needed.sh` 或 `xcodegen generate`

## 测试

- 单测（推荐）：`make test-unit`（或 `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`）
- 并发回归（推荐）：`make test-strict`（`SWIFT_STRICT_CONCURRENCY=complete`）
- 定向：`-only-testing:ScopyTests/<TestName>`
- 热键改动自查：`/tmp/scopy_hotkey.log` 应有 `updateHotKey()` 且按下仅触发一次。
- 性能基准测试必须使用从 `~/Library/Application Support/Scopy/clipboard.db` 快照到仓库内的最新副本（`make snapshot-perf-db`，文件不提交）。

## 编码风格

- Swift，4 空格缩进，协议优先、显式访问控制；默认 ASCII。
- 注释仅用于非显式逻辑；文件名匹配类型（例：`HotKeyService.swift`）。
- 搜索优先 `rg`；不回滚用户已有改动，避免破坏性 git 命令。

## 提交与 PR

- 提交信息：简短祈使句（例 “Fix hotkey recording”）。
- PR：说明改动、测试结果，UI 变更附截图，关联 issue；若性能/部署变化，附具体数据与环境。
- 版本发布（必须）：统一使用 **git tag** 驱动版本号与发布（禁止用“commit count 自动生成版本”）。
  - 创建版本提交（含 `doc/implementation/releases/vX.Y.Z.md`、索引、CHANGELOG、profile、必要时 `DEPLOYMENT.md`）
  - 发布前校验（必须过）：`make release-validate`（校验索引里的 **当前版本** 对应的版本文档/CHANGELOG 条目都存在）
  - 需要创建新版本文档骨架时：`make release-bump-patch`（从实现文档索引读取当前版本并递增 patch）
  - 打 tag（推荐从实现文档索引读取当前版本）：`make tag-release`
  - 推送（确保 tag 一并推送）：
    - 一次性：`make push-release`
    - 或手动：`git push origin main` + `git push origin vX.Y.Z`
  - Release 产物：GitHub Actions `Build and Release` 仅从 tag 构建并上传 DMG + `.sha256`；并会在 `main` 上更新本仓库 `Casks/scopy.rb` 到同版本与 sha；同时尝试更新 `Suehn/homebrew-scopy`（依赖 `HOMEBREW_GITHUB_API_TOKEN`，缺失时会跳过）。
  - 发布完成定义（必须做到）：**Homebrew 可安装/可升级到该版本**。
    - 等待 tag 对应 release 产出 `Scopy-<version>.dmg` + `Scopy-<version>.dmg.sha256`（不要覆盖同 tag 的 DMG；修复发布请 bump 版本重发）
    - 同步源检查（必须）：`curl -fsSL https://raw.githubusercontent.com/Suehn/Scopy/main/Casks/scopy.rb | sed -n '1,12p'`（version/sha 必须匹配上一步的 `.sha256`）
    - tap 检查（必须）：`curl -fsSL https://raw.githubusercontent.com/Suehn/homebrew-scopy/main/Casks/scopy.rb | sed -n '1,12p'`（应与同步源一致；若仍旧版本，通常是 workflow 缺少权限/secret，需手动提交 tap 仓库的 `Casks/scopy.rb`）
    - 本地验证：`brew tap Suehn/scopy` → `brew update` → `brew info --cask scopy`（看 version/From）→ `brew fetch --cask scopy -f`（必要时 `brew cat scopy` 排查 cask 内容）
    - 安装落地校验（必须做）：确认 `/Applications/Scopy.app` 存在；若未出现，执行 `brew reinstall --cask scopy --appdir=/Applications` 或从 `/opt/homebrew/Caskroom/scopy/<version>/Scopy.app` 手动复制到 `/Applications`。
    - 常见故障排查（版本“回滚/下载错版本”）：
      - 先看本地到底用的哪个 cask：`brew info --cask scopy`（From/版本），必要时 `brew cat scopy`。
      - 强制刷新 tap + 重装（适用于“以为是 fix18 但装到 fix2”这类缓存/旧 tap 场景）：
        ```bash
        brew untap Suehn/scopy >/dev/null 2>&1
        rm -rf "$(brew --repo Suehn/scopy 2>/dev/null || true)"
        brew update && brew tap Suehn/scopy && brew update
        brew reinstall --cask scopy --force --appdir=/Applications
        xattr -dr com.apple.quarantine /Applications/Scopy.app 2>/dev/null || true
        ```
      - 用 Info.plist 确认真正安装的版本（不要只看 UI/文件名）：`defaults read /Applications/Scopy.app/Contents/Info CFBundleShortVersionString`
  - 本地构建：推荐用 `make`/`./deploy.sh`（会注入 `MARKETING_VERSION/CURRENT_PROJECT_VERSION`；见 `scripts/version.sh`）。

## 架构与热键要点

- 统一入口 `AppDelegate.applyHotKey`：注册 + 持久化 UserDefaults；HotKeyService 仅监听 `kEventHotKeyPressed`，含轻节流防按住重复。
- 设置事件 `.settingsChanged` 兜底重应用热键。
- 热键日志：`/tmp/scopy_hotkey.log`。

## 设置窗口约定

- Settings 使用显式 **Save/Cancel** 事务模型（`isDirty`），UI 重排/视觉改进需避免任何设置逻辑/行为变化（不要改成 autosave）。
