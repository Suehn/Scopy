# Scopy 部署和使用指南

## 本次更新（v0.16）
- 搜索稳定性与 Pin 排序一致性修复；剪贴板流关闭保护。
- 外部存储/缩略图统计、孤儿清理、文件删除后台化，减少主线程阻塞。
- 新增 `(type, last_used_at)` 复合索引；缓存 TTL 延长以降低重复统计。
- 测试结果：`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests` **161/161 通过（1 跳过性能开关）**，性能实测详见 `doc/profile/v0.16-profile.md`。

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

**当前版本**: v0.15.2（Bug 修复）
- 修复存储统计显示不正确问题（External Storage 显示 0 Bytes）
- 新增 Thumbnails 统计显示
- 强制刷新缓存确保统计准确

**上一版本**: v0.15.1（Bug 修复）
- 修复文本预览显示 ProgressView 问题
- 图片有缩略图时去除 "Image" 标题
- 文本元数据显示最后15个字符
- 元数据样式统一（小字体 + 缩进）

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

- 📖 **完整设计**: `doc/implemented-doc/v0.5.md`
- 📖 **快速上手**: `doc/implemented-doc/v0.5-walkthrough.md`
- 📖 **设计规范**: `dev-doc/v0.md`

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
