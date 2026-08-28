# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## AI 工程化护栏（防幻觉 / 可验证）

### Required engineering principles

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

### 真实约束（不要猜）

- 以 `project.yml` 为单一事实来源：当前 `SWIFT_VERSION=5.9`、`MACOSX_DEPLOYMENT_TARGET=14.0`；除非明确要求，不要擅自升级语言版本/最低系统版本。
- 引入新系统 API（例如 macOS 26 / Liquid Glass）必须 `if #available` + fallback，并把可用性判断封装在组件内部（避免业务逻辑散落条件分支）。

### 权威上下文（Apple / Swift）

- 不要凭记忆编 Apple API：先用 MCP `cupertino` 搜索/阅读 Apple Developer Documentation 或 sample code，确认**精确签名**与平台可用性再写代码。
- 当文档与编译器提示冲突，以编译器为最终裁判；提交前必须能本地编译通过。

### Markdown / 富文本渲染原则

- 先读 `doc/current/markdown-chatgpt-wacz-style-contract.md`；它是 ChatGPT 风格 Markdown、GFM、代码、表格、KaTeX、字体、间距、响应式和 Unicode/RTL 行为的唯一 canonical 契约。归档源码/资源不等于 hydrated final DOM 或 computed style，不得据此虚构像素级、暗色或字体结论。
- 只维护 `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder` 一条 Markdown 到 standalone HTML 的运行时链路。预览和 PNG 导出共享同一 parse result、HTML、基础 CSS 与本地资源；禁止 renderer selector、feature flag、shadow renderer、markdown-it fallback 和第二套 export parser。
- 单 `~`、单 `$`、raw HTML、代码语法岛、table pipe、脚注 ID、WebView render ID 等语义必须遵守 canonical 契约；不要用 CSS 或启发式修复改变 parser 含义。
- 40rem/48rem thread width 由 `816 / scale` 的逻辑视口决定。代码、公式、表格只做局部 overflow，不能扩宽 popover；公式宿主禁止使用会让离屏 PNG 漏绘的 `content-visibility:auto`。
- 正文字体使用可靠的 macOS 系统 sans/mono 栈，公式使用项目内 KaTeX 字体；归档里存在字体文件不等于正文实际使用它。
- 渲染改动必须同步更新 Node 契约测试、`ScopyTests/ChatGPTMarkdownRendererTests.swift` 和真实导出 fixture，并完成 Node build/test、应用构建、单测、严格并发测试和真实 PNG 视觉检查。测试宿主没有进入 Scopy 场景时只能记录 environment-blocked。

### 验证闭环（按风险）

- 纯文档或元数据修改只跑相关校验，不强制构建应用。
- 功能代码修改默认跑 `make build` + `make test-unit`；局部、低风险修改可先跑定向测试，交付时说明未跑的门禁及原因。
- 并发/actor/线程相关：额外跑 `make test-strict`；需要时跑 `make test-tsan`
- 性能改动（搜索/清理/滚动）：
  - 后端至少跑 `make test-snapshot-perf-release`
  - 前端日常至少跑 `make perf-frontend-profile`（smoke，真实 snapshot DB）
  - 提交前建议跑 `make perf-frontend-profile-standard`；发布前必须跑 `make perf-frontend-profile-full`
  - 最终生成前后端同表：`make perf-unified-table BACKEND_BASELINE=... BACKEND_CURRENT=... FRONTEND_SUMMARY=...`
- 热键相关：自查 `/tmp/scopy_hotkey.log`（按下仅触发一次，且包含 `updateHotKey()`）
- 注意：`make build/test*` 会触发 `make setup`；若缺 `xcodegen` 可能会尝试 `brew install xcodegen`，在无法联网或未授权时先询问。

## 轻量开发工作流

### 默认做法

- 不要求创建 Trellis task、PRD、JSONL context、developer journal，也不要求使用 Trellis 专用 sub-agent/skill。
- 简单、边界明确的任务直接检查、修改、验证并交付。
- 复杂、跨模块或高风险任务先写一个短计划；只有设计需要长期保存、多人评审或分阶段实施时，才在 `doc/proposals/` 新建 proposal。
- sub-agent 只在任务可独立并行且确有收益时按需使用，不作为开发前置条件。
- 开始时先看 `doc/meta/release-current.yml` 提供的 canonical 入口，再按改动范围读取 `doc/current/product-spec.md`、`doc/current/development-guide.md` 或其他相关文档；只有涉及近期 release 状态时才读取 release index 和 changelog。

### 文档收尾

- 普通开发只更新被改动语义直接影响的 canonical 文档，不为流程完整性机械创建 release 文档。
- 准备 release、改变当前发布事实或用户明确要求时，才更新 `doc/meta/release-current.yml`、版本文档、release index 和 CHANGELOG。
- 性能或部署语义变化必须更新 `doc/current/release-runbook.md`，并记录环境与具体数值。
- 版本发布一律用 git tag：发布版本号不得由 commit count 自动生成；tag 作为发布单一事实来源（详见 `AGENTS.md` 与 `doc/current/release-runbook.md`）。

### 版本命名规范

```
v0.x       - 大版本 (新功能模块)
v0.x.x     - 小版本 (功能增强/完善)
v0.x.fix   - 修复版本 (bug fix/hotfix)
```

### 版本文档模板

每个版本文档必须包含:

1. 📌 **一页纸总结** - What + Why + Result
2. 🏗️ **实现路线** - 步骤列表
3. 📂 **核心改动** - 文件列表
4. 🎯 **关键指标** - 测试/性能数值 (必须具体)
5. 📊 **当前状态** - 快速检查
6. 🔮 **遗留与后续** - 下一步工作

### 性能数据要求

doc/current/release-runbook.md 中的性能测试要求必须包含:

- 测试环境 (硬件/系统/日期)
- 具体数值 (不能只写"满足")
- 对应的测试用例名称
- 性能基准必须基于真实数据：每次先将 `~/Library/Application Support/Scopy/clipboard.db` 快照到仓库目录（`make snapshot-perf-db`，并确保不提交）。
- 前端性能必须包含真实场景 scroll/profile 结果（日常 smoke：`make perf-frontend-profile`；发布前 full：`make perf-frontend-profile-full`）。
- 性能结论必须提供前后端统一对比表（`make perf-unified-table` 产物）。

### 性能变化记录 (必须)

当 release 需要单独性能档案时，在 `doc/perf/release-profiles/` 下创建性能对比文档；否则在 metadata 中显式记录 `profile_doc: null`:

1. **文件命名**: `vX.X-profile.md` (如 `v0.11-profile.md`)
2. **必须包含**:
   - 与上一版本的性能对比表格
   - 具体数值变化 (绝对值 + 百分比)
   - 新增/删除的测试用例
   - 性能回归说明 (如有)
3. **对比维度**:
   - 搜索性能 (5k/10k/25k/50k/75k)
   - 清理性能 (内联/外部/大规模)
   - 写入性能 (批量插入/去重)
   - 内存性能 (如有变化)

---

## Release 规范（必须）

- **版本号来源**：仅允许来自 git tag（例如 `v0.43.14`），禁止用 commit count 自动生成版本（历史遗留 tag 例：`v0.18.*` 不再作为发布口径）。
- **构建注入**：本地与 CI 构建需要注入 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（统一入口 `scripts/version.sh`）。
- **CI 行为**：GitHub Actions `Build and Release` 只从 tag 构建并产出 DMG；Cask 更新通过 PR 合入，workflow 不直接 push main。
- **发布检查表（必须过）**：
  - 版本提交：更新 `doc/meta/release-current.yml` + `doc/releases/history/vX.Y.Z.md` + `doc/releases/README.md` + `doc/releases/CHANGELOG.md`（性能/部署变化则同步 `doc/current/release-runbook.md`，含环境与数值）。
  - 校验：`make release-validate`（确保索引里的 **当前版本** 对应的版本文档/CHANGELOG 条目齐全）。
  - 打 tag：`make tag-release`（tag 从 release metadata 读取；要求工作区干净）。
  - 推送：`make push-release`（push main + 当前 tag）。
  - Homebrew 闭环：等待 release 产出 `Scopy-<version>.dmg` + `.sha256`，并确认 `Suehn/homebrew-scopy` 的 `Casks/scopy.rb` 已更新到同版本与 sha；本地用 `brew fetch --cask scopy`/`brew upgrade --cask scopy` 验证可安装可升级。

---

## Project Overview

**Scopy** is a native macOS clipboard manager designed to provide unlimited history, intelligent storage, and high-performance search. The current implementation status and latest version are tracked in `doc/meta/release-current.yml` and `doc/releases/README.md`, while `doc/current/product-spec.md` documents the active requirements baseline.

## Architecture

Scopy follows a **strict front-end/back-end separation** pattern to enable component swappability and independent testing:

### Backend Layer

- **ClipboardService**: Monitors and manages clipboard events
- **StorageService**: Handles data persistence with hierarchical storage (SQLite for small content, external files for large content)
- **SearchService**: Provides multi-mode search (exact, fuzzy, regex) with FTS5 indexing
- Core data model: `ClipboardItem` with fields for content hash, plain text, app source, timestamps, pin status, and storage references
- Deduplication at write time using content hashing

### Frontend Layer

- UI Shell: menubar icon + popup window + settings window
- Native macOS (SwiftUI preferred, AppKit compatibility considered)
- Communicates exclusively through protocol-based interfaces
- Can operate in "mock backend" mode for development

### Key Architectural Patterns

1. **Protocol-First Design**: All communication between UI and backend uses explicit interfaces, enabling testing and future replacement of either layer
2. **Hierarchical Storage**: Small content (<X KB) in SQLite, large content (≥X KB) as external files with metadata in DB
3. **Lazy Loading**: Initial load of 50-100 recent items, pagination of 100 items per page to prevent UI freezing
4. **Deduplication**: Compute content hash on clipboard change, update timestamps/usage count on duplicates rather than creating new entries
5. **Multi-Mode Search**: Exact (FTS/LIKE), Fuzzy (FTS + fuzzy rules), Regex (limited to small subsets)

## Development Commands

### 快速开始

```bash
cd /Users/hh/Documents/code/Scopy

# 构建（推荐，自动注入版本号）
make build

# 运行（可选）
make run

# 运行测试
make test-unit
make test-strict   # Strict concurrency regression
```

### 构建和部署

```bash
make build               # Debug build
make release             # Release build
./deploy.sh              # Debug 版本（会安装到 /Applications，按需使用）
./deploy.sh release      # Release 版本（同上）
./deploy.sh clean        # 清理后重新编译
./deploy.sh --no-launch  # 编译但不自动启动
```

### 测试命令

```bash
# 全部测试
make test

# 单元测试（排除 perf/integration）
make test-unit

# 性能测试
make test-perf
make test-snapshot-perf-release

# 严格并发回归（Swift strict concurrency）
make test-strict

# 前端真实性能采样 + 前后端统一对比
make perf-frontend-profile
make perf-frontend-profile-standard
make perf-frontend-profile-full
make perf-unified-table BACKEND_BASELINE=... BACKEND_CURRENT=... FRONTEND_SUMMARY=...

# 查看测试结果/日志
# - 日志：logs/*.log
# - xcresult：logs/TestResults.xcresult
```

## Key Design Requirements

### Performance Targets (P95 latencies)

- ≤5k items: search latency ≤ 50ms
- 10k-100k items: first 50 results within 100-150ms
- Search debounce: 150-200ms during continuous input

### Data Management

- Support "logically unlimited" history with configurable cleanup strategies:
  - By count (default: 10k items)
  - By time (default: unlimited)
  - By disk usage (default: 200MB for small content, 800MB for large content)

### Search Interface

All search requests follow this structure:

```typescript
interface SearchRequest {
  query: string;
  mode: "exact" | "fuzzy" | "regex";
  appFilter?: string;   // Filter by source app
  typeFilter?: string;  // Filter by content type
  limit: number;
  offset: number;
}
```

Results return paginated responses with hasMore flag for progressive rendering.

## Important Notes for Implementers

1. **This is a specification-driven project**: The detailed requirements in `doc/current/product-spec.md` define the active scope and acceptance criteria
2. **Start with backend**: Implement ClipboardService, StorageService, and SearchService before UI
3. **UI comes last**: The protocol-based architecture allows UI development to happen independently
4. **Performance is first-class**: Quantified SLOs guide implementation choices and should inform testing strategy
5. **Extensibility built-in**: The separation of concerns anticipates future features like daemon mode or distributed access

## Specification Reference

The active requirements baseline is in `doc/current/product-spec.md` with the four core goals:

1. Native beautiful UI + complete backend/frontend decoupling
2. Unlimited history + hierarchical storage + lazy loading
3. Data structures and indexing for deduplication and search
4. High-performance search + progressive result rendering
