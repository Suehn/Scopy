# 前后端分离深度复审（v0.10）

- 当前实现基线：v0.9.4（doc/implemented-doc/README.md），本次改动标记：v0.10 前后端分离强化。
- 评审范围：协议/服务/AppState/Settings/HistoryList 解耦改动；前后端分离与前端迁移可行性；相关测试/Mock。
- 评审依据：AGENTS.md、CLAUDE.md、doc/dev-doc/v0.md、doc/frontend-separation-review.md（2024-11-28）、现有实现索引。

## 结论摘要
- 进展：协议已补齐生命周期；AppState 不再类型判断；Settings/HotKeyRecorder 通过回调解耦 AppDelegate；HistoryList 移除直接文件访问，整体符合 v0.md 分层目标，迁移前端风险低。
- 关键缺口：降级 Mock 未执行生命周期、Settings 首帧默认化、settingsChanged 兜底热键依赖可空回调并使用旧状态，可能导致事件流中断或热键被错误覆盖。
- 建议优先级：先修复生命周期与热键兜底，再修正 Settings 初始状态，再补测试覆盖。

## 现状对照（doc/dev-doc/v0.md & frontend-separation-review.md）
- 协议边界：ClipboardServiceProtocol 增加 `start()/stop()`，生命周期与数据访问分段清晰（符合 v0.md 1.1/1.3 验收）。
- UI 解耦：HistoryList 取消直接文件读取；Settings/HotKeyRecorder 改为回调；AppState 支持工厂和 Environment 注入（对齐 “UI 在 Mock 模式运行”与 “替换 UI 框架无需改后端”）。
- 一致生命周期：降级路径缺少 start 调用，未满足“后端可被 CLI/单测驱动时生命周期一致”的要求。
- “真实数据优先”体验：Settings 初帧使用默认值，偏离 “UI 先呈现真实状态”。
- 热键兜底：依赖可空回调且不 reload 设置，未完全符合 AGENTS.md “settingsChanged 兜底重应用热键”。

## 主要问题（按严重度）
1) 严重：降级 Mock 未走生命周期  
   - 位置：Scopy/Observables/AppState.swift:122-133  
   - 细节：`service.start()` 失败后直接 `service = MockClipboardService()`，未对新实例调用 `start()`。协议已定义生命周期，降级后事件流/初始化（settings、recentApps、load）仍会调用，但 Mock 若需要 start 初始化（或未来扩展）将被跳过，生命周期不一致。违背 v0.md “后端可被 CLI/测试驱动”与 doc/frontend-separation-review Phase 1 生命周期完整性的要求。
   - 影响：降级时可能无事件推送或未按预期初始化，UI 失去更新；后续为 Mock 增加初始化逻辑会被静默跳过。
   - 建议：捕获失败后 stop 失败实例（可选），创建 Mock 后立即 `try await service.start()` 并记录降级日志。

2) 中：Settings 首帧使用默认配置，存在误写风险  
   - 位置：Scopy/Views/SettingsView.swift:10-12,78-80  
   - 细节：`tempSettings` 初值 `.default`，真实设置在 `onAppear` 后覆盖。首帧 UI 展示默认热键/设置，用户若快速 Save，会把默认值写回后端，导致热键或存储策略被意外重置。
   - 影响：与 v0.md “UI 先呈现真实数据”不符，热键被覆盖后需用户手动恢复；测试/演示场景易误触。
   - 建议：将 AppState.settings 作为初始化入参或在 onAppear 前通过依赖注入提供初值；或增加加载态/禁用 Save 直到设置加载完成。

3) 中：`.settingsChanged` 兜底热键依赖可空回调且使用旧状态  
   - 位置：Scopy/Observables/AppState.swift:225-228  
   - 细节：仅在 `applyHotKeyHandler` 存在时执行热键应用；复用当前 `settings`，未先 reload。无回调的场景（测试/headless）无法兜底，后台变更时可能用旧热键重复应用。
   - 影响：违背 AGENTS.md “settingsChanged 兜底重应用热键”；在非 UI 场景缺少热键同步；若设置在后台变更，新热键不会应用。
   - 建议：收到 `.settingsChanged` 时先 `await loadSettings()`，再调用兜底应用逻辑；无 handler 时调用本地 fallback（如直接走 HotKeyService 或日志提示），确保 headless/测试也安全。

## 其他观察
- 正向改进：
  - 协议层：ClipboardServiceProtocol 增加生命周期，Mock/Real 对齐；测试 Mock 已补 start/stop 空实现。
  - AppState：工厂/重置单例支持依赖注入，移除 RealClipboardService 类型检查，符合解耦目标。
  - Settings/HotKey：回调解耦 AppDelegate，HotKeyRecorder 录制期间注销/恢复热键走回调，符合前后端隔离。
  - HistoryList：移除文件直读，预览数据完全走服务接口，消除 UI→存储耦合。
- 性能/行为：未改动 Storage/Search/Monitor 主路径，理论上性能指标不受影响。
- 文档：新增 doc/frontend-separation-review.md（详述 Phase 1-4），本评审补充 doc/review/frontend-separation-review-v0.10.md。

## 风险与影响汇总
- 事件流/初始化缺失（降级未 start）：UI 无更新，潜在空列表或 stale 状态。
- 配置误写（Settings 默认值）：热键/存储策略被重置，用户感知强，恢复成本高。
- 热键兜底缺失：headless/测试场景不自动应用，违背要求；后台变更时热键不更新。

## 建议落地顺序
1) 生命周期修复：降级后 start Mock（必要时 stop 失败实例）；补日志。  
2) Settings 初值：构造时注入 appState.settings 或加载完成前禁用 Save/展示加载态，避免默认值落盘。  
3) settingsChanged 兜底：先 reload settings，再兜底应用热键；无回调也执行 fallback。  
4) 测试补强：在 AppStateTests 增加
   - “start 失败降级后仍调用 start/事件流可用”；
   - “settingsChanged 在无回调场景仍应用热键（或记录兜底行为）”；
   - “SettingsView 初始值来自真实设置，快速保存不会写回默认”。

## 参考文件与行号
- Scopy/Observables/AppState.swift:122-133（降级未 start）、225-228（settingsChanged 热键兜底）、10-121（生命周期与依赖注入）
- Scopy/Views/SettingsView.swift:10-12,78-80（默认初始值）、96-115（保存逻辑走回调）
- Scopy/Views/HistoryListView.swift:340-369（移除文件直读，预览依赖服务）
- Scopy/Services/MockClipboardService.swift:19-34（生命周期空实现）
- Scopy/Protocols/ClipboardServiceProtocol.swift:162-174（生命周期协议）

## 测试
- 未执行自动化测试（评审-only）。修复后建议执行：`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`.
