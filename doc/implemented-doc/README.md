# Scopy 实现文档索引

本目录包含 Scopy 项目的实现记录和开发文档。

---

## 当前状态

| 项目 | 状态 |
|------|------|
| **当前版本** | v0.44.fix10 |
| **测试状态** | 单元测试通过（`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`: Executed 229 tests, 7 skipped） |
| **构建状态** | Debug ✅ |
| **部署位置** | /Applications/Scopy.app |
| **最后更新** | 2025-12-16 |

> 详细变更历史请查看 [CHANGELOG.md](./CHANGELOG.md)

---

## 快速导航

### 📋 版本文档

| 版本 | 日期 | 主要内容 | 状态 |
|------|------|----------|------|
| [v0.44.fix10](./v0.44.fix10.md) | 2025-12-16 | UX/Preview：消除 Markdown/LaTeX 不必要横向滚动条 + 滚动条“仅滚动时显示”更可靠 | ✅ |
| [v0.44.fix9](./v0.44.fix9.md) | 2025-12-16 | UX/Preview：hover Markdown/LaTeX 预览更宽（更少横向滚动）+ 滚动条仅滚动时显示 | ✅ |
| [v0.44.fix8](./v0.44.fix8.md) | 2025-12-16 | Perf/Search：FTS 写放大修复（plain_text-only trigger）+ statement cache + cleanup/pin 一致性 + fuzzy 深分页稳定 | ✅ |
| [v0.44.fix6](./v0.44.fix6.md) | 2025-12-16 | Fix/Preview：避免括号内 `[...]` 被二次包裹（防嵌套 `$`/KaTeX parse error） | ✅ |
| [v0.44.fix5](./v0.44.fix5.md) | 2025-12-16 | Perf/Search：FTS query 构造更鲁棒（多词 AND + 特殊字符不崩）+ mmap 读优化 | ✅ |
| [v0.44.fix4](./v0.44.fix4.md) | 2025-12-16 | Fix/Preview：LaTeX `tabular`/`center`/`rule` 更可读（转 Markdown 表格/分割线） | ✅ |
| [v0.44.fix3](./v0.44.fix3.md) | 2025-12-16 | Fix/Preview：Markdown/公式懒加载渐变更自然 + 高度更新更稳定（减少闪烁） | ✅ |
| [v0.44.fix2](./v0.44.fix2.md) | 2025-12-16 | Fix/Preview：减少 `$` 误判（货币/变量）+ 预览尺寸上报/归一化轻量提速 | ✅ |
| [v0.44.fix](./v0.44.fix.md) | 2025-12-16 | Fix/Preview：hover 预览动态宽高更准确（Markdown/Text） | ✅ |
| [v0.44](./v0.44.md) | 2025-12-16 | Release：Preview 稳健性 + 自动发布（Homebrew 对齐） | ✅ |
| [v0.43.35](./v0.43.35.md) | 2025-12-16 | Preview：移除最小宽高限制，完全动态贴合 | ✅ |
| [v0.43.34](./v0.43.34.md) | 2025-12-16 | Preview：单行短文本/矮图预览更贴合（宽度可收缩 + 最小高度收敛） | ✅ |
| [v0.43.33](./v0.43.33.md) | 2025-12-16 | Preview：动态高度更准确更稳定（Retina 不再低估 + 监听内容变化） | ✅ |
| [v0.43.32](./v0.43.32.md) | 2025-12-16 | Preview：括号内下标/上标公式更鲁棒（`(T_{io}=...)` 等） | ✅ |
| [v0.43.31](./v0.43.31.md) | 2025-12-16 | Preview：LaTeX/Markdown 预览稳健性与依赖收敛（code-skip + 移除 Down） | ✅ |
| [v0.43.30](./v0.43.30.md) | 2025-12-16 | UX/Preview：表格显示优化（横向滚动 + 适度换行）+ 预览高度贴合 HTML 内容 | ✅ |
| [v0.43.28](./v0.43.28.md) | 2025-12-16 | UX/Preview：常见 LaTeX 文档结构（itemize/enumerate/quote/paragraph/label）转 Markdown | ✅ |
| [v0.43.27](./v0.43.27.md) | 2025-12-16 | Refactor/Preview：预览渲染实现收敛（环境 SSOT + 轻量工具复用）+ KaTeX 语法回归测试 | ✅ |
| [v0.43.26](./v0.43.26.md) | 2025-12-16 | Fix/Preview：`\\left...\\right` 公式更鲁棒（避免被拆碎/误包裹） | ✅ |
| [v0.43.25](./v0.43.25.md) | 2025-12-16 | Fix/Preview：论文式 LaTeX 段落渲染修复（避免环境内注入 `$`） | ✅ |
| [v0.43.24](./v0.43.24.md) | 2025-12-16 | Fix/Preview：LaTeX 环境公式渲染更兼容 + 预览脚本注入防护 | ✅ |
| [v0.43.23](./v0.43.23.md) | 2025-12-16 | Fix/Preview：Markdown hover 预览稳定性 + 表格 + 公式兼容性增强 | ✅ |
| [v0.43.22](./v0.43.22.md) | 2025-12-15 | UX/Preview：Markdown 渲染 hover 预览（KaTeX 公式）+ 安全/高性能 | ✅ |
| [v0.43.21](./v0.43.21.md) | 2025-12-15 | Dev/Release：main push 自动打 tag + Homebrew(cask) bump PR + 防覆盖 DMG | ✅ |
| [v0.43.20](./v0.43.20.md) | 2025-12-15 | UX/Perf：Hover 预览可滚动（全文/长图）+ 预览高度按屏幕上限自适应 | ✅ |
| [v0.43.19](./v0.43.19.md) | 2025-12-15 | Fix/Quality：安全/并发/边界收口（外部文件校验 + 事件流背压 + UI 支撑模块） | ✅ |
| [v0.43.18](./v0.43.18.md) | 2025-12-15 | Fix/UI：设置页视觉与排版再打磨（减少空白 + 图标去“全蓝” + About 对齐） | ✅ |
| [v0.43.17](./v0.43.17.md) | 2025-12-15 | Fix/UX：设置窗口更像 macOS 设置（不再误退出 + 热键失败回退 + 侧边栏搜索） | ✅ |
| [v0.43.16](./v0.43.16.md) | 2025-12-15 | Fix/UX：重做设置界面（布局清晰 + 对齐 + 图标统一） | ✅ |
| [v0.43.15](./v0.43.15.md) | 2025-12-15 | Dev/Release：版本统一由 git tag 驱动（停止 commit-count 自动版本） | ✅ |
| [v0.43.14](./v0.43.14.md) | 2025-12-15 | Fix/UX：字数统计按“词/字”单位（中英文混排更准确） | ✅ |
| [v0.43.13](./v0.43.13.md) | 2025-12-15 | Fix/UX：图片 hover 预览弹窗贴合图片尺寸 | ✅ |
| [v0.43.12](./v0.43.12.md) | 2025-12-15 | Fix/UX：搜索结果按时间排序（Pinned 优先）+ 大结果集性能不回退 | ✅ |
| [v0.43.11](./v0.43.11.md) | 2025-12-14 | Fix/Perf：Hover 预览首帧稳定 + 浏览器粘贴兜底（HTML 非 UTF-8） | ✅ |
| [v0.43.10](./v0.43.10.md) | 2025-12-14 | Dev/Quality：测试隔离 + 性能用例更贴近实际（fuzzyPlus/cold/service path） | ✅ |
| [v0.43.9](./v0.43.9.md) | 2025-12-14 | Perf/Quality：后台 I/O + ClipboardMonitor 语义修复（避免主线程阻塞） | ✅ |
| [v0.43.8](./v0.43.8.md) | 2025-12-14 | Fix/UX：悬浮预览首帧不正确 + 不刷新（图片/文本） | ✅ |
| [v0.43.7](./v0.43.7.md) | 2025-12-14 | Fix/UX：浏览器输入框粘贴空内容（RTF/HTML 缺少 plain text） | ✅ |
| [v0.43.6](./v0.43.6.md) | 2025-12-14 | Perf/UX：hover 图片预览更及时（预取 + ThumbnailCache 优先级） | ✅ |
| [v0.43.5](./v0.43.5.md) | 2025-12-14 | Perf/UX：图片预览提速（缩略图占位 + JPEG downsample） | ✅ |
| [v0.43.4](./v0.43.4.md) | 2025-12-14 | Fix/UX：测试隔离外部原图 + 缩略图即时刷新 | ✅ |
| [v0.43.3](./v0.43.3.md) | 2025-12-14 | Fix/Perf：短词搜索全量校准恢复 + 高速滚动进一步降载 | ✅ |
| [v0.43.2](./v0.43.2.md) | 2025-12-14 | Perf/UX：Low Power Mode 滚动优化 + 搜索取消更及时 | ✅ |
| [v0.43.1](./v0.43.1.md) | 2025-12-14 | Fix/Quality：热键应用一致性 + 去重事件语义 + 测试稳定性 | ✅ |
| [v0.43](./v0.43.md) | 2025-12-13 | Phase 7（完成）：强制 ScopyKit module 边界（后端从 App target 移出） | ✅ |
| [v0.42](./v0.42.md) | 2025-12-13 | Phase 7（准备）：引入本地 Swift Package `ScopyKit`（XcodeGen 接入） | ✅ |
| [v0.41](./v0.41.md) | 2025-12-13 | Dev/Quality：Makefile 固化 Strict Concurrency 回归门槛 | ✅ |
| [v0.40](./v0.40.md) | 2025-12-13 | Presentation：拆分 AppState（History/Settings ViewModel）+ perf 用例稳定性 | ✅ |
| [v0.39](./v0.39.md) | 2025-12-13 | Phase 6 收口：Strict Concurrency 回归（Swift 6）+ perf 用例稳定性 | ✅ |
| [v0.38](./v0.38.md) | 2025-12-13 | Phase 5 收口：DTO 去 UI 派生字段 + 展示缓存统一入口 | ✅ |
| [v0.37](./v0.37.md) | 2025-12-13 | P0-6 ingest 背压：spool + 有界并发队列（减少无声丢历史） | ✅ |
| [v0.36.1](./v0.36.1.md) | 2025-12-13 | Phase 6 回归：Thread Sanitizer（Hosted Tests） | ✅ |
| [v0.36](./v0.36.md) | 2025-12-13 | Phase 6 收尾：日志统一 + AsyncStream buffering + 阈值集中 | ✅ |
| [v0.35.1](./v0.35.1.md) | 2025-12-13 | 文档索引/变更/部署对齐 v0.35 | ✅ |
| [v0.35](./v0.35.md) | 2025-12-13 | HistoryListView 拆分（List/Row/Thumbnail/Preview 分文件） | ✅ |
| [v0.34](./v0.34.md) | 2025-12-13 | 缓存入口收口（IconService/ThumbnailCache）+ perf 用例稳定性 | ✅ |
| [v0.33](./v0.33.md) | 2025-12-13 | ClipboardService actor + 事件语义纯化 | ✅ |
| [v0.32](./v0.32.md) | 2025-12-13 | Search actor + 只读连接分离 + 去 GCD | ✅ |
| [v0.31](./v0.31.md) | 2025-12-13 | Persistence actor + SQLite 边界收口 | ✅ |
| [v0.30](./v0.30.md) | 2025-12-12 | Domain 拆分 + SettingsStore SSOT | ✅ |
| [v0.29.1](./v0.29.1.md) | 2025-12-12 | P0 准确性：fuzzyPlus ASCII 多词去噪 | ✅ |
| [v0.29](./v0.29.md) | 2025-12-12 | P0 渐进搜索全量校准 + P1/P2 性能收敛 | ✅ |
| [v0.28](./v0.28.md) | 2025-12-12 | P0 性能：重载全量模糊搜索提速 + 图片管线后台化 | ✅ |
| [v0.27](./v0.27.md) | 2025-12-12 | P0 准确性/性能：搜索与分页版本一致性修复 | ✅ |
| [v0.26](./v0.26.md) | 2025-12-12 | P0 性能优化：热路径清理节流 + 缩略图异步加载 + 短词全量模糊搜索去噪 | ✅ |
| [v0.25](./v0.25.md) | 2025-12-12 | 全量模糊搜索高性能实现 | ✅ |
| [v0.24](./v0.24.md) | 2025-12-12 | 超深度全仓库代码审查 + Hover 预览闪烁修复 | ✅ |
| [v0.23](./v0.23.md) | 2025-12-11 | 深度代码审查修复 (13个问题，actor替代nonisolated(unsafe)) | ✅ |
| [v0.22.1](./v0.22.1.md) | 2025-12-11 | 代码审查修复 (嵌套锁死锁、deinit竞态、异步缩略图) | ✅ |
| [v0.21](./v0.21.md) | 2025-12-11 | 视图渲染性能优化 (预计算 metadata，ForEach 优化) | ✅ |
| [v0.19.1](./v0.19.1.md) | 2025-12-04 | Fuzzy+ 搜索模式 (分词模糊匹配，默认模式) | ✅ |
| [v0.19](./v0.19.md) | 2025-12-04 | 代码深度审查修复 (11 个问题，内存优化 -99%) | ✅ |
| [v0.18](./CHANGELOG.md#v018---2025-12-03) | 2025-12-03 | 虚拟列表 (List) + 缩略图缓存，内存降 90% | ✅ |
| [v0.17.1](./CHANGELOG.md#v0171---2025-12-03) | 2025-12-03 | 统一锁策略 + P2-5/P2-6 任务等待修复 | ✅ |
| [v0.17](./CHANGELOG.md#v017---2025-12-03) | 2025-12-03 | 稳定性修复 (P0/P1) + 模糊搜索不区分大小写 | ✅ |
| [v0.16.3](./v0.16.3.md) | 2025-12-03 | 快捷键触发时窗口在鼠标位置呼出 | ✅ |
| [v0.16.2](./v0.16.2.md) | 2025-11-29 | Bug 修复（Pin 指示器）+ Pinned 区域可折叠 | ✅ |
| [v0.16.1](./v0.16.1.md) | 2025-11-29 | Bug 修复（过滤器不生效、负数 item count） | ✅ |
| [v0.16](./v0.16.md) | 2025-11-29 | 稳定性 + 后台化 + Pin 排序一致性 | ✅ |
| [v0.15.2](./v0.15.2.md) | 2025-11-29 | Bug 修复（存储统计显示不正确，新增 Thumbnails 统计） | ✅ |
| [v0.15.1](./v0.15.1.md) | 2025-11-29 | Bug 修复（文本预览、图片显示、元数据格式） | ✅ |
| [v0.15](./v0.15.md) | 2025-11-29 | UI 优化 + Bug 修复（孤立文件清理 9.3GB→0，文本预览） | ✅ |
| [v0.14](./v0.14.md) | 2025-11-29 | 深度清理性能优化（内联清理 -48%，事务批量删除） | ✅ |
| [v0.13](./v0.13.md) | 2025-11-29 | 深度性能优化（搜索 -57~74%，LIMIT+1，FTS5 两步查询） | ✅ |
| [v0.12](./v0.12.md) | 2025-11-29 | 稳定性与性能深度优化（P0/P1 修复，外部清理 -49%） | ✅ |
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
├── v0.5-phase1.md      ← 测试流程自动化
├── ...
├── v0.43.1.md          ← Fix/Quality（热键/事件语义/测试稳定性）
├── v0.43.2.md          ← Perf/UX（滚动降载/搜索取消更及时）
├── v0.43.3.md          ← Fix/Perf（短词全量校准 + 高速滚动降载）
├── v0.43.4.md          ← Fix/UX（测试隔离外部原图 + 缩略图即时刷新）
├── v0.43.5.md          ← Perf/UX（图片预览提速：缩略图占位 + JPEG downsample）
├── v0.43.6.md          ← Perf/UX（hover 图片预览更及时：预取 + ThumbnailCache 优先级）
├── v0.43.7.md          ← Fix/UX（浏览器输入框粘贴空内容：RTF/HTML plain text fallback）
├── v0.43.8.md          ← Fix/UX（悬浮预览首帧不正确 + 不刷新：图片/文本）
├── v0.43.9.md          ← Perf/Quality（后台 I/O + ClipboardMonitor 语义修复）
├── v0.43.10.md         ← Dev/Quality（测试隔离 + 性能用例更贴近实际）
└── v0.43.11.md         ← Fix/Perf（Hover 预览首帧稳定 + 浏览器粘贴兜底，最新）
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

**最后更新**: 2025-12-15
**维护者**: Codex CLI
**最新完成**: v0.43.18（设置页视觉与排版再打磨）
