# Repository Guidelines

## 必读文档

- 行为准则要同时参考 @CLAUDE.md 的说法准则
- 启动前依次阅读：`doc/implemented-doc/README.md`（当前状态）、`doc/implemented-doc/CHANGELOG.md`（近期改动）、`doc/dev-doc/v0.md`（规格）。
- CLAUDE 约定：完成开发必须更新版本文档、索引、CHANGELOG；性能/部署变更需写入 `DEPLOYMENT.md`，含环境与具体数值。

## 项目结构

- 源码：`Scopy/`（入口 `main.swift` → `ScopyApp`，`AppDelegate` 管窗口/热键）。
- 服务：`Scopy/Services/`（HotKeyService、ClipboardMonitor、StorageService、SearchService）。
- 状态与协议：`Scopy/Observables/`，`Scopy/Protocols/`。
- 测试：`ScopyTests/`，`ScopyUITests/`。
- 文档：`doc/implemented-doc/`（版本/变更）、`doc/dev-doc/v0.md`（规格）。
- 脚本：`deploy.sh`，`Makefile`。

## 构建与开发

- Debug 构建：`./deploy.sh` 或 `xcodebuild -scheme Scopy -configuration Debug -destination 'platform=macOS' build`
- Release 构建：`./deploy.sh release`
- 仅编译不启动：`./deploy.sh --no-launch`
- 生成工程（需要时）：`xcodegen generate`

## 测试

- 单测：`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`
- 定向：`-only-testing:ScopyTests/<TestName>`
- 热键改动自查：`/tmp/scopy_hotkey.log` 应有 `updateHotKey()` 且按下仅触发一次。

## 编码风格

- Swift，4 空格缩进，协议优先、显式访问控制；默认 ASCII。
- 注释仅用于非显式逻辑；文件名匹配类型（例：`HotKeyService.swift`）。
- 搜索优先 `rg`；不回滚用户已有改动，避免破坏性 git 命令。

## 提交与 PR

- 提交信息：简短祈使句（例 “Fix hotkey recording”）。
- PR：说明改动、测试结果，UI 变更附截图，关联 issue；若性能/部署变化，附具体数据与环境。
- 版本发布（必须）：统一使用 **git tag** 驱动版本号与发布（禁止用“commit count 自动生成版本”）。
  - 创建版本提交（含 `doc/implemented-doc/vX.Y.Z.md`、索引、CHANGELOG、profile、必要时 `DEPLOYMENT.md`）
  - 打 tag（推荐从实现文档索引读取当前版本）：`make tag-release`
  - 推送（确保 tag 一并推送）：
    - 一次性：`make push-release`
    - 或手动：`git push origin main` + `git push origin vX.Y.Z`
  - Release 产物：GitHub Actions `Build and Release` 仅从 tag 构建；Cask 更新通过 PR 合入（workflow 不再直接 push main）。
  - 本地构建：推荐用 `make`/`./deploy.sh`（会注入 `MARKETING_VERSION/CURRENT_PROJECT_VERSION`；见 `scripts/version.sh`）。

## 架构与热键要点

- 统一入口 `AppDelegate.applyHotKey`：注册 + 持久化 UserDefaults；HotKeyService 仅监听 `kEventHotKeyPressed`，含轻节流防按住重复。
- 设置事件 `.settingsChanged` 兜底重应用热键。
- 热键日志：`/tmp/scopy_hotkey.log`。
