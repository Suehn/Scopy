# 性能基线记录（2026-01-27）

> 说明：这是一次“非版本发布”的性能基线快照，用于后续回归对比与瓶颈定位。  
> 更完整的审计与分析见：`doc/reviews/perf-audit-2026-01-27.md`。

## 环境

- macOS: 26.3 (25D5101c)
- Xcode: 26.2 (17C52)
- Swift toolchain: Apple Swift 6.2.3（语言模式仍为 Swift 5）
- 机器：Apple M3 / 24GB RAM

## 数据集

- `perf-db/clipboard.db`：6421 items；148.6MB

## 关键指标（摘要）

### ScopyBench（release，SearchEngine 直测，warmup=20 / iters=30）

| query | mode | forceFullFuzzy | P95 (ms) |
|------|------|----------------|----------|
| `cm` | fuzzyPlus | false | 9.81 |
| `数学` | fuzzyPlus | false | 15.02 |
| `cmd` | fuzzyPlus | false | 0.21 |
| `cm` | fuzzyPlus | true | 9.96 |

数据：`logs/perf-audit-*/scopybench*.jsonl`

### ScopyBench（release，ClipboardService 端到端）

- `cm`（fuzzyPlus）：P95 **~9.7ms**（返回 50 条结果仅 text/rtf/html；thumbnailHits=0）

### PerformanceTests（`make test-perf`）

- 5k（fuzzyPlus）：P95 4.85ms；cold 83.83ms
- 10k（fuzzyPlus）：P95 25.06ms；cold 193.78ms
- Disk 25k（fuzzyPlus）：P95 53.34ms；cold 816.66ms
- Service Disk 10k（fuzzyPlus）：P95 22.34ms；cold 299.39ms

### SnapshotPerformanceTests（`make test-snapshot-perf`，Xcode Debug，ClipboardService 端到端）

- fetchRecent 50：P95 ~1–2ms
- search `cmd`：P95 ~0.3ms
- search `cm`：P95 ~100ms（Debug 下主要是 SearchEngineImpl 本体慢；不建议与 Release bench 直接对比）

## 复现命令

```bash
make test-perf
make test-snapshot-perf
bash scripts/perf-audit.sh --skip-tests --bench-metrics
```
