# Scopy 部署和使用指南

## Release/版本号（v0.43.15 起，必须）

### 版本号来源（Single Source of Truth）

- **发布版本号仅来自 git tag**（例如 `v0.43.14`）。
- 历史遗留的 `v0.18.*`（commit count）不再作为发布口径；后续版本按 `v0.43.x` 继续递增。

### 构建注入（确保 About/版本展示一致）

- `CFBundleShortVersionString = $(MARKETING_VERSION)`
- `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
- 本地/CI 统一通过 `scripts/version.sh` 生成：
  - `MARKETING_VERSION`：取 tag（优先 HEAD tag，其次最近 tag），去掉前缀 `v`
  - `CURRENT_PROJECT_VERSION`：`git rev-list --count HEAD`

### 发布流程（推荐）

1. 合入版本提交（含版本文档、索引、CHANGELOG、profile；如涉及部署/性能，也更新本文件并写明环境与具体数值）。
2. 创建 tag（推荐用脚本，版本来源 `doc/implementation/README.md`）：`make tag-release`
3. 推送（确保 tag 一并推送）：
   - 一次性：`make push-release`
   - 或手动：`git push origin main` + `git push origin vX.Y.Z`
4. GitHub Actions `Build and Release` 从 tag 构建 DMG 并生成 `.sha256`；Cask 更新以 PR 形式提交（不再自动 push main）。

### 自动化（可选）

- 推送到 `main` 且更新了 `doc/implementation/*` 时，GitHub Actions 会从 `doc/implementation/README.md` 读取 **当前版本**，校验版本文档/CHANGELOG 后自动打 tag（等价于 `make tag-release`），并 push tag 触发发布。
- 发布 workflow 会拒绝覆盖同一 tag 的既有 DMG（避免 Homebrew SHA mismatch）；如需修复发布，请 **递增版本并创建新 tag**。
- 如配置了仓库 Secret `HOMEBREW_GITHUB_API_TOKEN`，发布后会自动对 `Homebrew/homebrew-cask` 发起 bump PR（`brew install --cask scopy` 依赖该仓库合并）。

**CI 环境**（GitHub Actions）：
- runner：`macos-15`
- Xcode：`16.0`

## 本次更新（v0.59.fix3）

- **Perf/Search（语义不变）**：
  - 短词（≤2 chars）候选分页使用 top‑K heap（取 `offset+limit+1`），避免 O(k log k) 全量排序带来的抖动。
  - `computeCorpusMetrics` 刷新从“按时间周期刷新”改为“仅 stale/force 刷新”，消除周期性 O(n) 全表聚合抖动。
- **Infra/SQLite（语义不变）**：
  - DB user_version bump 到 `6`：在 `scopy_meta` 增量维护 `item_count/unpinned_count/total_size_bytes`（触发器精确维护），统计读侧从 O(n) 收敛到 O(1)，旧库自动 fallback。
  - 新增索引 `idx_recent_order` / `idx_app_last_used`，降低常见排序/分组查询的常数成本。
- **Perf/UI（语义不变）**：
  - hover Markdown 渲染移出 MainActor；滚动期间缩略图 decode 降优先级，减少主线程竞争。

**性能实测**（本地，release，`perf-db/clipboard.db` 6421 items / 148.6MB；`hw.model=Mac15,12`；macOS 26.3（25D5112c）；Xcode 26.2（17C52）；2026-01-29）：
- ScopyBench（engine，warmup 20 / iters 30；`logs/perf-audit-2026-01-29_03-22-58/scopybench.jsonl`）：
  - fuzzyPlus relevance `cm`：avg 5.17ms，P95 5.58ms
  - fuzzyPlus relevance `数学`：avg 8.73ms，P95 9.15ms
  - fuzzyPlus relevance `cmd`：avg 0.11ms，P95 0.14ms
- PerformanceTests（`make test-perf`）：
  - 5k（fuzzyPlus）：P95 4.81ms；cold 82.11ms
  - 10k（fuzzyPlus）：P95 25.15ms；cold 191.60ms
  - Disk 25k（fuzzyPlus）：P95 52.74ms；cold 795.69ms
  - Service Disk 10k（fuzzyPlus）：P95 22.06ms；cold 287.59ms

**测试结果**（2026-01-29）：
- `make test-unit`：Executed 272 tests, 1 skipped, 0 failures
- `make test-strict`：Executed 272 tests, 1 skipped, 0 failures
- `make test-tsan`：Executed 262 tests, 1 skipped, 0 failures
- `make test-perf`：Executed 25 tests, 7 skipped, 0 failures

## 本次更新（v0.59.fix1）

- **Correctness/Robustness（语义不变）**：
  - fullIndex 磁盘缓存 hardening（v3）：fingerprint（DB/WAL/SHM size+mtime）+ `*.sha256` 旁路校验；并对 postings 做轻量结构校验；任一失败则自动回退 DB 重建（准确性优先）。
  - full-history 兜底：新增 `scopy_meta.mutation_seq`（commit counter，user_version=5）作为 change token；检测到未观测提交（外部写入/漏回调）时丢弃内存索引并回退 SQL 扫描/重建，避免 full-history 不完整。
  - tombstone 衰退兜底：upsert（文本/备注）产生 tombstone 同样纳入 stale 判定，达到阈值触发后台重建，避免 postings 膨胀导致 refine 逐步变慢。
  - deep paging 成本收敛：bounded top-K 缓存，避免大 offset 反复扫描或无界内存增长。
  - close/pending 体验：写盘改为后台任务 + time budget 等待；build 取消/失败也清理 pending 队列。
- **冷启动 refine 对照**（本地，DEBUG，真实 DB `~/Library/Application Support/Scopy/clipboard.db` ≈ 145.9MB；`make test-real-db` 输出；`hw.model=Mac15,12`；macOS 26.3（25D5101c）；Xcode 26.2（17C52）；2026-01-19）：
  - prefilter：~2.06ms
  - prefilter + 后台预热后 refine：~18.09ms
  - 冷启动直接 refine（无预热）：~3105.86ms
  - 冷启动重建 refine（无缓存）：~2274.50ms
  - 磁盘缓存加载 refine：~905.25ms（缓存文件 `clipboard.db.fullindex.v3.plist` ≈ 39.1MB，旁路校验 `*.sha256`）
- **测试结果**：
  - `make test-unit`：Executed 266 tests, 1 skipped, 0 failures（2026-01-19）
  - `make test-strict`：Executed 266 tests, 1 skipped, 0 failures（2026-01-19）
  - `make test-real-db`：Executed 2 tests, 0 failures（2026-01-19）

## 本次更新（v0.59）

- **Perf/Search（冷启动 refine 收敛，语义不变）**：
  - fullIndex 磁盘冷启动缓存（binary plist，best-effort）：下次启动优先加载，fingerprint（DB/WAL size+mtime）不匹配则放弃，保证准确性优先。
  - prefilter 命中时后台预热 fullIndex：避免“第一次 refine”承担 fullIndex 冷构建成本。
  - fullIndex 增量更新：upsert/pin/delete 实时应用；文本变化用 tombstone + append 策略保持 correctness，同时避免 postings 移除的高成本。
  - 热路径收敛：query 预处理、ASCII postings 快路径、statement cache LRU、`json_each` 固定 SQL shape + 保序 fetch 等（保持语义与排序一致）。
- **性能实测**（本地，release，`perf-db/clipboard.db` ≈ 148.6MB；`hw.model=Mac15,12`；macOS 26.3（25D5087f）；Xcode 26.2（17C52）；2026-01-13）：
  - fuzzyPlus relevance query=cm：avg 4.89ms，P95 5.43ms（warmup 20 / iters 30）
  - fuzzyPlus relevance query=数学：avg 9.40ms，P95 11.82ms
  - fuzzyPlus relevance query=cmd：avg 0.10ms，P95 0.11ms
  - fuzzyPlus relevance forceFullFuzzy query=cm：avg 5.15ms，P95 5.42ms
  - fuzzy relevance forceFullFuzzy query=abc：avg 2.36ms，P95 2.51ms
  - fuzzy relevance forceFullFuzzy query=cmd：avg 2.61ms，P95 2.64ms
- **冷启动 refine 对照**（本地，DEBUG，真实 DB `~/Library/Application Support/Scopy/clipboard.db` ≈ 148.6MB；`make test-real-db` 输出；2026-01-13）：
  - prefilter：~1.30ms
  - prefilter + 后台预热后 refine：~16.33ms
  - 冷启动直接 refine（无预热）：~2305.90ms
  - 磁盘缓存加载 refine：~861.03ms（缓存文件 `clipboard.db.fullindex.v2.plist` ≈ 38.8MB）
- **测试结果**：
  - `make test-unit`：Executed 259 tests, 1 skipped, 0 failures（2026-01-13）
  - `make test-strict`：Executed 259 tests, 1 skipped, 0 failures（2026-01-13）
  - `make test-real-db`：Executed 2 tests, 0 failures（2026-01-13）

## 本次更新（v0.58）

- **Perf/Search（6k+ 大文本历史）**：
  - ASCII fuzzy 子序列匹配改为 UTF16 单次扫描，降低全量 fuzzy 扫描延迟与抖动。
  - 渐进式全量校准：长文本语料优先返回 FTS 预筛首屏，并自动触发全量校准（不减少搜索范围），UI 会提示“正在全量校准”。
  - 短词（≤2）全量覆盖：未预热全量索引时用 SQL substring 扫描保障覆盖，索引已存在时优先走内存索引进一步提速。
- **Fix/UX（Pinned）**：搜索状态下如有 pinned 命中，Pinned 区域仍会展示（不再仅空搜索时展示）。
- **Perf/UI（端到端）**：DTO 转换避免对每条结果重复触盘检查缩略图；启动时异步建立 thumbnail cache 文件名索引，缩略图生成后增量更新索引，降低端到端搜索/滚动抖动。
- **真实性能基准（必须）**：每次先将 `~/Library/Application Support/Scopy/clipboard.db` 快照到仓库目录（`make snapshot-perf-db`，并确保不提交），再用 `make bench-snapshot-search` 跑基准。
- **性能实测**（本地，release，`perf-db/clipboard.db` ≈ 143MB；`hw.model=Mac15,12`；macOS 26.2（25C56）；Xcode 16.3（16E140）；2026-01-11）：
  - fuzzyPlus relevance query=cm：avg 41.10ms，P95 42.04ms
  - fuzzyPlus relevance query=cmd：avg 0.09ms，P95 0.12ms
  - fuzzy relevance forceFullFuzzy query=abc：avg 2.40ms，P95 2.50ms
  - fuzzy relevance forceFullFuzzy query=cmd：avg 2.69ms，P95 2.79ms
- **测试结果**：
  - `make test-unit`：Executed 254 tests, 1 skipped, 0 failures（2026-01-11）
  - `make test-strict`：Executed 254 tests, 1 skipped, 0 failures（2026-01-11）

## 本次更新（v0.50.fix18）

- **Fix/Release（pngquant 进包生效）**：修复部分 release 产物中 `Tools/pngquant` 未被打包的问题：构建阶段强制将 `Scopy/Resources/Tools/pngquant` 复制到 `Scopy.app/Contents/Resources/Tools/pngquant` 并设为可执行，同时拷贝 `Scopy/Resources/ThirdParty/pngquant/*`。
- **Fix/PNG（手动优化历史图片）**：历史列表新增“优化图片（pngquant）”按钮，点击后会覆盖 `content/` 原图，同时更新 DB 的 hash/size 并刷新 UI；若压缩后不变小会自动回滚并提示“无变化”。
- **UX**：hover 在优化按钮上不再触发预览，避免误弹预览影响操作。
- **验证环境**（本地）：`hw.model=Mac15,12`；macOS 15.7.3（24G419）；Xcode 16.3（16E140）
- **验证结果**：
  - Release build：`.build/Release/Scopy.app/Contents/Resources/Tools/pngquant --version` → `3.0.3`
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 276 tests, 25 skipped, 0 failures

## 本次更新（v0.50.fix17）

- **Feat/PNG（pngquant）**：Markdown/LaTeX 导出 PNG 默认启用 pngquant 压缩（写入剪贴板前完成压缩），导出进入历史与 `content/` 的会是压缩后的 PNG。
- **可选：历史图片写入前压缩**：新增设置开关（默认关闭），开启后图片写入历史前会压缩并覆盖原始 payload；导出/写入分别提供独立参数（quality/speed/colors）。
- **打包与兼容**：
  - 设计目标为随 App bundle 内置 `Tools/pngquant`（`Scopy/Resources/Tools/pngquant`）；实际“进包”问题在 `v0.50.fix18` 修复。
  - 如用户配置自定义路径，则优先使用；否则可回退探测 brew 常见路径；不可用时 best-effort 跳过，不影响原导出/写入功能链路。
  - 许可信息随包附带：`Scopy/Resources/ThirdParty/pngquant/*`。
- **测试结果**：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 276 tests, 25 skipped, 0 failures

## 本次更新（v0.50.fix13）

- **Fix/Preview**：hover Markdown/LaTeX 预览跨行复用单个 `WKWebView`（`MarkdownPreviewWebViewController` 上移到列表层），避免频繁 create/destroy。
- **Fix/Preview**：popover 全局互斥（同一时刻最多 1 个 hover preview），避免同一个 `WKWebView` 同帧挂到两个 hierarchy。
- **Fix/Preview**：修复 popover close 竞态误取消任务，快速 re-hover 同一行更稳定。
- **指标（本地 Debug，`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140））**：
  - `WKWebView` 实例数：全局共享 1 个（不再每行创建/销毁）
  - hover preview popover：同时最多 1 个
- **测试结果**：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 271 tests, 25 skipped, 0 failures

## 本次更新（v0.50.fix11）

- **Perf/UI（滚动）**：仅在预览开启时才创建 `ScrollWheelDismissMonitor`，避免列表每行常驻 `NSViewRepresentable`。
- **Perf/UI（滚动）**：`relativeTimeText` 在 `HistoryItemView.init` 预初始化，移除 `.onAppear` 首次写入 `@State`，减少行进入视窗时的额外更新回合。
- **Chore**：`trace/` 加入 `.gitignore`。
- **性能实测**（`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140），Debug，UI 自动化单次对比）：
  - baseline-image-accessibility（10k items + 2k thumbnails，accessibility on）
    - v0.50.fix10：frame avg 20.61ms，max 508.33ms，drop_ratio 0.03767（samples=292）
    - v0.50.fix11：frame avg 18.12ms，max 208.33ms，drop_ratio 0.01807（samples=332）
- **测试结果**：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 269 tests, 25 skipped, 0 failures
  - `SCOPY_RUN_PROFILE_UI_TESTS=1 xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryListUITests/testScrollProfileBaseline`：Executed 1 test, 0 failures

## 本次更新（v0.50.fix8）

- **Perf/Profile（滚动）**：新增 ScrollPerformanceProfile，采样 frame time / drop ratio / scroll speed 并输出 JSON。
- **Perf/Profile（分层）**：文本 title/metadata、缩略图解码、hover 预览 decode/Markdown render 计时入桶（profiling 开启时）。
- **Mock 场景矩阵**：Mock 数据量/图片数量/文本长度/缩略图开关可配置，用于基线对比。
- **UX**：hover 预览滚轮触发自动关闭，避免预览遮挡滚动；UI 测试预览点击不关闭面板。
- **Tests**：新增 scroll profile UI 测试入口（默认跳过，需 `SCOPY_RUN_PROFILE_UI_TESTS=1` 或 `/tmp/scopy_run_profile_ui_tests`），覆盖 baseline/text-only/image-heavy。
- **性能实测**（Apple M3 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140），Debug）：
  - baseline-image-accessibility：frame P50 16.67ms，P95 16.67ms，avg 19.01ms，max 341.67ms，drop_ratio 0.01899
  - image-heavy-no-accessibility：frame P50 16.67ms，P95 25.00ms，avg 19.35ms，max 325.00ms，drop_ratio 0.02251
  - text-only：frame P50 16.67ms，P95 25.00ms，avg 19.44ms，max 350.00ms，drop_ratio 0.02265
  - buckets（baseline）：text.title_ms p50 0.0020ms / p95 0.0110ms；text.metadata_ms p50 0.0249ms / p95 0.2110ms；image.thumbnail_decode_ms p50 18.15ms / p95 18.32ms
- **测试结果**：
  - `SCOPY_RUN_PROFILE_UI_TESTS=1 xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryListUITests`：Executed 10 tests, 0 failures

## 本次更新（v0.50.fix7）

- **Perf/UI（滚动）**：DisplayText title/metadata 在后台预热，减少滚动进入新页时的主线程文本扫描。
- **Observables**：HistoryViewModel 在 load/loadMore/search/事件更新触发预热，滚动路径优先命中缓存。
- **Tests**：新增滚动观察 reattach/end-without-start 与 DisplayText 预热性能用例；全量 ScopyTests 通过（性能测试需 `RUN_PERF_TESTS=1`）。
- **性能实测**（`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140）, Debug）：
  - Scroll state update（1000 samples）：min 0.00 μs, max 1.07 μs, mean 0.31 μs, median 0.00 μs, P95 1.07 μs, P99 1.07 μs, std dev 0.46 μs
  - DisplayText metadata access（400 items × 4096 chars）：cold 324.58 ms, cached 204.92 μs
- **测试结果**：
  - `xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 269 tests, 25 skipped, 0 failures（perf tests 跳过：`RUN_PERF_TESTS` 未设置）

## 本次更新（v0.50.fix6）

- **Perf/UI（滚动）**：滚动状态改为 start/end 事件驱动，移除高频 onScroll 轮询，降低滚动 CPU 峰值。
- **Perf/UI（滚动）**：滚动期间关闭行级 hover tracking，预览清理仅在有状态时触发，减少无效事件与状态写入。
- **Perf/UI（滚动）**：相对时间文本缓存 + 行背景/边框仅在悬停或选中时绘制，减少滚动时格式化与绘制开销。
- **Perf/UI（滚动）**：文本 metadata 计算改为单次扫描/低分配；DisplayText 缓存 key 去拼接字符串；非 UI 测试模式移除行级 accessibility identifier/value，降低纯文本高速滚动 CPU。
- **测试**：新增 ScrollPerformanceTests，量化 scroll state 更新成本。
- **性能实测**（`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140）, Debug）：  
  - Scroll state update（1000 samples）：min 0.00 μs, max 1.07 μs, mean 0.18 μs, median 0.00 μs, P95 1.07 μs, P99 1.07 μs, std dev 0.39 μs
- **测试结果**：  
  - `xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/ScrollPerformanceTests/testScrollStatePerformance`：Executed 1 test, 0 failures

## 本次更新（v0.44.fix2）

- **Fix/Preview（误判收敛）**：`MarkdownDetector.containsMath` 不再把“出现两个 `$`”直接判定为数学公式，仅在检测到成对 `$...$`（以及 `$$` / `\\(`/`\\[` / LaTeX 环境 / 已知命令）时启用 math 相关渲染，降低货币/变量/日志等纯文本误走 WebView 的概率。
- **Perf（等价收敛）**：
  - 尺寸上报调度：同一帧内合并多次 `scheduleReportHeight()`（挂起 rAF 次数从“可能多次”收敛为最多 1 次/帧；≈≤60Hz 上限），最终上报尺寸不变。
  - 归一化 fast-path：无 TeX/inline 命令信号时跳过扫描（`MathProtector` / `LaTeXInlineTextNormalizer`），减少 hover 预览非公式文本的 CPU 开销。
- **测试结果**（Apple M3 24GB, macOS 15.7.2（24G325）, Xcode 16.3）：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 218 tests, 7 skipped, 0 failures

## 本次更新（v0.44.fix3）

- **Fix/Preview（体验稳定）**：Markdown/LaTeX 预览改为“渲染 + 尺寸稳定后再打开 popover”，避免懒加载阶段 popover 高度/宽度反复调整造成的闪烁与跳动。
- **实现要点**：
  - 复用同一个 `WKWebView`：先离屏预热加载 HTML，尺寸稳定后将同一实例用于 popover 展示，避免二次加载导致的二次抖动。
  - 尺寸稳定策略：收到 size 上报后等待 90ms 无新上报再视为稳定（可按体验调整）。
- **测试结果**（Apple M3 24GB, macOS 15.7.2（24G325）, Xcode 16.3）：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 218 tests, 7 skipped, 0 failures

## 本次更新（v0.44.fix4）

- **Fix/Preview（LaTeX 文档可读性 + 公式稳定）**：
  - `tabular` 表格（常见符号约定表）归一化为 Markdown pipe table，避免 raw LaTeX 作为纯文本挤成一行。
  - `\\noindent\\rule{\\linewidth}{...}` / `\\rule{\\textwidth}{...}` 归一化为 Markdown `---` 分割线。
  - `\\text{...}` 内部的未转义 `_` 自动转义为 `\\_`（例如 `drop_last` → `drop\\_last`），避免 KaTeX 报错导致整段公式红字。
- **测试结果**（Apple M3 24GB, macOS 15.7.2（24G325）, Xcode 16.3）：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 220 tests, 7 skipped, 0 failures

## 本次更新（v0.44.fix5）

- **Perf/Search（长文/大库更稳）**：
  - FTS query 统一收敛为“多词 AND + 特殊字符转义”，避免 phrase 语义导致的错失匹配与 `MATCH` 解析失败。
  - fuzzy(Plus) 大候选集场景更早使用 FTS 预筛，降低万字长文导致候选集膨胀时的 CPU 峰值。
  - SQLite 读写连接启用 `PRAGMA mmap_size = 268435456`（256MB），提升大库随机读取吞吐。
- **性能实测**（`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140）, Debug）：
  - Disk 25k fuzzyPlus：cold start 710.20ms；P95 47.56ms（Samples: 60）
  - Long-doc exact（40 docs, ~15840 chars）：P95 0.23ms（Samples: 20）
- **测试结果**：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests -skip-testing:ScopyTests/IntegrationTests`：Executed 214 tests, 7 skipped, 0 failures

## 本次更新（v0.44.fix8）

- **Perf/Search（语义等价，稳定性优先）**：
  - FTS 写放大修复：`clipboard_au` trigger 仅在 `plain_text` 变化时触发，避免元数据更新导致 FTS churn（`PRAGMA user_version=2`）。
  - SearchEngineImpl statement cache：复用热路径 prepared statements，降低高频输入时的固定开销。
  - 一致性修复：cleanup 后统一 `search.invalidateCache()`；pin/unpin 同步失效 short-query cache，避免短词搜索短暂不一致。
  - fuzzy 深分页稳定：offset>0 缓存本次 query 的全量有序 matches，后续分页切片返回（排序 comparator 不变）。
- **性能实测**（`hw.model=Mac15,12`, 24GB；macOS 15.7.2（24G325）；Xcode 16.3（16E140）, Debug，`PerformanceTests`）：
  - Disk 25k fuzzyPlus：cold start 720.22ms；P95 46.08ms（Samples: 60）
  - Service-path disk 10k fuzzyPlus：cold start 250.20ms；P95 35.54ms（Samples: 50）
- **测试结果**：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/PerformanceTests`：Executed 24 tests, 6 skipped, 0 failures
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/SearchServiceTests`：Executed 25 tests, 1 skipped, 0 failures

## 本次更新（v0.43.23）

- **Fix/Preview（Markdown hover 预览：稳定性 + 表格 + 公式鲁棒性）**：
  - 检测到 Markdown/公式分隔符时，hover 预览使用 Markdown 渲染展示（首帧仍优先显示纯文本）。
  - 渲染引擎：`WKWebView` 内置 `markdown-it`（禁 raw HTML：`html:false`；`linkify:false`），支持 pipe table 等常见表格语法。
  - 公式：内置 KaTeX auto-render + `mhchem`，支持 `$...$` / `$$...$$` / `\\(...\\)` / `\\[...\\]`；并对 `$...$` 等数学片段做占位符保护，避免被 Markdown emphasis 打碎导致无法识别。
  - 兼容性增强：归一化 `[\n...\n]` display 块为 `$$\n...\n$$`；数学片段内将 `\\command` 归一化为 `\command`（仅对 `\\` 后紧跟字母的场景）。
  - 稳定性：修复渲染器使用 `NSJSONSerialization` 生成 JS 字面量导致的崩溃（`SIGABRT`）。
  - 资源：构建阶段将 `Scopy/Resources/MarkdownPreview` 以目录结构复制进 app bundle，确保 `katex.min.css/js`、`contrib/*` 与 `fonts/*` 可按相对路径加载。
  - 安全：CSP 默认 `default-src 'none'`（仅放行 `file:`/`data:` 本地资源），并通过 `WKWebView` content rule list 阻断 `http/https` 与跳转。
- **构建/测试约束**：
  - App/Test 使用自定义 `CONFIGURATION_BUILD_DIR=.build/...`；为兼容 SwiftPM 资源 bundle（`.bundle`）落在 DerivedData，新增 staging 脚本将其复制到 `.build/<config>`。
  - `make test-strict` 保持 `SWIFT_STRICT_CONCURRENCY=complete`，不再全局开启 warnings-as-errors（SwiftPM 依赖默认 `-suppress-warnings` 与其冲突）。
- **性能实测**（Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Search 5k (fuzzyPlus) cold start ≈ 39.30ms；steady P95 ≈ 5.29ms（Samples: 50）
  - Search 10k (fuzzyPlus) cold start ≈ 116.15ms；steady P95 ≈ 52.23ms（Samples: 50）
  - Service-path disk 10k (fuzzyPlus) cold start ≈ 284.26ms；steady P95 ≈ 42.08ms（Samples: 50）
  - Regex 20k items P95 ≈ 3.09ms
  - Mixed content disk search（single run）≈ 11.30ms
  - Memory（5k inserts）increase ≈ 2.4MB；stability（500 iterations）growth ≈ 0.2MB
- **测试结果**：
  - `make test-unit`（Executed 158 tests, 1 skipped, 0 failures）
  - `make test-perf`（Executed 23 tests, 6 skipped, 0 failures）
  - `make test-strict`（Executed 158 tests, 1 skipped, 0 failures）

## 历史更新（v0.43.12）
- **Fix/UX（搜索结果按时间排序）**：
  - 搜索结果统一按 `isPinned DESC, lastUsedAt DESC` 排序（Pinned 仍稳定置顶）。
  - 大结果集（候选≥20k）使用 time-first FTS prefilter，避免排序变更引入磁盘搜索性能回退。
- **性能实测**（MacBook Air（Mac15,12）24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode disabled）：
  - Search 10k (fuzzyPlus) cold start ≈ 113.67ms；steady P95 ≈ 48.44ms（Samples: 50）
  - Disk 25k (fuzzyPlus) cold start ≈ 712.36ms；steady P95 ≈ 44.92ms（Samples: 60）
  - Service-path disk 10k (fuzzyPlus) cold start ≈ 251.20ms；steady P95 ≈ 39.45ms（Samples: 50）
  - Bulk insert 1000 items ≈ 56.15ms（≈17,809 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.32ms
  - Mixed content disk search（single run）≈ 11.42ms
- **测试结果**：
  - `make test-unit` **143 passed** (1 skipped)
  - `make test-integration` **12 passed**
  - `make test-perf` **17 passed** (6 skipped)
  - `make test-tsan` **143 passed** (1 skipped)
  - `make test-strict` **143 passed** (1 skipped)

## 历史更新（v0.43.11）
- **Fix/Perf（Hover 预览首帧稳定 + 浏览器粘贴兜底）**：
  - hover 预览：popover 固定尺寸；预览模型持有 downsampled `CGImage`，避免首次展示“先小后大/需重悬停”。
  - 图片链路：预览/缩略图优先走 ImageIO（file path 直读 + downsample）；`ThumbnailCache` 解码移出主线程。
  - 粘贴兜底：HTML plain text 提取不再假设 UTF-8；回写剪贴板时对 `.html/.rtf` 的空 `plainText` 从 data 解析生成 `.string`，减少 Chrome/Edge 粘贴空内容。
- **性能实测**（MacBook Air（Mac15,12）24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode disabled）：
  - Search 10k (fuzzyPlus) cold start ≈ 131.58ms；steady P95 ≈ 59.03ms（Samples: 50）
  - Disk 25k (fuzzyPlus) cold start ≈ 739.60ms；steady P95 ≈ 66.36ms（Samples: 60）
  - Service-path disk 10k (fuzzyPlus) cold start ≈ 259.61ms；steady P95 ≈ 49.58ms（Samples: 50）
  - Bulk insert 1000 items ≈ 66.04ms（≈15,141 items/s）
  - Fetch recent (50 items) avg ≈ 0.08ms
  - Regex 20k items P95 ≈ 4.73ms
  - Mixed content disk search（single run）≈ 5.11ms
- **测试结果**：
  - `make test-unit` **142 passed** (1 skipped)
  - `make test-integration` **12 passed**
  - `make test-perf` **17 passed** (6 skipped)
  - `make test-tsan` **142 passed** (1 skipped)
  - `make test-strict` **142 passed** (1 skipped)

## 历史更新（v0.43.9）
- **Perf/Quality（后台 I/O + ClipboardMonitor 语义修复）**：
  - 外部文件读取改为后台 `.mappedIfSafe`：回写剪贴板与图片预览不再主线程同步读盘，降低 hover/click 卡顿。
  - 图片 ingest 的 TIFF→PNG 转码移到后台 ingest task，并确保 `sizeBytes/plainText/hash` 以最终 PNG 为准（避免误判外部存储/清理阈值）。
  - `ClipboardMonitor` stop/start 语义修复：stop 不再永久阻断 stream；session gate 防止 restart 后旧任务误 yield。
  - orphan cleanup 的磁盘遍历移到后台；Application Support 目录解析失败时更保守（测试场景避免误删）。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.41ms
  - Fuzzy 10k items P95 ≈ 76.89ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 108.72ms（Samples: 50）
  - Bulk insert 1000 items ≈ 82.99ms（≈12,050 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.31ms
  - Mixed content disk search（single run）≈ 7.50ms
- **测试结果**：
  - `make test-unit` **57 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **137 passed** (1 skipped)
  - `make test-strict` **165 passed** (7 skipped)

## 历史更新（v0.43.8）
- **Fix/UX（悬浮预览首帧不正确 + 不刷新）**：
  - 图片 hover 预览改为订阅 `ObservableObject` 预览模型：preview 数据就绪后可在同一次 popover 展示中无缝替换，避免“移开再悬停才显示”的体感。
  - 图片预览统一按预览区域 `fit` 渲染：缩略图占位也会放大显示，避免“小缩略图当预览”。
  - 文本 hover 预览：`nil` 期间展示 `ProgressView`，生成后即时刷新，避免首帧误显示 `(Empty)`。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.40ms
  - Fuzzy 10k items P95 ≈ 76.10ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 103.79ms（Samples: 50）
  - Bulk insert 1000 items ≈ 83.63ms（≈11,957 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.26ms
  - Mixed content disk search（single run）≈ 7.47ms
- **测试结果**：
  - `make test-unit` **57 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **137 passed** (1 skipped)
  - `make test-strict` **165 passed** (7 skipped)

## 历史更新（v0.43.7）
- **Fix/UX（浏览器输入框粘贴空内容）**：
  - `.rtf/.html` 回写剪贴板时同时写入 `.string`（plain text）+ 原始格式数据，修复 Chrome/Edge 输入框 `⌘V` 可能粘贴为空的问题。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.30ms
  - Fuzzy 10k items P95 ≈ 76.67ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 103.41ms（Samples: 50）
  - Bulk insert 1000 items ≈ 80.96ms（≈12,352 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.23ms
  - Mixed content disk search（single run）≈ 7.66ms
- **测试结果**：
  - `make test-unit` **57 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **137 passed** (1 skipped)
  - `make test-strict` **165 passed** (7 skipped)

## 历史更新（v0.43.6）
- **Perf/UX（hover 图片预览更及时）**：
  - hover delay 期间预取原图数据并完成 downsample，popover 出现后更容易直接展示预览图，减少“长时间转圈/移开再悬停才显示”的体感。
  - popover 缩略图占位加载使用 `userInitiated` 优先级；`ThumbnailCache.loadImage` 使用 `.mappedIfSafe` 降低读盘拷贝开销。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.23ms
  - Fuzzy 10k items P95 ≈ 77.35ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 110.59ms（Samples: 50）
  - Bulk insert 1000 items ≈ 82.74ms（≈12,086 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.31ms
  - Mixed content disk search（single run）≈ 7.91ms
- **测试结果**：
  - `make test-unit` **55 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **135 passed** (1 skipped)
  - `make test-strict` **163 passed** (7 skipped)

## 历史更新（v0.43.5）
- **Perf/UX（图片 hover 预览提速）**：
  - popover 在延迟到达后先展示缩略图占位（若已缓存），原图准备好后无缝替换，避免长时间转圈。
  - downsample：若像素已小于 `maxPixelSize` 则跳过重编码；无 alpha 用 JPEG（q=0.85）避免 PNG 编码 CPU 开销。
  - 预览 IO + downsample 使用 `userInitiated` 优先级；外部文件读取使用 `.mappedIfSafe`，提升交互优先级与读盘效率。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.26ms
  - Fuzzy 10k items P95 ≈ 75.82ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 99.52ms（Samples: 50）
  - Bulk insert 1000 items ≈ 84.10ms（≈11,891 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.32ms
  - Mixed content disk search（single run）≈ 7.46ms
- **测试结果**：
  - `make test-unit` **55 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **135 passed** (1 skipped)
  - `make test-strict` **163 passed** (7 skipped)

## 历史更新（v0.43.4）
- **Fix/UX（测试隔离 + 缩略图即时刷新）**：
  - 测试隔离外部存储根目录：in-memory / 测试场景下外部内容目录不再落到 `Application Support/Scopy/content`，避免测试触发 orphan 清理时误删真实历史原图。
  - 缩略图即时刷新：缩略图保存后发出 `.thumbnailUpdated` 事件；列表行的 `Equatable` 比较纳入 `thumbnailPath`，确保缩略图路径变化会触发 UI 刷新（无需搜索/重载）。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode disabled）：
  - Fuzzy 5k items P95 ≈ 4.82ms
  - Fuzzy 10k items P95 ≈ 44.61ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 70.83ms（Samples: 50）
  - Bulk insert 1000 items ≈ 51.87ms（≈19,277 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 2.99ms
  - Mixed content disk search（single run）≈ 4.25ms
- **测试结果**：
  - `make test-unit` **55 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **135 passed** (1 skipped)
  - `make test-strict` **163 passed** (7 skipped)

## 历史更新（v0.43.3）
- **Fix/Perf（搜索精度 + 高速滚动）**：
  - 短词（≤2）fuzzy/fuzzyPlus：首屏仍走 recent cache 快速返回，但标记为预筛（`total=-1`），并支持 `forceFullFuzzy=true` 走全量 full-index；UI 将在后台渐进 refine 到全量精确结果。
  - 预筛分页一致性：当 `total=-1` 时，`loadMore()` 会先强制 full-fuzzy 拉取前 N 条再分页，避免“永远停在 cache 子集”的不全量问题。
  - 滚动期进一步降载：滚动期间忽略 hover 事件并清理悬停状态；键盘选中动画在滚动时禁用；缩略图 placeholder 在滚动时不启动 `.task`，降低高速滚动的主线程负担。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 9.09ms
  - Fuzzy 10k items P95 ≈ 81.33ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 108.45ms（Samples: 50）
  - Bulk insert 1000 items ≈ 85.31ms（≈11,721 items/s）
  - Fetch recent (50 items) avg ≈ 0.11ms
  - Regex 20k items P95 ≈ 5.54ms
  - Mixed content disk search（single run）≈ 7.59ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **16 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - `make test-strict` **160 passed** (7 skipped)

## 历史更新（v0.43.2）
- **Perf/UX（交互与功耗场景）**：
  - 滚动期间降载：List live scroll 时暂停缩略图异步加载、禁用 hover 预览/hover 选中并减少动画开销，降低 Low Power Mode 下快速滚动卡顿。
  - 搜索取消更及时：取消/超时时调用 `sqlite3_interrupt` 中断只读查询，减少尾部浪费；短词（≤2）模糊搜索走 recent cache，避免触发全量 fuzzy/refine 重路径。
- **性能实测**（MacBook Air Apple M3 24GB, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`；Low Power Mode enabled）：
  - Fuzzy 5k items P95 ≈ 8.45ms
  - Fuzzy 10k items P95 ≈ 78.50ms（Samples: 50；Low Power Mode 下测试阈值放宽至 300ms）
  - Disk 25k fuzzy P95 ≈ 104.57ms（Samples: 50）
  - Bulk insert 1000 items ≈ 83.76ms（≈11,940 items/s）
  - Fetch recent (50 items) avg ≈ 0.12ms
  - Regex 20k items P95 ≈ 5.20ms
  - Mixed content disk search（single run）≈ 7.31ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - `make test-strict` **166 passed** (7 skipped)

## 历史更新（v0.43）
- **Phase 7（完成）：ScopyKit module 强制边界**：
  - App target 仅保留 App/UI/Presentation；后端（Domain/Application/Infrastructure/Services/Utilities）由本地 SwiftPM 模块 `ScopyKit` 提供。
  - `ScopyTests`/`ScopyTSanTests` 统一依赖 `ScopyKit`，不再把后端源码直接编进 test bundle。
- **构建/部署（重要）**：
  - 本仓库将构建产物落到 `.build/`（`project.yml` 设置 `BUILD_DIR`/`CONFIGURATION_BUILD_DIR`），但 SwiftPM 产物仍位于 DerivedData。
  - v0.43 补齐 `SWIFT_INCLUDE_PATHS`/`FRAMEWORK_SEARCH_PATHS` 到 DerivedData `Build/Products/*`，确保 App/Test targets 可稳定 `import ScopyKit`。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 7.11ms
  - Fuzzy 10k items P95 ≈ 51.88ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 72.74ms（Samples: 50）
  - Bulk insert 1000 items ≈ 60.26ms（≈16,595 items/s）
  - Fetch recent (50 items) avg ≈ 0.08ms
  - Regex 20k items P95 ≈ 3.87ms
  - Mixed content disk search（single run）≈ 6.10ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - `make test-strict` **166 passed** (7 skipped)

## 历史更新（v0.42）
- **Phase 7（准备）：ScopyKit SwiftPM 接入**：
  - 根目录 `Package.swift` 定义本地 `ScopyKit` library，后续用于把 Domain/Infra/Application 抽成独立 module。
  - `project.yml` 增加本地 `packages` 并让 App target 依赖 `ScopyKit`；构建/测试时会出现 `Resolve Package Graph`。
- **性能/稳定性**：
  - 本版本仅做工程接入，不影响运行时逻辑；性能数据在噪声范围内波动。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.69ms
  - Fuzzy 10k items P95 ≈ 43.60ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 56.61ms（Samples: 50）
  - Bulk insert 1000 items ≈ 51.70ms（≈19,342 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.11ms
  - Mixed content disk search（single run, after warmup）≈ 4.24ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - `make test-strict` **166 passed** (7 skipped)

## 历史更新（v0.41）
- **Dev/Quality：固化 Strict Concurrency 回归门槛**：
  - 新增 `make test-strict`，统一以 `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 跑 `ScopyTests`。
  - 输出写入 `logs/strict-concurrency-test.log`，便于 CI/本地审计与排查。
- **性能/稳定性**：
  - 本版本仅新增回归入口，不影响运行时逻辑；性能数据在噪声范围内波动。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.70ms
  - Fuzzy 10k items P95 ≈ 43.64ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 58.08ms（Samples: 50）
  - Bulk insert 1000 items ≈ 51.84ms（≈19,290 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.04ms
  - Mixed content disk search（single run, after warmup）≈ 4.18ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - `make test-strict` **166 passed** (7 skipped)

## 历史更新（v0.40）
- **Presentation：拆分 AppState（History/Settings ViewModel）**：
  - 新增 `HistoryViewModel` / `SettingsViewModel`，AppState 收敛为“服务启动 + 事件分发 + UI 回调”协调器（保留兼容 API）。
  - 主窗口视图改为依赖 `HistoryViewModel`，设置窗口改为依赖 `SettingsViewModel`；依赖方向更清晰，为后续 Phase 7（Swift Package）做准备。
- **性能/稳定性**：
  - perf 用例稳定性：`testDiskBackedSearchPerformance25k` 采样从 5 → 50（10 rounds × 5 queries），降低一次性系统抖动导致的 P95 误报。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.72ms
  - Fuzzy 10k items P95 ≈ 46.06ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 58.44ms（Samples: 50）
  - Bulk insert 1000 items ≈ 51.57ms（≈19,390 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.11ms
  - Mixed content disk search（single run, after warmup）≈ 4.24ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - Strict Concurrency：`xcodebuild test -only-testing:ScopyTests SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` **166 passed** (7 skipped)

## 历史更新（v0.39）
- **Phase 6 收口：Strict Concurrency 回归（Swift 6）**：
  - 单测 target 以 `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 回归通过（无并发 warnings）。
  - 关键修复：`Sendable` 捕获（tests/UI tests）、`@MainActor` 边界（UI 缓存/显示辅助）、HotKeyService Carbon 回调 hop 到 MainActor。
- **性能/稳定性**：
  - perf 用例稳定性：`testSearchPerformance10kItems` 采样从 5 → 50（10 rounds × 5 queries），降低一次性系统抖动导致的 P95 误报。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.66ms
  - Fuzzy 10k items P95 ≈ 45.63ms（Samples: 50）
  - Disk 25k fuzzy P95 ≈ 55.89ms
  - Bulk insert 1000 items ≈ 54.96ms（≈18,195 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.04ms
  - Mixed content disk search（single run, after warmup）≈ 4.06ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)
  - Strict Concurrency：`xcodebuild test -only-testing:ScopyTests SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` **166 passed** (7 skipped)

## 历史更新（v0.38）
- **Phase 5 收口：Domain vs UI**：
  - `ClipboardItemDTO` 移除 UI-only 派生字段 `cachedTitle/cachedMetadata`，Domain 只保留事实数据。
  - Presentation 新增 `ClipboardItemDisplayText`（`NSCache`）为 `ClipboardItemDTO.title/metadata` 提供计算 + 缓存，保持列表渲染低开销。
  - `HeaderView.AppFilterButton` 移除 View 内静态 LRU 缓存，统一改为 `IconService`（图标/名称缓存入口收口）。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.68ms
  - Fuzzy 10k items P95 ≈ 43.44ms
  - Disk 25k fuzzy P95 ≈ 56.15ms
  - Bulk insert 1000 items ≈ 82.69ms（≈12,094 items/s）
  - Fetch recent (50 items) avg ≈ 0.07ms
  - Regex 20k items P95 ≈ 3.02ms
  - Mixed content disk search（single run, after warmup）≈ 4.25ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)

## 历史更新（v0.37）
- **P0-6 ingest 背压确定性**：
  - `ClipboardMonitor` 大内容处理改为“有界并发 + backlog”，不再在队列满时 cancel oldest task（减少无声丢历史风险）。
  - 大 payload（默认 ≥100KB）会先落盘到 `~/Library/Caches/Scopy/ingest/`，stream 只传 file ref，避免 burst 时内存堆积与 stream drop。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 8.55ms
  - Fuzzy 10k items P95 ≈ 78.40ms
  - Disk 25k fuzzy P95 ≈ 115.68ms
  - Bulk insert 1000 items ≈ 83.97ms（≈11,908 items/s）
  - Regex 20k items P95 ≈ 5.54ms
  - Mixed content disk search（single run, after warmup）≈ 7.37ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)
  - `make test-tsan` **132 passed** (1 skipped)

## 历史更新（v0.36.1）
- **Thread Sanitizer 回归**：新增 Hosted tests 方案与 `make test-tsan`，用于并发回归门槛（不触及性能路径）。
- **性能基线**：沿用 v0.36（见 `doc/profiles/v0.36.1-profile.md`）。

## 历史更新（v0.36）
- **Phase 6 收尾**：`AsyncStream` buffering policy 显式化（monitor/event streams）+ 日志统一到 `os.Logger`（保留热键文件日志）+ 阈值集中配置（`ScopyThresholds`）。
- **性能实测**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 5.23ms
  - Fuzzy 10k items P95 ≈ 44.80ms
  - Disk 25k fuzzy P95 ≈ 56.94ms
  - Bulk insert 1000 items ≈ 54.80ms（≈18,248 items/s）
  - Regex 20k items P95 ≈ 3.08ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - AppState：`xcodebuild test -only-testing:ScopyTests/AppStateTests -only-testing:ScopyTests/AppStateFallbackTests` **46 passed**
  - `make test-perf` **22 passed** (6 skipped)

## 历史更新（v0.35.1）
- **文档对齐**：补齐 v0.30–v0.35 的索引/变更/性能记录入口，避免“代码已迭代但索引停在旧版本”。
- **代码基线**：v0.35（Domain/SettingsStore/Repository/Search/ClipboardService actor 重构 + HistoryListView 组件拆分）。
- **性能基线**（Apple M3, macOS 15.7.2（24G325）, Debug, `make test-perf`；heavy 需 `RUN_HEAVY_PERF_TESTS=1`）：
  - Fuzzy 5k items P95 ≈ 4.69ms
  - Fuzzy 10k items P95 ≈ 44.81ms
  - Disk 25k fuzzy P95 ≈ 55.73ms
  - Bulk insert 1000 items ≈ 54.33ms（≈18,405 items/s）
  - Regex 20k items P95 ≈ 3.03ms
- **测试结果**：
  - `make test-unit` **53 passed** (1 skipped)
  - `make test-perf` **22 passed** (6 skipped)

## 历史更新（v0.29.1）
- **P0 fuzzyPlus 英文多词去噪**：ASCII 长词（≥3）改为连续子串语义，避免 subsequence 弱相关跨路径误召回（用户搜索更“准”）。
- **性能无回归**（Apple Silicon, macOS 14, Debug, `make test-perf`）：
  - Fuzzy 5k items P95 ≈ 4.68ms
  - Fuzzy 10k items P95 ≈ 43.52ms
  - Disk 25k fuzzy P95 ≈ 43.40ms
  - Heavy Disk 50k fuzzy P95 ≈ 82.76ms ✅
  - Ultra Disk 75k fuzzy P95 ≈ 122.24ms ✅
- **测试结果**：
  - `make test-unit` **53/53 passed**（1 perf skipped）
  - `make test-perf` **22/22 passed（含重载）**

## 历史更新（v0.29）
- **P0 渐进式全量模糊搜索校准**：巨大候选集首屏（ASCII 单词、offset=0）对 fuzzy/fuzzyPlus 走 FTS 预筛极速返回，后台 `forceFullFuzzy` 校准为全量 fuzzy/fuzzyPlus，保证最终零漏召回与正确排序。
- **P0 预筛首屏与分页一致性**：若用户在校准前就滚动 `loadMore`，先强制全量 fuzzy 重拉前 N 条再分页，避免弱相关/错序条目提前出现。
- **P1/P2 性能收敛**：
  - 全量模糊索引移除 `plainText` 双份驻留，分页按 id 回表取完整项，降低内存峰值。
  - 大内容外部文件写入后台化，主线程只写 DB 元信息。
  - `NSCache` 替代 icon/thumbnail 手写 LRU，降低锁竞争；`AppState` 低频字段 `@ObservationIgnored` 缩小重绘半径。
  - incremental vacuum 仅在 WAL >128MB 时执行，减少磁盘抖动。
- **性能实测（Apple Silicon, macOS 14, Debug, `make test-perf`）**：
  - Fuzzy 5k items P95 ≈ 4.91ms
  - Fuzzy 10k items P95 ≈ 42.74ms
  - Disk 25k fuzzy P95 ≈ 42.30ms
  - Heavy Disk 50k fuzzy P95 ≈ 81.24ms ✅
  - Ultra Disk 75k fuzzy P95 ≈ 122.17ms ✅
- **测试结果**：
  - `make test-unit` **52/52 passed**（1 perf skipped）
  - `make test-perf` **22/22 passed（含重载）**

## 历史更新（v0.28）
- **P0 全量模糊搜索重载提速**：`SearchService.searchInFullIndex` 使用 postings 有序交集 + top‑K 小堆排序；巨大候选首屏（ASCII 单词、offset=0）自适应 FTS 预筛，后续分页仍走全量 fuzzy 保障覆盖，pinned 额外兜底。
- **P0 图片管线后台化**：缩略图生成改用 ImageIO 后台 downsample/编码；新图缩略图不再同步生成；原图读取与 hover 预览 downsample 后台化，主线程仅做状态更新。
- **性能实测（Apple Silicon, macOS 14, Debug, `make test-perf`）**：
  - Fuzzy 5k items P95 ≈ 5.1ms
  - Fuzzy 10k items P95 ≈ 47ms
  - Disk 25k fuzzy P95 ≈ 43ms
  - Heavy Disk 50k fuzzy P95 ≈ 90.6ms ✅
  - Ultra Disk 75k fuzzy P95 ≈ 124.7ms ✅
- **测试结果**：
  - `make test-unit` **52/52 passed**（1 perf skipped）
  - `make test-perf` **22/22 passed（含重载）**

## 历史更新（v0.27）
- **P0 搜索/分页版本一致性修复**：搜索切换时自动取消旧分页任务，`loadMore` 只对当前搜索版本生效，避免旧结果混入列表。
- **沿用 v0.26 P0 性能改进**：热路径清理节流、缩略图异步加载、短词全量模糊搜索去噪。
- **性能实测（Apple Silicon, macOS 14, Debug, `make test-perf`）**：
  - Fuzzy 5k items P95 ≈ 10–11ms
  - Fuzzy 10k items P95 ≈ 75ms
  - Disk mixed 25k fuzzy 首屏 ≈ 60ms
  - 50k/75k 磁盘极限 fuzzy 仍高于目标（Debug 环境），后续继续优化。
- **测试结果**：
  - `make test-unit` **51/51 passed**（1 perf skipped）
  - `make test-perf` 非 heavy 场景通过

## 🚀 快速开始 (推荐: 使用 deploy.sh)

### 最简单的方式 - 使用自动化脚本

```bash
cd /Users/ziyi/Documents/code/Scopy

# Debug 版本 (开发用)
./deploy.sh

# Release 版本 (生产用)
./deploy.sh release

# 清理后重新编译
./deploy.sh clean

# 编译但不自动启动
./deploy.sh --no-launch
```

**脚本会自动完成**:
1. ✅ 生成 Xcode 项目
2. ✅ 编译应用 (Debug 或 Release)
3. ✅ 构建到 `.build/$CONFIGURATION/Scopy.app`
4. ✅ 关闭已运行的应用
5. ✅ 备份旧版本到 `Scopy_backup.app`
6. ✅ 部署到 `/Applications/Scopy.app`
7. ✅ 询问是否启动应用

### 手动编译和部署

#### 1. 编译应用

```bash
cd /Users/ziyi/Documents/code/Scopy
xcodegen generate
xcodebuild build -scheme Scopy -configuration Release
```

**输出**:
```
✅ BUILD SUCCEEDED
```

编译后应用位置:
```
.build/Release/Scopy.app
```

完整路径:
```
/Users/ziyi/Documents/code/Scopy/.build/Release/Scopy.app
```

#### 2. 部署到应用程序文件夹

```bash
# 关闭运行中的应用
killall Scopy 2>/dev/null || echo "No running instance"

# 备份旧版本
[ -d /Applications/Scopy.app ] && mv /Applications/Scopy.app /Applications/Scopy_backup.app

# 复制新应用
cp -r ".build/Release/Scopy.app" /Applications/
```

#### 3. 启动应用

**方式 1: 终端**
```bash
open /Applications/Scopy.app
```

**方式 2: Finder**
- 打开 /Applications 文件夹
- 双击 Scopy.app

**方式 3: Spotlight**
- 按 Cmd+Space
- 输入 "Scopy"
- 按 Enter

---

## 🧪 运行测试

### 核心单元测试

```bash
xcodegen generate
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests
```

**预期结果**:
- 核心单测（上次全量 2025-11-27）: 80/80 passed, 1 skipped
- 性能测试（2025-11-28，含重载）: 19/19 passed

**分组参考**:
- PerformanceProfilerTests: 6/6 ✅
- PerformanceTests: 19/19 ✅（默认 RUN_HEAVY_PERF_TESTS=1）
- SearchServiceTests: 16/16 ✅ (已修复缓存刷新问题)
- StorageServiceTests: 13/13 ✅

### UI 测试 (21 个)

```bash
xcodebuild test -scheme ScopyUITests -destination 'platform=macOS'
```

**预期结果**:
```
21 tests passed, 0 failures
```

### 性能测试详细

```bash
# 运行性能测试（默认包含重载场景）
RUN_HEAVY_PERF_TESTS=1 xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/PerformanceTests

# 结果示例（2025-11-29 v0.11）
# Executed 22 tests, 0 failures, ~66s
# 关键输出片段：
# 📊 Search Performance (5k items): P95 2.16ms
# 📊 Search Performance (10k items): P95 17.28ms
# 📊 Disk Search Performance (25k items): P95 53.09ms
# 📊 Heavy Disk Search (50k items): P95 124.64ms
# 📊 Ultra Disk Search (75k items): P95 198.42ms
# 📊 Inline Cleanup Performance (10k items): P95 158.64ms
# 📊 External Cleanup Performance (10k items): 514.50ms
# 📊 Large Scale Cleanup Performance (50k items): 407.31ms
# 🧹 External cleanup elapsed: 123.37ms (v0.11 优化后，原 653.84ms)
```

---

## 🏗️ 构建目录结构

### 为什么使用 .build 目录?

之前: Xcode 默认输出到 `~/Library/Developer/Xcode/DerivedData/` (深层次, 难以访问)

现在: 配置 project.yml 让构建输出到项目内的 `.build/` 目录

**优点**:
- ✅ 本地项目内构建，易于访问和清理
- ✅ 支持版本控制忽略 (`.gitignore`)
- ✅ 便于 CI/CD 集成和脚本自动化
- ✅ 清晰的目录结构

**目录结构**:
```
Scopy/
├── .build/
│   ├── Release/
│   │   └── Scopy.app          # Release 构建产物
│   └── Debug/
│       └── Scopy.app          # Debug 构建产物
├── Scopy/                      # 源代码
├── ScopyTests/                 # 单元测试
├── deploy.sh                   # 部署脚本
└── project.yml                 # Xcode 构建配置
```

---

## 📊 性能基准线 (实测数据)

### 测试环境
- **硬件**: MacBook Pro (Apple Silicon)
- **系统**: macOS 14.x+
- **测试日期**: 2025-11-29 (v0.14)
- **测试框架**: XCTest（性能用例 22 个，默认启用重载场景；设置 `RUN_HEAVY_PERF_TESTS=0` 可跳过）

### 搜索性能 (P95)

| 数据量 / 场景 | 目标 | 实测 | 测试用例 | 状态 |
|---------------|------|------|----------|------|
| 5,000 items | < 50ms | **P95 4.37ms** | `testSearchPerformance5kItems` | ✅ |
| 10,000 items | < 150ms | **P95 4.74ms** | `testSearchPerformance10kItems` | ✅ |
| 25,000 items（磁盘/WAL） | < 200ms | **P95 24.47ms** | `testDiskBackedSearchPerformance25k` | ✅ |
| 50,000 items（重载，磁盘） | < 200ms | **P95 53.06ms** | `testHeavyDiskSearchPerformance50k` | ✅ |
| 75,000 items（极限，磁盘） | < 250ms | **P95 83.94ms** | `testUltraDiskSearchPerformance75k` | ✅ |
| Regex 20k items | < 120ms | **P95 3.10ms** | `testRegexPerformance20kItems` | ✅ |

### 首屏与读取性能

| 场景 | 目标 | 实测 | 测试用例 | 状态 |
|------|------|------|----------|------|
| 50 items 加载 | P95 < 100ms | **P95 0.08ms / Avg 0.06ms** | `testFirstScreenLoadPerformance` | ✅ |
| 100 次批量读取 | < 5s | **5.50ms（18,185 次/秒）** | `testConcurrentReadPerformance` | ✅ |
| Fetch recent 100 次（50/批） | < 50ms/次 | **0.06ms/次** | `testFetchRecentPerformance` | ✅ |

### 内存性能

| 场景 | 目标 | 实测 | 测试用例 | 状态 |
|------|------|------|----------|------|
| 5,000 项插入后内存增长 | < 100KB/项 | **+2.1MB（~0.4KB/项）** | `testMemoryEfficiency` | ✅ |
| 500 次操作后内存增长 | < 50MB | **+0.2MB** | `testMemoryStability` | ✅ |

### 写入性能

| 场景 | 目标 | 实测 | 测试用例 | 状态 |
|------|------|------|----------|------|
| 批量插入 (1000 items) | > 500/sec | **23.83ms（~42.0k/sec）** | `testBulkInsertPerformance` | ✅ |
| 去重 (200 upserts) | 正确去重 | **3.78ms** | `testDeduplicationPerformance` | ✅ |
| 清理 (900 items) | 快速完成 | **59.94ms** | `testCleanupPerformance` | ✅ |
| 外部存储清理 (195MB→≤50MB) | < 800ms | **123.37ms** | `testExternalStorageStress` | ✅ |

### 清理性能 (v0.14 更新)

| 场景 | 目标 | 实测 | 测试用例 | 状态 |
|------|------|------|----------|------|
| 内联清理 10k 项 | P95 < 500ms | **P95 312.40ms** | `testInlineCleanupPerformance10k` | ✅ |
| 外部清理 10k 项 | < 1200ms | **1047.07ms** | `testExternalCleanupPerformance10k` | ✅ |
| 大规模清理 50k 项 | < 2000ms | **通过** | `testCleanupPerformance50k` | ✅ |
| 外部存储压力测试 | < 800ms | **510.63ms** | `testExternalStorageStress` | ✅ |

### 搜索模式比较 (3k items)

| 模式 | 实测 | 目标 | 测试用例 |
|------|------|------|----------|
| Exact | 3.24ms | < 100ms | `testSearchModeComparison` |
| Fuzzy | 4.76ms | < 100ms | `testSearchModeComparison` |
| Regex | 0.91ms | < 200ms | `testSearchModeComparison` |

### 其他性能指标

| 指标 | 实测 | 测试用例 |
|------|------|----------|
| 搜索防抖 (8 连续查询) | 9ms 总计（1.07ms/次） | `testSearchDebounceEffect` |
| 短词缓存加速 | 首次 0.90ms，缓存 0.36ms | `testShortQueryPerformance` |

### 磁盘与混合内容场景（近真实 I/O）

| 场景 | 实测 | 细节 | 测试用例 |
|------|------|------|----------|
| 磁盘搜索（25k/WAL） | P95 55.00ms | Application Support + WAL，文本混合 | `testDiskBackedSearchPerformance25k` |
| 混合内容搜索 | 7.70ms | 文本/HTML/RTF/大图(120KB)/文件混合；外存引用 300（测试后已清理） | `testMixedContentIndexingOnDisk` |
| 重载磁盘搜索 | P95 125.94ms (50k) / 195.77ms (75k) | 同步 WAL，真实 I/O | `testHeavyDiskSearchPerformance50k` / `testUltraDiskSearchPerformance75k` |
| 外部存储压力 | 195.6MB -> 清理 653.84ms | 300 张 256KB 图片写入 + 外存清理 | `testExternalStorageStress` |

### 性能测试命令

```bash
# 运行所有性能测试
RUN_HEAVY_PERF_TESTS=1 xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/PerformanceTests

# 预期输出
Executed 19 tests, with 0 failures (0 unexpected) in ~36 seconds
```

---

## 🐛 常见问题

### Q1: 应用启动后立即崩溃
**原因**: 旧版本冲突或权限问题

**解决**:
```bash
# 使用 deploy.sh 自动处理（推荐）
./deploy.sh release

# 或手动操作
rm -rf /Applications/Scopy.app /Applications/Scopy_backup.app
xcodebuild build -scheme Scopy -configuration Release
cp -r ".build/Release/Scopy.app" /Applications/
rm -rf ~/Library/Caches/Scopy
```

### Q2: "找不到 Scopy" 错误
**原因**: 应用未正确签名或权限问题

**解决**:
```bash
# 检查签名
codesign -v /Applications/Scopy.app

# 如果签名失败，重新构建
xcodebuild clean -scheme Scopy
./deploy.sh release
```

### Q3: 性能测试失败
**原因**: 系统负载过高或测试环境问题

**解决**:
```bash
# 关闭其他应用
killall Chrome Safari Mail 2>/dev/null

# 重新运行测试
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/PerformanceTests
```

### Q4: 编译失败 "xcodeproj 不存在"
**原因**: 需要 xcodegen 生成项目文件

**解决**:
```bash
# 安装 xcodegen (如果未安装)
brew install xcodegen

# 重新生成项目
xcodegen generate

# 清理并重新构建
xcodebuild clean -scheme Scopy
xcodebuild build -scheme Scopy -configuration Release
```

---

## 📱 应用功能

### 核心功能

1. **剪贴板监控**
   - 实时监控系统剪贴板
   - 自动保存历史记录
   - 无限历史存储

2. **搜索和查找**
   - 全文搜索 (FTS5 索引)
   - 模糊搜索
   - 正则表达式搜索
   - 应用和类型过滤

3. **剪贴板管理**
   - 固定重要项目
   - 删除不需要的项目
   - 清空历史

4. **性能优化**
   - 分级存储 (SQLite + 外部文件)
   - 智能缓存
   - 防抖搜索 (150-200ms)

### 快捷键

- **Cmd+;** - 打开 Scopy 窗口
- **Cmd+,** - 打开设置
- **↑/↓** - 选择上一个/下一个项目
- **Enter** - 复制选中项目
- **Escape** - 关闭/清除搜索

---

## 🔧 开发者指南

### 项目结构

```
Scopy/
├── Scopy/                      # 主应用代码
│   ├── Services/               # 后端服务
│   │   ├── ClipboardMonitor.swift
│   │   ├── SearchService.swift
│   │   └── StorageService.swift
│   ├── Protocols/              # 接口定义
│   ├── Observables/            # 状态管理
│   └── Views/                  # UI 组件
│
├── ScopyTests/                 # 单元测试
│   ├── AppStateTests.swift     # 状态管理测试 (31)
│   ├── PerformanceTests.swift  # 性能测试 (19，含重载)
│   ├── SearchServiceTests.swift
│   ├── StorageServiceTests.swift
│   └── Helpers/                # 测试基础设施
│       ├── TestDataFactory.swift
│       ├── MockServices.swift
│       ├── PerformanceHelpers.swift
│       └── XCTestExtensions.swift
│
└── ScopyUITests/               # UI 测试 (21)
    ├── MainWindowUITests.swift
    ├── HistoryListUITests.swift
    ├── KeyboardNavigationUITests.swift
    ├── SettingsUITests.swift
    └── ContextMenuUITests.swift
```

### 修改代码后重新编译

```bash
# 快速编译 (Debug)
xcodebuild build -scheme Scopy

# 发布版编译 (Release)
xcodebuild build -scheme Scopy -configuration Release

# 运行并调试
xcodebuild build -scheme Scopy -configuration Debug
open /path/to/DerivedData/Scopy.app
```

### 添加新测试

```swift
// ScopyTests/YourNewTests.swift
@MainActor
final class YourNewTests: XCTestCase {
    var mockService: TestMockClipboardService!

    override func setUp() async throws {
        mockService = TestMockClipboardService()
        mockService.setItemCount(100)
    }

    func testYourFeature() async throws {
        // 测试代码
        XCTAssertEqual(mockService.searchCallCount, 1)
    }
}
```

---

## 📈 版本信息

**当前版本**: v0.28（P0 性能）
- 重载全量模糊搜索提速（50k/75k 磁盘首屏达标）
- 图片缩略图/预览管线后台化

**上一版本**: v0.27（P0 准确性/性能）
- 搜索/分页版本一致性修复
- 热路径清理节流 + 缩略图异步加载 + 短词全量模糊搜索去噪

**更早版本**: v0.15（UI 优化 + Bug 修复）
- 孤立文件清理：9.3GB → 0（删除 81,603 个孤立文件）
- 修复 Show in Finder 按钮不工作问题
- 移除 Footer 中的 Clear All 按钮
- 新增文本悬浮预览功能

**下一版本**: v0.16（规划中）
- 继续 UI 美化
- 性能监控收敛

---

## 📚 相关文档

- 📖 **完整设计**: `doc/implementation/releases/v0.5.md`
- 📖 **快速上手**: `doc/implementation/releases/v0.5-walkthrough.md`
- 📖 **设计规范**: `doc/specs/v0.md`

---

## 🎯 快速检查清单

部署前检查:

- [x] 单元测试 177/177 passed (22 性能测试，2025-11-29)
- [x] FTS5 COUNT 缓存和搜索超时实际应用
- [x] 数据库连接健壮性修复
- [x] 配置构建到本地 `.build` 目录
- [x] 代码编译成功 (`BUILD SUCCEEDED`)
- [x] 应用能够正常部署到 /Applications
- [x] 应用文件结构正确 (Universal Binary: x86_64 + arm64)
- [x] deploy.sh 脚本测试通过

## 📝 更新日志

### 2025-11-27 修复和改进
- ✅ **修复 SearchServiceTests**: 添加缓存空检查，修复 3 个失败的测试
- ✅ **配置构建目录**: project.yml 设置构建到 `.build/$CONFIGURATION/`
- ✅ **更新 deploy.sh**: 自动化构建、部署、备份流程
- ✅ **更新文档**: DEPLOYMENT.md 已同步最新信息

### 测试状态
- 单元测试: 48/48 ✅ (1 skipped)
- 构建: Release ✅ (1.8M universal binary)
- 部署: /Applications/Scopy.app ✅

---

**最后更新**: 2025-11-29
**维护者**: Claude Code
**许可证**: MIT
