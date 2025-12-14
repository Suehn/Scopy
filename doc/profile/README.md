# 性能对比记录

本目录存放每个版本相对于上一版本的性能变化记录。

## 文件列表

| 版本 | 日期 | 主要变化 |
|------|------|----------|
| [v0.43.10-profile.md](./v0.43.10-profile.md) | 2025-12-14 | Dev/Quality：测试隔离 + 性能用例更贴近实际（fuzzyPlus/cold/service path） |
| [v0.43.9-profile.md](./v0.43.9-profile.md) | 2025-12-14 | Perf/Quality：后台 I/O + ClipboardMonitor 语义修复（避免主线程阻塞） |
| [v0.43.8-profile.md](./v0.43.8-profile.md) | 2025-12-14 | Fix/UX：悬浮预览首帧不正确 + 不刷新（图片/文本） |
| [v0.43.7-profile.md](./v0.43.7-profile.md) | 2025-12-14 | Fix/UX：浏览器输入框粘贴空内容（RTF/HTML plain text fallback） |
| [v0.43.6-profile.md](./v0.43.6-profile.md) | 2025-12-14 | Perf/UX：hover 图片预览更及时（预取 + ThumbnailCache 优先级） |
| [v0.43.5-profile.md](./v0.43.5-profile.md) | 2025-12-14 | Perf/UX：图片预览提速（缩略图占位 + JPEG downsample） |
| [v0.43.4-profile.md](./v0.43.4-profile.md) | 2025-12-14 | Fix/UX：测试隔离外部原图 + 缩略图即时刷新 |
| [v0.43.3-profile.md](./v0.43.3-profile.md) | 2025-12-14 | Fix/Perf：短词搜索全量校准恢复 + 高速滚动进一步降载 |
| [v0.43.2-profile.md](./v0.43.2-profile.md) | 2025-12-14 | Perf/UX：Low Power Mode 滚动优化 + 搜索取消更及时 |
| [v0.43.1-profile.md](./v0.43.1-profile.md) | 2025-12-14 | Fix/Quality：热键应用一致性 + 去重事件语义 + 测试稳定性（含 Low Power Mode 备注） | 
| [v0.43-profile.md](./v0.43-profile.md) | 2025-12-13 | Phase 7：ScopyKit module 强制边界（后端从 App target 移出） | 
| [v0.42-profile.md](./v0.42-profile.md) | 2025-12-13 | Phase 7：ScopyKit SwiftPM 接入准备（性能基线记录） | 
| [v0.41-profile.md](./v0.41-profile.md) | 2025-12-13 | Makefile 固化 Strict Concurrency 回归门槛（性能基线记录） | 
| [v0.40-profile.md](./v0.40-profile.md) | 2025-12-13 | AppState 拆分（History/Settings ViewModel）+ Disk 25k 用例采样稳定性 | 
| [v0.39-profile.md](./v0.39-profile.md) | 2025-12-13 | Strict Concurrency 回归 + perf 10k 采样稳定性 | 
| [v0.38-profile.md](./v0.38-profile.md) | 2025-12-13 | DTO 去 UI 派生字段 + 展示缓存入口（基线记录） |
| [v0.37-profile.md](./v0.37-profile.md) | 2025-12-13 | P0-6 ingest 背压：spool + 有界并发队列（基线记录） |
| [v0.36.1-profile.md](./v0.36.1-profile.md) | 2025-12-13 | TSan（Hosted tests）回归方案；性能基线沿用 v0.36 |
| [v0.36-profile.md](./v0.36-profile.md) | 2025-12-13 | Phase 6：日志统一 + AsyncStream buffering + 阈值集中（基线记录） |
| [v0.35.1-profile.md](./v0.35.1-profile.md) | 2025-12-13 | 文档对齐版本；性能基线沿用 v0.35（无代码改动） |
| [v0.35-profile.md](./v0.35-profile.md) | 2025-12-13 | UI 拆分（HistoryListView components），基线记录 |
| [v0.34-profile.md](./v0.34-profile.md) | 2025-12-13 | 缓存入口收口 + perf 用例 warmup 稳定性 |
| [v0.33-profile.md](./v0.33-profile.md) | 2025-12-13 | Application 门面 + 事件语义，基线记录 |
| [v0.32-profile.md](./v0.32-profile.md) | 2025-12-13 | Search actor + 只读连接分离，基线记录 |
| [v0.29.1-profile.md](./v0.29.1-profile.md) | 2025-12-12 | fuzzyPlus 英文多词准确性修复，无性能回归 |
| [v0.29-profile.md](./v0.29-profile.md) | 2025-12-12 | 渐进搜索校准 + 内存/存储/渲染性能收敛，小幅提速 |
| [v0.11-profile.md](./v0.11-profile.md) | 2025-11-29 | 外部清理 -81%，+16 测试 |

## 文档规范

每个性能对比文档必须包含：

1. **对比版本**: 明确标注 `vX.X → vY.Y`
2. **测试环境**: 硬件/系统/日期
3. **性能对比表格**:
   - 搜索性能 (5k/10k/25k/50k/75k)
   - 清理性能 (内联/外部/大规模)
   - 写入性能 (批量插入/去重)
   - 读取性能 (首屏/批量读取)
4. **测试用例变化**: 新增/删除的测试
5. **性能回归说明**: 如有回归，说明原因和是否需要修复
6. **总结**: 亮点、需关注项、SLO 达标情况

## 命名规范

```
vX.X-profile.md
```

例如：`v0.11-profile.md`, `v0.12-profile.md`

---

**维护者**: Claude Code
