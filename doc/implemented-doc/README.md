# Scopy 实现文档索引

本目录包含 Scopy 项目的实现记录和开发文档。

---

## 当前状态

| 项目 | 状态 |
|------|------|
| **当前版本** | v0.11 |
| **测试状态** | 177/177 passed (22 性能测试全部通过) |
| **构建状态** | Debug ✅ |
| **部署位置** | /Applications/Scopy.app |
| **最后更新** | 2025-11-29 |

> 详细变更历史请查看 [CHANGELOG.md](./CHANGELOG.md)

---

## 快速导航

### 📋 版本文档

| 版本 | 日期 | 主要内容 | 状态 |
|------|------|----------|------|
| [Unreleased](../dev-doc/v0.11-frontend-design.md) | 2025-11-28 | v0.12 前端美化设计（草案） | 🚧 |
| [v0.11](./v0.11.md) | 2025-11-29 | 性能/稳定性/测试改进（外部清理 -81%，+16 测试） | ✅ |
| [v0.10.8](./v0.10.8.md) | 2025-11-28 | 性能优化与稳定性改进（7 P1 问题） | ✅ |
| [v0.10.7](./v0.10.7.md) | 2025-11-28 | 并发安全与稳定性修复（9 P0 问题） | ✅ |
| [v0.10.6](./v0.10.6.md) | 2025-11-28 | 设计系统完善（100% 覆盖率） | ✅ |
| [v0.10.5](./v0.10.5.md) | 2025-11-28 | 智能设计系统（ScopySize 统一尺寸） | ✅ |
| [v0.10.4](./v0.10.4.md) | 2025-11-28 | 性能/稳定性深度修复（7 P0 + 4 P1 + 12 测试） | ✅ |
| [v0.10.3](./v0.10.3.md) | 2025-11-28 | 代码审查修复（P0/P1）+ UI 优化 | ✅ |
| [v0.10.1](./v0.10.1.md) | 2025-11-28 | 前后端分离问题修复（5个review问题） | ✅ |
| [v0.9.4](./v0.9.4.md) | 2025-11-29 | 复制兜底、过滤搜索分页、图片哈希修正 | ✅ |
| [v0.9.3](./v0.9.3.md) | 2025-11-28 | 快捷键录制即时生效、按下触发 | ✅ |
| [v0.9.2](./v0.9.2.md) | 2025-11-27 | App图标位置统一、过滤功能修复 | ✅ |
| [v0.9](./v0.9.md) | 2025-11-27 | App过滤按钮、Type过滤按钮、大内容空间清理 | ✅ |
| [v0.8.1](./CHANGELOG.md#v081---2025-11-27) | 2025-11-27 | 缩略图懒加载修复、来源app图标+时间显示 | ✅ |
| [v0.8](./v0.8.md) | 2025-11-27 | 图片缩略图、悬浮预览、多文件显示、滚动条优化 | ✅ |
| [v0.7-fix](./v0.7-fix.md) | 2025-11-27 | 快捷键生效、文件复制修复、性能指标改进 | ✅ |
| [v0.7](./v0.7.md) | 2025-11-27 | UX 精细化、性能监控、删除快捷键 | ✅ |
| [v0.6](./v0.6.md) | 2025-11-27 | UI/UX 改进、设置多页、文件复制修复 | ✅ |
| [v0.5.fix](./CHANGELOG.md#v05fix---2025-11-27) | 2025-11-27 | SearchService 缓存修复、部署优化 | ✅ |
| [v0.5](./v0.5.md) | 2025-11-27 | 测试框架完善、UI 测试基础设施 | ✅ |
| [v0.5-phase1](./v0.5-phase1.md) | 2025-11-27 | 测试流程自动化 | ✅ |
| [v0.4](./v0.4.md) | 2025-11-27 | 设置窗口 | ✅ |
| [v0.3.1](./v0.3.1.md) | 2025-11-27 | 大图片性能优化 | ✅ |
| [v0.3](./v0.3.md) | 2025-11-27 | 前后端联调 | ✅ |
| [v0.2](./v0.2.md) | 2025-11-27 | 后端实现 | ✅ |
| [v0.1](./v0.1.md) | 2025-11-27 | 前端实现 | ✅ |

### 📄 其他文档

- [CHANGELOG.md](./CHANGELOG.md) - 版本变更日志
- [v0.5-summary.md](./v0.5-summary.md) - v0.5 总结
- [v0.5-walkthrough.md](./v0.5-walkthrough.md) - v0.5 快速上手
- [test-hanging-fix.md](./test-hanging-fix.md) - 测试卡住问题修复

---

### 🎯 快速检查表

新启动对话时，参考这个快速检查：

```
项目状态检查:
  ✅ 源代码位置: /Users/ziyi/Documents/code/Scopy/Scopy/
  ✅ 编译命令: make build
  ✅ 运行命令: make run (真实服务: USE_MOCK_SERVICE=0 make run)
  ✅ 测试流程: make test-flow (完整测试流程自动化)
  ✅ 测试命令: make test
  ✅ 已编译: Scopy.app
  ✅ 前后端完全集成 (v0.3)

功能状态:
  ✅ 基础 UI（搜索、列表、导航）
  ✅ 搜索防抖（150ms）
  ✅ 懒加载分页
  ✅ 键盘快捷键
  ✅ 浮动窗口
  ✅ 系统剪贴板监控
  ✅ SQLite 数据持久化
  ✅ FTS5 全文搜索 (已验证)
  ✅ 分级存储（小内容内联，大内容外部）
  ✅ 内容去重 (已验证)
  ✅ 自动清理
  ✅ 全局快捷键 (⇧⌘C)
  ✅ 大图片性能优化 (v0.3.1)
  ✅ 设置窗口 (v0.4 - 已完成)
  ✅ 测试卡住问题修复 (已完成)
  ✅ 测试流程自动化 (v0.5-phase1 - 已完成)
  ✅ 测试执行 45 个测试 1.6s 无卡住 (已验证)
  ⏳ 服务层单元测试 (v0.5-phase2 计划)
  ⏳ UI 测试 (v0.5-phase4 计划)
```

### 📁 文件结构

```
implemented-doc/
├── README.md           ← 你在这里
├── v0.1.md             ← 前端实现文档
├── v0.2.md             ← 后端实现文档
├── v0.3.md             ← 前后端联调文档
├── v0.3.1.md           ← 大图片性能优化
├── v0.4.md             ← 设置窗口
└── v0.5-phase1.md      ← 测试流程自动化 (最新)
```

### 🚀 快速开始

```bash
cd /Users/ziyi/Documents/code/Scopy

# 第一次
make setup

# 构建和运行
make run

# 运行测试
make test

# 性能基准
make benchmark
```

## 版本历史

| 版本 | 日期       | 主要内容                                           |
| ---- | ---------- | -------------------------------------------------- |
| v0.7 | 2025-11-27 | UX 精细化：悬停/滚动分离、删除快捷键、性能监控    |
| v0.6 | 2025-11-27 | UI/UX 改进：鼠标悬停修复、设置多页、文件复制修复  |
| 测试卡住修复 | 2025-11-27 | 测试卡住问题修复：独立 Bundle、AppDelegate 解耦  |
| v0.5-Phase1 | 2025-11-27 | 测试流程自动化：test-flow.sh、health-check、集成  |
| v0.4 | 2025-11-27 | 设置窗口：可配置参数、持久化、快捷键支持          |
| v0.3.1 | 2025-11-27 | 大图片性能优化：轻量指纹算法、主线程优化          |
| v0.3 | 2024-11-27 | 前后端联调：完整集成、全局快捷键                 |
| v0.2 | 2024-11-27 | 后端完整实现：监控、存储、搜索、测试              |
| v0.1 | 2024-11-27 | 初始实现：Mock 后端 + 完整 UI                     |

## 项目架构概览

```
Protocol-First Design:

┌─────────────────────────────────────┐
│  UI Layer (SwiftUI Views)           │
│  - ContentView, HeaderView, etc.    │
└─────────────────────┬───────────────┘
                      │
                      ↓ (via Protocol)
┌─────────────────────────────────────┐
│  ClipboardServiceProtocol           │
│  - fetchRecent(), search(), etc.    │
└─────────────────────┬───────────────┘
                      │
        ┌─────────────┴──────────────┐
        ↓                            ↓
  ┌───────────────┐         ┌─────────────────────┐
  │ MockService   │         │ RealClipboardService│
  │ (开发测试)    │         │  ┌────────────────┐ │
  └───────────────┘         │  │ClipboardMonitor│ │
                            │  ├────────────────┤ │
                            │  │StorageService  │ │
                            │  ├────────────────┤ │
                            │  │SearchService   │ │
                            │  └────────────────┘ │
                            └─────────────────────┘
```

## 核心文件速查

### 协议和服务层

| 文件                                        | 用途            | 行数 |
| ------------------------------------------- | --------------- | ---- |
| `Protocols/ClipboardServiceProtocol.swift`  | 后端接口定义    | ~130 |
| `Services/ClipboardMonitor.swift`           | 剪贴板监控      | ~600 |
| `Services/StorageService.swift`             | SQLite存储      | ~500 |
| `Services/SearchService.swift`              | FTS5搜索        | ~300 |
| `Services/RealClipboardService.swift`       | 服务整合        | ~245 |
| `Services/MockClipboardService.swift`       | 测试数据        | ~200 |
| `Services/PerformanceProfiler.swift`        | 性能分析        | ~250 |
| `Services/HotKeyService.swift`              | 全局快捷键      | ~165 |

### UI层

| 文件                            | 用途          | 行数 |
| ------------------------------- | ------------- | ---- |
| `Observables/AppState.swift`    | 状态管理      | ~312 |
| `Views/ContentView.swift`       | 主 UI         | ~100 |
| `Views/HistoryListView.swift`   | 列表 + 懒加载 | ~160 |
| `Views/HeaderView.swift`        | 搜索框        | ~80  |
| `Views/FooterView.swift`        | 底部栏        | ~130 |
| `Views/SettingsView.swift`      | 设置窗口      | ~247 |
| `FloatingPanel.swift`           | 浮动窗口      | ~100 |

### 测试

| 文件                                   | 用途         | 行数 |
| -------------------------------------- | ------------ | ---- |
| `ScopyTests/StorageServiceTests.swift` | 存储测试     | ~300 |
| `ScopyTests/SearchServiceTests.swift`  | 搜索测试     | ~350 |
| `ScopyTests/ClipboardMonitorTests.swift` | 监控测试   | ~250 |
| `ScopyTests/IntegrationTests.swift`    | 集成测试     | ~300 |
| `ScopyTests/PerformanceTests.swift`    | 性能测试     | ~350 |

## Makefile 命令速查

```bash
# 构建
make setup         # 安装依赖 + 生成项目
make build         # 编译 (Debug)
make release       # 编译 (Release)
make run           # 编译并运行
make quick-build   # 快速编译（跳过项目生成）
make xcode         # 打开 Xcode
make clean         # 清理

# 测试
make test          # 运行所有测试
make test-unit     # 运行单元测试
make test-perf     # 运行性能测试
make test-integration  # 运行集成测试
make coverage      # 生成覆盖率报告
make benchmark     # 完整基准测试

# 测试流程自动化 (v0.5-Phase1 新增)
make test-flow     # 完整流程 (杀进程 → 编译 → 安装 → 启动 → 检查)
make test-flow-quick  # 快速流程 (跳过编译)
make health-check  # 仅运行 6 项健康检查

# 开发
make format        # 格式化代码 (需要swift-format)
make lint          # 检查代码 (需要swiftlint)
make stats         # 显示项目统计
make help          # 显示帮助
```

## 服务切换

默认 Debug 模式使用 Mock 服务，可通过环境变量切换：

```bash
# 使用真实服务
USE_MOCK_SERVICE=0 make run

# 或修改 AppState.swift
private init() {
    // self.service = MockClipboardService()  // 开发
    self.service = RealClipboardService()      // 生产
}
```

## 数据存储位置

```
~/Library/Application Support/Scopy/
├── clipboard.db          # SQLite数据库
├── content/              # 大内容外部存储
│   └── <uuid>.png
└── thumbnails/           # 缩略图缓存
```

## 性能目标 (v0.md)

| 场景 | 目标 | 状态 |
|------|------|------|
| ≤5k 条搜索 | P95 ≤ 50ms | ✅ |
| 10k-100k 条搜索 | P95 ≤ 150ms | ✅ |
| 搜索防抖 | 150-200ms | ✅ |
| 大图片处理 | <10ms | ✅ (v0.3.1) |

## 下一步工作 (v0.5 Phase 2-5 计划)

### Phase 2: 服务层单元测试 (P1)
- HotKeyServiceTests.swift (6 个测试用例)
- PerformanceProfilerTests.swift (9 个测试用例)
- 提升后端覆盖率到 85%+

### Phase 3: 大文件和外部存储测试 (P1)
- StorageServiceTests 扩展 (6 个大文件测试)
- IntegrationTests 扩展 (3 个集成测试)
- 验证 v0.md 分级存储要求

### Phase 4: UI 测试基础设施 (P2)
- ScopyUITests target 配置
- SettingsViewUITests (10+ 个 UI 测试)
- 其他 View 的 UI 测试
- UI 测试覆盖率 > 70%

### Phase 5: 覆盖率监控和 CI/CD (P3)
- check_coverage.py 覆盖率检查脚本
- HTML 覆盖率报告生成
- GitHub Actions CI/CD 配置
- 整体覆盖率 > 75%

### 其他计划
1. **功能增强**: 搜索模式选择、批量操作、应用过滤
2. **可选特性**: iCloud同步、导出、内容预览

## 相关文件

- `doc/dev-doc/v0.md` - 完整设计规范
- `CLAUDE.md` - 开发指南
- `README.md` - 用户文档

---

## 📊 项目进度

```
v0.1-v0.4: 基础功能 ████████████████████ 100%
v0.5-Phase1: 测试流程 ████████░░░░░░░░░░░░░ 20% (✅ 完成)
v0.5-Phase2: 服务层测试 ░░░░░░░░░░░░░░░░░░░░░ 0% (计划)
v0.5-Phase3: 大文件测试 ░░░░░░░░░░░░░░░░░░░░░ 0% (计划)
v0.5-Phase4: UI 测试 ░░░░░░░░░░░░░░░░░░░░░ 0% (计划)
v0.5-Phase5: CI/CD ░░░░░░░░░░░░░░░░░░░░░ 0% (计划)
```

**总体完成度**: ~20% (v0.5 系列中)

---

**最后更新**: 2025-11-28
**维护者**: Claude Code
**最新完成**: v0.10.7 (并发安全与稳定性修复)
