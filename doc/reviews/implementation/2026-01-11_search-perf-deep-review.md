# 2026-01-11 — Search 性能/准确性改动深度 Review（v0.58）

## 🎯 目标

- 验证搜索结果仍为“全量匹配”（不减搜索范围），且首屏/全量阶段语义一致。
- 聚焦 2 字短词与 6k+ 大文本历史的延迟问题，排查端到端链路的固定开销。
- 为发布 v0.58 提供风险评估与回归点。

---

## ✅ Review 范围（关键文件）

- 搜索引擎：`Scopy/Infrastructure/Search/SearchEngineImpl.swift`
- 端到端 DTO/缩略图链路：`Scopy/Application/ClipboardService.swift`
- 渐进式搜索状态机：`Scopy/Observables/HistoryViewModel.swift`
- 搜索时 pinned 展示：`Scopy/Views/HistoryListView.swift`
- UI 提示：`Scopy/Views/HeaderView.swift`
- 迁移：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`
- 测试：`ScopyTests/SearchServiceTests.swift`、`ScopyTests/AppStateTests.swift`、`ScopyTests/PerformanceTests.swift`
- 性能工具链：`scripts/snapshot-perf-db.sh`、`Tools/ScopyBench/main.swift`、`Makefile`、`Package.swift`

---

## 🧠 关键结论（正确性）

1. **短词（≤2）保证全量覆盖**  
   - Fuzzy/Fuzzy+ 短词不再走 cache-limited prefilter；未预热全量索引时走 SQL substring 全量扫描，避免“首个全量索引构建秒级卡顿”导致的误判。
   - 若全量内存索引已存在，则优先走索引路径（更快且排序更贴近 score 模型）。

2. **渐进式搜索不会减少最终搜索范围**  
   - 长文本语料下优先返回 FTS 预筛首屏（`isPrefilter=true`），随后自动触发 `forceFullFuzzy=true` 的全量校准；UI 会提示“正在全量校准”（排序/漏项可能更新）。

3. **Pinned 命中在搜索状态可见**  
   - `HistoryListView` 将 pinned/unpinned 从当前 `items` 切分展示，不再依赖 “searchQuery 为空” 才显示 pinned section；因此 pinned 命中不会被 UI 隐藏。

---

## ⚡ 关键结论（性能）

- 搜索引擎热路径对 ASCII 长词的 fuzzy 子序列匹配采用 UTF16 单次扫描，减少 `Character` 遍历在长文本上的额外开销。
- 端到端上，DTO 转换不再对每条结果重复触盘检查缩略图；启动时异步建立 thumbnail cache 文件名索引，并在生成缩略图时增量更新索引。
- 真实性能基准建议固定为：
  - `make snapshot-perf-db`（从真实 `~/Library/Application Support/Scopy/clipboard.db` 快照到仓库目录，文件不提交）
  - `make bench-snapshot-search`（release 级基准）

基准结果（release，`perf-db/clipboard.db` ≈ 143MB；2026-01-11）：
- fuzzyPlus relevance query=cm：P95 42.04ms
- fuzzyPlus relevance query=cmd：P95 0.12ms
- fuzzy relevance forceFullFuzzy query=abc：P95 2.50ms
- fuzzy relevance forceFullFuzzy query=cmd：P95 2.79ms

---

## ⚠️ 风险与建议

1. **Trigram FTS 迁移的可选性与 user_version**  
   - 当前迁移会把 `PRAGMA user_version` 升到 4；若 trigram tokenizer 不可用会跳过 trigram 表创建，但仍会记为已迁移。  
   - 建议后续如需更强的 substring 加速，考虑提供更明确的 feature-detection/重试策略（不作为本次发布阻塞项）。

2. **严格并发模式警告**  
   - `make test-strict` 当前存在历史遗留 warnings（非本次变更引入）；本次发布不以清零 warnings 为目标，但需关注 Swift 6 语言模式升级后可能变成 error 的点。

---

## ✅ 回归检查清单（发布前）

- `make test-unit` / `make test-strict` 通过
- `make bench-snapshot-search` 通过并记录数值
- 手动验证：搜索状态 pinned 命中可见；短词（≤2）不会漏历史；结果排序稳定

