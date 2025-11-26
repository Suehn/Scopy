# Scopy

A native macOS clipboard manager with unlimited history, intelligent storage, and high-performance search.

## Quick Start

### Prerequisites

- macOS 14.0+
- Xcode 15.0+
- Homebrew (for xcodegen)

### Build & Run

```bash
# 方法 1: 使用 Makefile (推荐)
make setup    # 安装 xcodegen 并生成 Xcode 项目
make build    # 构建
make run      # 构建并运行

# 方法 2: 使用 Xcode
make xcode    # 生成并打开 Xcode 项目
# 然后在 Xcode 中按 ⌘R 运行
```

### Development

```bash
# 清理并重新构建
make clean && make build

# 快速构建（跳过项目生成）
make quick-build
```

## Architecture

Scopy 遵循 **前后端彻底解耦** 的设计原则（详见 `doc/dev-doc/v0.md`）：

```
┌─────────────────────────────────────────────────────────┐
│                      UI Shell                           │
│   ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│   │ MenuBar  │  │  Popup   │  │      Settings        │ │
│   │  Icon    │  │  Window  │  │       Window         │ │
│   └──────────┘  └──────────┘  └──────────────────────┘ │
│                        │                                │
│              Protocol Interface                         │
│        ┌───────────────┴───────────────┐               │
└────────│───────────────────────────────│───────────────┘
         ▼                               ▼
┌─────────────────────────────────────────────────────────┐
│                    Backend Services                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│   │  Clipboard   │  │   Storage    │  │    Search    │ │
│   │   Service    │  │   Service    │  │   Service    │ │
│   └──────────────┘  └──────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Key Files

```
Scopy/
├── Protocols/
│   └── ClipboardServiceProtocol.swift  # 后端接口定义
├── Services/
│   └── MockClipboardService.swift      # Mock 后端实现（用于开发）
├── Observables/
│   └── AppState.swift                  # 全局状态管理
├── Views/
│   ├── ContentView.swift               # 主视图
│   ├── HeaderView.swift                # 搜索框
│   ├── HistoryListView.swift           # 历史列表
│   └── FooterView.swift                # 底部状态栏
├── FloatingPanel.swift                 # 浮动窗口
├── AppDelegate.swift                   # 应用委托
└── ScopyApp.swift                      # 应用入口
```

## Protocol-Based Backend

后端接口完全通过协议定义，UI 只依赖协议不依赖具体实现：

```swift
protocol ClipboardServiceProtocol {
    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO]
    func search(query: SearchRequest) async throws -> SearchResultPage
    func pin(itemID: UUID) async throws
    func unpin(itemID: UUID) async throws
    func delete(itemID: UUID) async throws
    // ...
}
```

### Search Request Format

```swift
struct SearchRequest {
    let query: String
    let mode: SearchMode  // .exact, .fuzzy, .regex
    let appFilter: String?
    let typeFilter: ClipboardItemType?
    let limit: Int
    let offset: Int
}
```

## Demo / 交互示例

运行后：

1. **菜单栏图标**: 点击剪贴板图标打开/关闭弹出窗口
2. **搜索**: 输入文字自动搜索（150ms 防抖）
3. **键盘导航**:
   - `↑/↓` 上下选择
   - `Enter` 复制并关闭
   - `Esc` 清空搜索或关闭窗口
4. **右键菜单**: Copy / Pin / Delete
5. **底部操作**: Clear / Settings / Quit

## Testing

当前使用 `MockClipboardService` 提供测试数据，可以：

1. 验证 UI 在后端 mock 模式下正常运行
2. 测试搜索、分页、Pin/Unpin 等功能
3. 后续实现真实后端时只需替换 Service 实现

## Performance Goals (from v0.md)

- ≤5k items: P95 search latency ≤ 50ms
- 10k-100k items: first 50 results within P95 ≤ 100-150ms
- Search debounce: 150-200ms during continuous input

## Next Steps

1. 实现真实的 `ClipboardService`（监控系统剪贴板）
2. 实现 `StorageService`（SQLite + FTS5）
3. 实现 `SearchService`（多模式搜索）
4. 添加设置窗口
5. 添加快捷键支持

## License

MIT
