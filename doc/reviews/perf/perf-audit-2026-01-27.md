# Scopy 全链路性能审计（2026-01-27）

> 目标：对照 `doc/specs/v0.md` 的性能目标，以“可重复 + 定量”为主，审计后端搜索/存储与前端关键链路的真实成本，并补齐可复现的基准工具与报告闭环。  
> 范围：Search/SQLite/索引/缓存（后端）+ DTO/缩略图路径（前后端交界）+（可选）Instruments 采样流程。  
> 原则：所有埋点默认关闭（env gate），不改变任何已有功能语义与稳定性。

## 0. 结论（可执行）

- ✅ 回归基线通过：`make build` / `make test-unit` / `make test-strict` / `make test-snapshot-perf` 全绿（2026-01-28）。
- ✅ 性能目标达标（以 Release bench 为准）：在 `perf-db/clipboard.db`（6421 items / 148.6MB）上：
  - `ScopyBench --layer engine`（release，SearchEngine 直测；warmup=20/iters=30）：
    - `cm` P95 ≈ **9.81ms**
    - `数学` P95 ≈ **15.02ms**
    - `cmd` P95 ≈ **0.21ms**
  - `ScopyBench --layer service`（release，ClipboardService 端到端）：
    - `cm` P95 ≈ **9.73ms**（返回 50 条结果仅 text/rtf/html；thumbnailHits=0）
- ⚠️ 注意：`make test-snapshot-perf` 默认在 Xcode **Debug**（-Onone）下运行，短词 `cm` P95 约 **100ms**（同机同库），主要是 Debug 构建下 SearchEngine 本体慢；不要直接和 Release bench 对比。
- ✅ 工具链补齐：ScopyBench 新增 `--layer` 分层（engine/service）+ JSON 化输出；Makefile 通过 `TEST_RUNNER_*` 正确把 `SCOPY_SNAPSHOT_DB_PATH/SCOPY_SNAPSHOT_STRICT_SLO` 注入 XCTest，避免“以为切库但实际没生效”。

## 1. 测试环境与数据集

### 1.1 环境（来自 `scripts/perf-audit.sh` 的 env 采样）

- macOS: 26.3 (25D5101c)
- Xcode: 26.2 (17C52)
- Swift toolchain: Apple Swift 6.2.3（语言模式仍为 Swift 5）
- 机器：Apple M3 / 24GB RAM

### 1.2 数据集

- repo-local snapshot：`perf-db/clipboard.db`
  - 统计：6421 rows；`db_bytes=148647936`（见 `logs/perf-audit-*/scopybench.jsonl`）

## 2. 关键结果（定量）

### 2.1 SearchEngine 直测（ScopyBench, release）

命令（脚本化）：

```bash
bash scripts/perf-audit.sh --skip-tests --bench-metrics
```

结果摘要（`warmup=20/iters=30`；P95）：

| 场景 | mode/sort | forceFullFuzzy | P95 (ms) | 备注 |
|------|-----------|----------------|----------|------|
| `cm` | fuzzyPlus/relevance | false | 9.81 | 2 字短词 |
| `数学` | fuzzyPlus/relevance | false | 15.02 | 2 字 CJK |
| `cmd` | fuzzyPlus/relevance | false | 0.21 | FTS 预筛命中 |
| `cm` | fuzzyPlus/relevance | true | 9.96 | refine/全量阶段 |

数据来源：
- `logs/perf-audit-*/scopybench.jsonl`
- engine phase/counter sample：`logs/perf-audit-*/scopybench.metrics.jsonl`
- service（ClipboardService 端到端）：`logs/perf-audit-*/scopybench.service.jsonl`

### 2.2 单测级性能矩阵（PerformanceTests）

命令：

```bash
make test-perf
```

关键指标（摘自 `logs/test-perf.log`）：

- 5k items（fuzzyPlus）：P95 **4.85ms**；cold start **83.83ms**
- 10k items（fuzzyPlus）：P95 **25.06ms**；cold start **193.78ms**
- Disk 25k items（fuzzyPlus）：P95 **53.34ms**；cold start **816.66ms**
- Service（Disk 10k，fuzzyPlus）：P95 **22.34ms**；cold start **299.39ms**

### 2.3 端到端（SnapshotPerformanceTests：ClipboardService）

命令：

```bash
make test-snapshot-perf
```

结果（摘自 `logs/test-snapshot-perf.log`）：

- 首屏加载（fetchRecent 50）：P95 **~1–2ms**
- 搜索 `cmd`（fuzzyPlus 50）：P95 **~0.3ms**
- 搜索 `cm`（fuzzyPlus 50）：P95 **~100ms**（Xcode Debug 下）

说明：
- `make test-snapshot-perf` 默认在 Xcode Debug 下跑，因此 `cm` 的 ~100ms 主要来自 SearchEngineImpl 的 Debug (-Onone) 运行成本。
- 为避免混淆，本次补齐了 `ScopyBench --layer engine|service`：在 Release 下 engine/service 的 P95 量级一致（~10ms），更贴近真实用户体验。
- SnapshotPerformanceTests 现会打印 `dbLabel`（如 `clipboard.db` / `clipboard-real.db`），并支持通过 `SCOPY_SNAPSHOT_DB_PATH` 切换 DB（由 Makefile 注入到 XCTest）。

## 3. 发现与建议（前后端交界）

### 3.1 [P1] “端到端慢”的根因：Debug (-Onone) 与 Release 混用导致误判

现象（易误判）：`ScopyBench` 默认用 `swift run -c release`，而 `make test-snapshot-perf` 默认跑 Xcode Debug。两者直接对比，会把“编译配置差异”误当成 service/DTO 开销。

证据（同机同库）：

- Release：`ScopyBench --layer engine` 与 `ScopyBench --layer service` 的 `cm` P95 同量级（~10ms）。
- Debug：`ScopyBench --layer engine` 的 `cm` P95 ~70ms（SwiftPM debug），而 `SnapshotPerformanceTests`（Xcode debug）通常 ~100ms；`--layer service` 也基本同量级（说明 service 层额外开销很小）。

结论：在当前数据集（`cm` 返回 50 条结果均为 text/rtf/html，thumbnailHits=0）下，端到端成本主要由 SearchEngineImpl 在 Debug 下未优化导致；Release 下用户体验是 ~10ms 量级。

建议（保持语义不变）：

- 性能回归优先用 Release 的 `ScopyBench`，并通过 `--layer engine|service` 做“同层对比”，避免混用配置。
- 若要刻意放大 service 层成本并定位（image/file-heavy 场景），可用：
  - `ScopyBench --layer service` vs `--layer engine`（同一 DB/同一 query）
  - `ScopyBench --layer service --no-thumbnails` vs 默认（隔离 thumbnail scheduling/thumbnailPath 影响）

## 4. 可复现流程（推荐）

### 4.1 最小回归闭环

```bash
make build
make test-unit
make test-strict
make test-perf
make test-snapshot-perf

# 可选：指定 snapshot DB（Makefile 会注入到 XCTest）
SCOPY_SNAPSHOT_DB_PATH=perf-db/clipboard-real.db make test-snapshot-perf
```

### 4.2 统一输出与脚本化采样

```bash
bash scripts/perf-audit.sh --skip-tests --bench-metrics
```

### 4.3 可选：更严格的 short-query SLO（仅用于 profiling）

```bash
SCOPY_SNAPSHOT_STRICT_SLO=1 make test-snapshot-perf
```

说明：`make test-snapshot-perf` 默认是 Xcode Debug；strict SLO 更适合用于“同机/同配置”的手动对照或 CI 环境采样，日常开发机（Debug + 背景负载）可能会不稳定。

## 5. 本次改动点索引

- SearchEngine perf + 磁盘缓存：`Scopy/Infrastructure/Search/SearchEngineImpl.swift`（`SearchPerfMetrics` / `PerfContext` / `load*FromDiskCache` / `ShortQueryIndex`）
- ScopyBench（分层 + JSONL）：`Tools/ScopyBench/main.swift`（`--layer` / `--json` / `schema_version`）
- Snapshot perf（DB 路径 + SLO gate）：`ScopyTests/SnapshotPerformanceTests.swift`（`resolveSnapshotDBPath` / `SCOPY_SNAPSHOT_STRICT_SLO`）
- 一键脚本：`scripts/perf-audit.sh`
- Makefile：`Makefile`（`test-snapshot-perf`）
