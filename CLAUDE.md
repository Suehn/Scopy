# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## 开发工作流 (必读)

### 每次对话开始时

1. **读取** `doc/implemented-doc/README.md` - 了解当前状态和最新版本
2. **读取** `doc/implemented-doc/CHANGELOG.md` - 了解最近变化
3. **参考** `doc/dev-doc/v0.md` - 设计规范和需求来源

### 每次开发完成后

必须更新以下文档:

1. **创建/更新版本文档** `doc/implemented-doc/vX.X.md`
2. **更新索引** `doc/implemented-doc/README.md`
3. **更新变更日志** `doc/implemented-doc/CHANGELOG.md`
4. **更新部署文档** `DEPLOYMENT.md` (如有性能/部署变化，必须包含具体数值)
5. **版本发布一律用 git tag**：发布版本号不得由 commit count 自动生成；tag 作为发布单一事实来源（详见 `AGENTS.md` 与 `DEPLOYMENT.md`）。

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

DEPLOYMENT.md 中的性能测试必须包含:

- 测试环境 (硬件/系统/日期)
- 具体数值 (不能只写"满足")
- 对应的测试用例名称

### 性能变化记录 (必须)

每次版本迭代后，必须在 `doc/profile/` 目录下创建性能对比文档:

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
  - 版本提交：更新 `doc/implemented-doc/vX.Y.Z.md` + `doc/implemented-doc/README.md` + `doc/implemented-doc/CHANGELOG.md`（性能/部署变化则同步 `DEPLOYMENT.md`，含环境与数值）。
  - 校验：`make release-validate`（确保索引里的 **当前版本** 对应的版本文档/CHANGELOG 条目齐全）。
  - 打 tag：`make tag-release`（tag 从实现文档索引读取；要求工作区干净）。
  - 推送：`make push-release`（push main + 当前 tag）。
  - Homebrew 闭环：等待 release 产出 `Scopy-<version>.dmg` + `.sha256`，并确认 `Suehn/homebrew-scopy` 的 `Casks/scopy.rb` 已更新到同版本与 sha；本地用 `brew fetch --cask scopy`/`brew upgrade --cask scopy` 验证可安装可升级。

---

## Project Overview

**Scopy** is a native macOS clipboard manager designed to provide unlimited history, intelligent storage, and high-performance search. The project is currently in the specification phase with a detailed architecture document (`doc/dev-doc/v0.md`) that serves as the complete Phase 1 requirements.

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
cd /Users/ziyi/Documents/code/Scopy

# 部署应用 (推荐)
./deploy.sh release    # Release 版本
./deploy.sh            # Debug 版本

# 运行测试
xcodegen generate
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests
```

### 构建和部署

```bash
./deploy.sh              # Debug 版本
./deploy.sh release      # Release 版本
./deploy.sh clean        # 清理后重新编译
./deploy.sh --no-launch  # 编译但不自动启动
```

### 测试命令

```bash
# 全部单元测试
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests

# 性能测试
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/PerformanceTests

# 查看测试结果
# 当前: 48/48 tests passed (1 skipped)
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

1. **This is a specification-driven project**: The detailed requirements in `doc/dev-doc/v0.md` define Phase 1 scope and acceptance criteria
2. **Start with backend**: Implement ClipboardService, StorageService, and SearchService before UI
3. **UI comes last**: The protocol-based architecture allows UI development to happen independently
4. **Performance is first-class**: Quantified SLOs guide implementation choices and should inform testing strategy
5. **Extensibility built-in**: The separation of concerns anticipates future features like daemon mode or distributed access

## Specification Reference

The complete Phase 1 specification is in `doc/dev-doc/v0.md` with the four core goals:

1. Native beautiful UI + complete backend/frontend decoupling
2. Unlimited history + hierarchical storage + lazy loading
3. Data structures and indexing for deduplication and search
4. High-performance search + progressive result rendering
