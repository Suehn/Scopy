# Scopy 离线语义检索 v1（E5 + HNSW/SQLite）：超详细设计与实施指南

更新日期：2025-12-17  
当前代码基线：`v0.44.fix20`（见 `doc/implementation/README.md`）  
文档性质：**开发设计文档（未实现）**  
目标读者：维护 Scopy 的开发者（需要落地实现/测试/发布）  

---

## TL;DR（先把路线钉死：最低风险 / 最强性能 / 最好体验）

**v1 的唯一推荐路线（SSOT）：**

1. **Embedding 模型**：`intfloat/multilingual-e5-small`（离线、中英混合、384-dim、检索训练对齐）  
2. **Tokenizer**：从 Model Pack 读取 `tokenizer.json`，在 Swift 侧用 Hugging Face `swift-transformers` 的 `Tokenizers` 模块加载（保证 token id 一致）  
3. **向量索引**：SQLite loadable extension `vectorlite`（HNSW，100k 规模毫秒级召回）  
4. **检索策略**：Hybrid（FTS 词法候选 + 向量候选合并，再排序）  
5. **完全离线**：模型安装完成后，embedding 推理/向量检索/FTS 全离线；剪贴板内容不出网  
6. **模型不进 DMG**：模型以“外挂 Model Pack”按需下载（GitHub Release 或手动导入），下载后强校验（manifest + sha256）  
7. **最终一致性**：因为 embedding 计算慢 + vectorlite 不支持事务 → 必须引入 **outbox（持久化任务队列）+ worker + reconcile**，保证索引最终一致且可崩溃恢复  

> 你要的是“无敌强”：v1 不是“把模型塞进去跑起来就行”，而是把 **工程化（下载/校验/一致性/性能/可观测/回退）** 做成 SSOT。

---

## 0. 一页纸总结（What / Why / Result）

### What（要做什么）

在 Scopy 现有的 **FTS5 + 内存 fuzzyPlus** 搜索体系上，新增一条 **完全本地（离线）语义检索** 管线：

- 文本向量：本地推理生成向量（中英统一向量空间）。
- 向量检索：本地 ANN（HNSW）提供毫秒级召回。
- 语义 + 词法：Hybrid（向量召回 + FTS 召回合并再排序）保证“概念相关”与“关键字/代码精确”同时成立。
- 模型不打包进 DMG：模型以外挂 Model Pack 的方式按需下载到 Application Support（可删除、可替换、可离线导入）。

### Why（为什么要做）

现有 Scopy 搜索已经很快（`SearchEngineImpl` + FTS5 + cache + cancel），但仍偏“词法”：

- 同义改写、跨语言（中文搜英文、英文搜中文）、概念关联弱。
- 长文/噪声文本下，纯词法容易出现“包含 token 但不相关”的结果靠前。

### Result（交付形态）

1. 新增搜索模式：`semantic`（纯语义）与 `hybrid`（推荐默认）。  
2. 新增模型管理：下载/导入/删除/切换；未装模型时自动回退到现有搜索。  
3. 新增向量索引：持久化 index file（HNSW），支持 100k 规模与可回收删除 tombstone。  
4. 新增可观测性：tokenize / embed / ANN / FTS / merge / 回表的分段耗时与 P95 基线。  

---

## 1. 硬约束与成功标准（SLO/验收）

### 1.1 功能约束（必须满足）

- **完全本地推理**：剪贴板内容不出网；语义检索与索引完全在本机。
- **完全离线可用**：模型安装完成后，断网也能正常语义/Hybrid 搜索。
- **模型不打包在 DMG**：DMG 体积不因模型显著膨胀；模型需按需下载、可删除、可替换。
- **中英混合必须好用**：同一历史库中，中英混写、夹杂代码/符号、夹杂 LaTeX/Markdown，都要稳定。
- **与现有接口兼容**：仍以 `SearchRequest` / `SearchResultPage` 为主（见 `Scopy/Domain/Models/SearchRequest.swift`）。
- **不破坏现有体验**：未安装模型时，用户体验与当前版本一致（默认 fuzzyPlus + FTS），语义功能可选启用。
- **Settings 事务模型不破坏**：设置页仍遵循 Save/Cancel（`isDirty`），不要引入 autosave 行为（见 `AGENTS.md` 约定）。

### 1.2 性能目标（建议目标；实现后必须以测试数据验证）

以 v0.md 的“10k–100k：首屏 100–150ms”目标为基线（参考 `doc/specs/v0.md` 与 `ScopyTests/PerformanceTests.swift`）。

**Hybrid 搜索（100k items，limit=50，offset=0）预算建议：**

- Query tokenize：P95 ≤ 2ms（目标：<1ms）
- Query embedding（Core ML）：P95 ≤ 10ms（目标：≤ 5ms；M 系列为主）
- ANN（HNSW）：P95 ≤ 10ms（k≈200，ef≈64）
- FTS（并行可选）：P95 ≤ 20ms（视 query）
- Merge + 排序 + 回表：P95 ≤ 30ms
- 端到端：P95 ≤ 150ms

> 这是“预算”，不是承诺。落地后必须把实测写入 `DEPLOYMENT.md`（硬件/系统/日期/数值），按仓库规范。

---

## 2. 现有代码结构与新增模块的最佳落点（符合你当前风格）

### 2.1 现有搜索/存储链路（现状，已存在）

- 数据写入：`ClipboardMonitor` → `StorageService`（SQLite + 分级存储）  
  关键：`Scopy/Services/StorageService.swift`
- 搜索入口：`ClipboardService.search(query:)`（Application 层门面）  
  关键：`Scopy/Application/ClipboardService.swift`
- 搜索后端：`SearchEngineImpl`（actor）  
  - exact：短词缓存；长词走 FTS5（`clipboard_fts`）
  - fuzzy/fuzzyPlus：全量内存索引 + 可选 FTS 预筛
  - regex：仅 cache
  关键：`Scopy/Infrastructure/Search/SearchEngineImpl.swift`
- DB schema：`clipboard_items`（rowid table）+ `clipboard_fts`（fts5，content_rowid=’rowid’）  
  关键：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`

### 2.2 新增模块（建议分 3 层，保持可替换）

你的工程已经大量采用：

- `actor` 做线程隔离（SearchEngineImpl、ClipboardService、SQLiteClipboardRepository）
- FTS “两段式”策略（先拿 rowid，再回表按需要字段）
- statement cache、timeout/cancel、渐进式搜索（`total == -1` refine）

因此语义检索建议新增三个组件（都可独立替换）：

1. **`EmbeddingModelManager`（@MainActor 或 actor）**  
   - 管 Model Pack 的下载、校验、安装、版本切换、删除
2. **`EmbeddingService`（actor）**  
   - `embedQuery(text)` / `embedPassage(text)`  
   - 内部使用 Core ML（含 tokenizer、pooling、normalize）
3. **`SemanticIndexEngine`（actor）**  
   - 管 `vectorlite` 的加载与索引（insert/delete/search）
   - 提供 `semanticCandidates(request)`：返回 `[(rowid, distance)]`

最后在现有 `ClipboardService.search` 内做路由：

- `exact/fuzzy/fuzzyPlus/regex` → 现有 `SearchEngineImpl`
- `semantic/hybrid` → 新增 `SemanticIndexEngine`（并可复用现有 `SearchEngineImpl` 做 FTS 候选、回表、分页）

> 这样“语义检索”对现有体系是 **增量叠加**，而不是侵入式改造。

---

## 3. 选型（模型 / 向量引擎 / 为什么不引入更重框架）

### 3.1 模型选择：为什么是 `multilingual-e5-small`

剪贴板数据的典型挑战：

- 中英混写（含专业术语/缩写）
- 代码/路径/命令行（符号密集）
- Markdown/LaTeX/网页段落（长文、噪声 token）

`multilingual-e5-small` 的优势：

- **跨语言**：单一向量空间，适合中英混合历史库。
- **小模型**：更容易做到低延迟/低能耗（你的产品是常驻应用）。
- **检索训练对齐**：明确为 query/passage 检索训练，适合“query → 历史片段”。

### 3.2 E5 必须遵守的使用规范（否则效果明显下降）

E5 模型要求输入前缀（非英文也要加）：

- 文档（索引）：`passage: <text>`
- 查询（检索）：`query: <text>`

Pooling / normalization（必须对齐）：

- Tokenize：`max_length=512`，`padding=True`，`truncation=True`
- Pooling：attention-mask mean pooling
- Normalize：L2 normalize（cosine/点积检索前置）

> 这部分在模型卡与官方仓库有明确示例：实现时必须完全对齐，否则“能跑但效果差一截”。

### 3.3 备选嵌入模型（只作为 P2/可选，不建议 v1 上来就换）

你要同时满足 **离线 + 中英混合 + 100k + 低尾延迟**，模型选择本质是三角取舍：

- **精度**：更大模型通常更强，但 query 推理更慢、更吃电。
- **速度**：更小模型更容易做到“打字即出结果”，但要依赖 Hybrid 兜精确性。
- **维护风险**：模型越新/越复杂，tokenizer/转换/兼容性坑越多。

因此 v1 固定 `multilingual-e5-small`，把工程风险压到最低；P2 再考虑：

- `multilingual-e5-base`：更高精度，但 embedding 维度 768，索引体积/内存≈翻倍；推理更慢。
- 其它多语言模型（例如 bge-m3 等）：可能更强，但转换与推理成本更难控；更适合“高精度外挂模式”。

### 3.4 向量引擎选择：为什么是 `vectorlite`（HNSW）而不是其它

v1 的目标是 100k，且要“高性能 + 低尾延迟”。因此首选 ANN（HNSW），原因：

- brute-force 在 100k×384 的 dot/L2 上更容易成为尾延迟来源（尤其并行又要做 FTS/回表）。
- HNSW 的召回/延迟更可控：`M/ef_search/ef_construction` 可调。

对比常见方案（只谈 v1 的“离线嵌入式”场景）：

- `vectorlite`：SQLite loadable extension + HNSW + index serde + metadata filter pushdown → **最契合你当前 SQLite 架构**。
- `sqlite-vec`：纯 C、无依赖、双许可证（Apache-2.0/MIT），但主要是 brute-force 向量扫描 → v1 不适合作为 100k 的默认性能方案（可当 fallback/小库方案）。
- `sqlite-vss`（Faiss）：项目声明“not in active development”，且过滤/更新能力受限 → v1 不推荐。
- `sqlite-vector`（sqlite.ai）：许可证为 Elastic License 2.0 → **不适合 Scopy 这种公开分发/开源项目**。
- 直接集成 Faiss/hnswlib：Swift/C++ 工程化与 codesign/notarize 风险更高，且会重复你现有 SQLite 数据模型。

### 3.5 为什么不引入更重的 IR 框架（Lucene/Tantivy/Milvus 等）

你现有工程已经有：

- SQLite（WAL、mmap、FTS5、触发器、两段式回表、interrupt）
- 搜索/存储 actor 隔离

在 **完全离线 + 仅 100k 规模** 的前提下，引入更重框架通常带来：

- 构建/打包复杂度显著上升（Rust/Java/C++ 大依赖、交叉编译、codesign/notarize 风险）。
- 运行时资源更难控（索引格式升级、崩溃恢复、常驻内存不可控）。
- 与现有 SQLite 数据模型重复（你已用 rowid/FTS5 解决了大部分词法检索问题）。

因此 v1 的最小风险路线是：**继续以 SQLite 为唯一持久化与词法索引基座**，仅新增一个“可加载扩展”作为向量 ANN 引擎，并用 Hybrid 把精度兜住。

---

## 4. “模型外挂”方案（不进 DMG，但要可控、可校验、可回滚）

### 4.1 目标与威胁模型（最低风险要点）

模型外挂带来的主要风险不是“代码执行”，而是：

- 下载失败/断点/损坏 → 需要自动恢复
- 版本不一致（tokenizer 与 model 不匹配）→ 需要强校验
- 被篡改（MITM 或 CDN 异常）→ 需要 checksum（最好再加签名）

因此 v1 必须做到：

1. **原子安装**：下载到 tmp → 校验 → 解压 → 再 rename 到正式目录
2. **强一致性**：manifest 锁死：模型版本、维度、tokenizer、sha256、文件列表
3. **离线可用**：模型安装完成后，断网也可完全运行
4. **可清理**：用户可一键删除模型与索引释放磁盘

### 4.2 Model Pack 目录结构（建议）

以 StorageService root 目录为基准（默认 `~/Library/Application Support/Scopy/`）：

```
Scopy/
  clipboard.db
  content/...
  thumbnails/...
  semantic/
    models/
      e5-multilingual-small/
        1.0.0/
          manifest.json
          tokenizer.json
          tokenizer_config.json
          special_tokens_map.json
          model.mlmodelc.zip          # 下载产物（推荐 v1）
          model.mlmodelc/             # 解压后的目录（运行时加载）
    index/
      e5-multilingual-small/
        1.0.0/
          clipboard_vec.index.bin     # vectorlite index file（HNSW）
    state.json                        # 当前启用模型、安装状态、最后一次校验时间等
```

> v1 推荐直接分发 `model.mlmodelc.zip`：  
> - 优点：安装无需编译，路径简单；`MLModel(contentsOf:)` 直接 load `.mlmodelc`。  
> - 风险：需要你在 CI 固定 Xcode/macos target，验证 `.mlmodelc` 在 macOS 14+ 可用。  
> 后续若确认 `MLModel.compileModel(at:)` 能稳定编译 `.mlpackage`（并验证 macOS 14），可切换到“下载 mlpackage → 本机编译”的路线。

### 4.3 模型分发来源（推荐策略）

最小风险建议：

- 在 Scopy 主仓库（或单独 `ScopyModels` 仓库）建 GitHub Release，发布：
  - `scopy-model-e5-multilingual-small-1.0.0.zip`（内含 manifest + tokenizer + model.mlmodelc.zip）
  - `scopy-model-e5-multilingual-small-1.0.0.sha256`
- App 内置“模型 catalog”（硬编码或随 app 更新）：
  - 固定 URL 列表 + sha256
  - **不做自动更新**（更新 Model Pack 需要随 app 发布更新 catalog），风险最低

进阶（P2 可选）：

- catalog 从网络拉取，但必须带签名（内置公钥验签）

### 4.4 下载/安装流程（严格状态机）

定义安装状态（Settings 可展示）：

- `notInstalled`
- `downloading(progress)`
- `verifying`
- `installing`
- `ready`
- `failed(error)`

流程：

1. 用户在 Settings 点击“Download”
2. 下载 zip → 写入 `.../semantic/tmp/<uuid>/`
3. 校验 zip 整体 sha256（与 catalog 对比）
4. 解压 → 校验 `manifest.json` + `files[*].sha256`
5. 原子 move 到 `semantic/models/.../1.0.0/`
6. 写入 `semantic/state.json`，标记为启用

失败恢复：

- 任意一步失败 → 删除 tmp → 状态 `failed`（提供重试）

### 4.5 `manifest.json` 规范（必须：强一致性 + 可审计）

每个 Model Pack 必须带 `manifest.json`，建议 schema：

```json
{
  "model_id": "e5-multilingual-small",
  "version": "1.0.0",
  "license": "MIT",
  "embedding": {
    "dimension": 384,
    "max_tokens": 512,
    "distance": "cosine",
    "query_prefix": "query: ",
    "passage_prefix": "passage: ",
    "pooling": "attention_mask_mean",
    "normalize": "l2"
  },
  "files": [
    { "path": "tokenizer.json", "sha256": "..." },
    { "path": "tokenizer_config.json", "sha256": "..." },
    { "path": "special_tokens_map.json", "sha256": "..." },
    { "path": "model.mlmodelc.zip", "sha256": "..." }
  ],
  "created_at": "2025-12-17",
  "notes": "E5 multilingual small, mlmodelc zipped"
}
```

强校验规则（v1 必做）：

- `embedding.dimension` 必须等于你向量表定义维度（384）。
- `query_prefix/passage_prefix` 必须存在且非空（E5 训练假设）。
- tokenizer 文件必须齐全；否则拒绝安装。
- `files[*].sha256` 必须全量匹配（不仅校验 zip 整体）。

### 4.6 纯离线环境支持（air‑gapped / 企业电脑）

必须提供 **不联网也能安装模型** 的路径：

- Settings 提供 “Import Model Pack…”：
  - 允许选择本地 `*.zip`（与 Release 同格式）
  - 走同一套校验/安装流程
- 文档给出“另一台联网机器下载 zip + sha256，再拷贝到目标机器”的步骤

### 4.7 清理策略（释放磁盘 + 防止半残留）

必须提供两个清理入口：

1. **删除模型（仅模型）**：删除 `semantic/models/<id>/<ver>/`  
2. **删除语义索引（仅 index）**：删除 `semantic/index/<id>/<ver>/`

清理实现原则：

- 删除前必须停止使用（释放 Core ML model、关闭 vectorlite 连接）
- 删除用“先移动到 trash 再异步删除”（避免 UI 卡顿；失败可回滚）

---

## 5. Core ML 推理落地（毫秒级的关键点）

### 5.1 推理 API 形态（建议输出已 pooling + normalize 的 embedding）

为了把 Swift 侧开销降到最低，建议 Core ML 模型输出直接是 embedding：

- 输入：`input_ids`、`attention_mask`（以及必要时 `token_type_ids`，视模型而定）
- 输出：`embedding`（shape `[384]` float32），已做 mean pooling + L2 normalize

这样 Swift 侧只做：

1) tokenize → 2) 送入 Core ML → 3) 得到 embedding（Float32[384]）  
避免在 Swift 层遍历 `last_hidden_state` 做 pooling（长序列会额外吃 CPU）。

### 5.2 computeUnits 策略（面向“常驻应用”）

建议优先：

- `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`（若可用）
备选：
- `.all`
兜底：
- `.cpuAndGPU` / `.cpuOnly`

注意：

- 实际是否走 ANE 受算子、量化、系统版本影响；不要承诺“必走 ANE”。
- 必须用性能基准验证（见第 10/14）。

### 5.3 Tokenizer 与输入预处理（中英混写的关键）

#### 5.3.1 tokenizer 来源与一致性

为了避免“看起来能 tokenize，但 token id 不一致”的灾难，v1 强制：

- tokenizer 使用 Model Pack 内的 `tokenizer.json`（与模型同版本打包）
- 不要用系统分词或自写 tokenization（会直接毁掉 embedding 质量）

#### 5.3.1.1 Tokenizer 的 Swift 落地路线（v1 推荐：最低风险且高性能）

**核心原则：Tokenizer 必须与模型训练时完全一致。**  
对检索 embedding 来说，“token id 不一致”比“模型小一点”更致命：会得到**能跑但召回很差**的结果。

v1 推荐使用 Hugging Face `swift-transformers` 的 `Tokenizers` 模块，从 Model Pack 的本地目录加载 tokenizer：

- ✅ 直接读 `tokenizer.json`（与 HF/Transformers 同源格式）
- ✅ 性能强（fast tokenizer 路径）
- ✅ Swift 6 支持，维护风险更低

建议版本固定（避免 tokenizer 行为变更引入不可预期回归）：

- SwiftPM：`https://github.com/huggingface/swift-transformers`（建议固定到一个已验证 tag，例如 `1.1.5`）

伪代码（示意）：

```swift
import Tokenizers

let tokenizer = try await AutoTokenizer.from(modelFolder: modelDirURL)
let encoded = try tokenizer.encode(text: "query: hello 世界")
// encoded.ids / encoded.attentionMask -> MLMultiArray([1, maxTokens])
```

#### 5.3.2 输入文本规范化（与 Scopy 现有 normalizeText 协调）

Scopy 当前已经对 `plainText` 做了稳定化（统一换行、trim、NBSP/BOM 处理，见 `Scopy/Services/ClipboardMonitor.swift`）。

对 embedding 建议：

- 使用 **同一份 normalized plainText** 作为 passage 输入（避免“肉眼一样但向量不一样”）
- 不做 aggressive normalize（不要移除标点、不要大小写折叠），否则会破坏代码/路径/公式语义

建议 passage/query 统一做：

- `trimmingCharacters(in: .whitespacesAndNewlines)`
- `\r\n/\r → \n`
- 保留原始大小写

#### 5.3.3 Query/Passage 前缀（必须）

- `query: ` 与 `passage: ` 必须添加（包括中文）
- 前缀后紧跟原文（不要额外加语言标签）

#### 5.3.4 长文截断策略（512 tokens 上限）

剪贴板长文常见（网页/论文/PDF）。

- v1：直接 truncate（保留前 512 tokens）
- P1：可选“头+尾拼接”（前 256 + 后 256，中间插入 `\n...\n`），仍保持 ≤512 tokens

> 这是“语义变化”策略，需要回归测试与 A/B（P1 做）。

### 5.4 Swift 侧数据结构（避免隐形拷贝）

**输入：**

- `input_ids` / `attention_mask` 转为 Core ML 的 `MLMultiArray`
- 建议固定 shape（例如 `[1, 512]`），避免 dynamic shape 引发 graph 缓存 miss

**输出：**

- 模型输出 `[384]` 的 `MLMultiArray`（float32）
- 立刻拷贝到 `ContiguousArray<Float32>` 或 `Data`，用于 vectorlite

关键性能点：

- 避免 `Array` ↔ `Data` 多次拷贝
- 用 `withUnsafeBytes` / `withUnsafeBufferPointer` 打包 float32 bytes（little-endian）

### 5.5 Core ML 模型产物的构建流水线（总览）

v1 目标是“模型不进 DMG”，但你仍需要一个可复现的构建流程生成 Model Pack。

流程总览：

1) 拉取 HF 模型与 tokenizer（固定 tag/commit）  
2) 导出/转换为 CoreML（建议输出已 pooling + normalize 的 embedding）  
3) 权重量化（v1 推荐 W8 weight-only）  
4) 产出 `model.mlmodelc.zip`（或 mlpackage）  
5) 生成 `manifest.json` 与 per-file sha256  
6) 打包 zip 并发布到 GitHub Release  

> 本节只给总览。可复现的版本锁定、命令、脚本骨架、产物规范、发布流程详见第 13 节。

### 5.6 推理缓存与取消（对齐你现有 cancel 语义）

你已有 debounce + cancel（`HistoryViewModel`），后端 `SearchEngineImpl` 也支持 timeout + `sqlite3_interrupt`。

语义推理必须支持：

- 输入变化时取消上一条 embedding 推理任务（避免排队堆积）
- 缓存最近 N 个 query 的 embedding（建议 N=32）：
  - key：`model_id + model_version + normalized_query_text`
  - value：`Float32[384]` + timestamp

缓存要点：

- 命中时跳过 tokenize+推理（打字过程收益巨大）
- cache 只对 query（短文本）开；document embedding 不缓存（写入后即存入 index）

### 5.7 量化（降低模型体积 + 提升吞吐）

v1 推荐 **weight-only int8（W8）**：

- 体积显著下降
- 推理速度通常更好或至少不差
- 跨设备更稳

注意：

- W8A8 等更激进量化在 macOS 上收益不确定；不要先假设，必须实测后再启用。

---

## 6. 向量检索引擎：vectorlite（HNSW）作为 v1 默认

### 6.1 选择理由（对 100k 非常关键）

`vectorlite` 的关键能力：

- HNSW ANN（可调 `M / ef_construction / ef_search`）
- cosine 距离（适配 L2 normalize 的 E5 embedding）
- rowid filter pushdown（`rowid IN (SELECT ...)`），过滤不会“先召回再过滤导致漏”
- index serde：index file 持久化，重启免重建

### 6.2 vectorlite 的已知限制（必须在设计里显式规避）

1. **不支持事务**：主表写入与向量写入不能原子一致；必须用 outbox/补偿做到最终一致（第 8.5）。  
2. **metadata filter 能力有限**：只支持 `AND`/`OR`，不支持复杂表达式（括号/嵌套布尔）。  
3. **rowid 约束**：`rowid` 必须在 `[1, 9223372036854775807]` 且不超过 `size_t` 上限。  
4. **维度/列约束**：embedding 维度必须 `< 2048`；每张向量表只能有 1 个 vector 列。  
5. **仅 float32**：embedding 存储为 float32 BLOB → 索引体积与内存占用真实可见。  
6. **删除是 tombstone**：不会立即释放；依赖 `allow_replace_deleted=true` 复用或定期重建回收。  
7. **索引驻留内存**：HNSW index 常驻内存；必须把 max_elements 与内存预算绑定（第 6.7）。  

### 6.3 表结构（与 clipboard_items 共享同一 SQLite 文件）

建议新建虚拟表（只存向量索引，不存业务字段）：

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_vec
USING vectorlite(
  embedding float32[384] cosine,
  hnsw(
    max_elements = 100000,
    ef_construction = 200,
    M = 32,
    random_seed = 100,
    allow_replace_deleted = true
  ),
  '/ABS/PATH/TO/Scopy/semantic/index/e5-multilingual-small/1.0.0/clipboard_vec.index.bin'
);
```

> v1 推荐：向量表 `rowid` 直接复用 `clipboard_items.rowid`（见第 8.4）。

### 6.4 过滤下推（与你的 SearchRequest 对齐）

```sql
SELECT rowid, distance
FROM clipboard_vec
WHERE knn_search(embedding, knn_param(? /* query embedding blob */, ? /* k */, ? /* ef */))
  AND rowid IN (
    SELECT rowid FROM clipboard_items
    WHERE app_bundle_id = ?
      AND type IN (?, ?, ?)
  )
ORDER BY distance
LIMIT ?;
```

### 6.5 删除与更新（索引维护必须做）

删除：

```sql
DELETE FROM clipboard_vec WHERE rowid = ?;
```

更新：

```sql
UPDATE clipboard_vec SET embedding = ? WHERE rowid = ?;
```

> v1 推荐：只对“新插入 item”生成 embedding；对 dedup 的“只更新 lastUsedAt/useCount”不重算 embedding。

### 6.6 在 Scopy 中集成 vectorlite（构建 / 打包 / codesign / 加载）

目标：vectorlite 作为 native code 随 app 分发（它不是模型，不在“模型不进 DMG”的限制内）。

#### 6.6.1 构建（loadable extension）

vectorlite 官方提供 `make loadable`：

```bash
git clone --depth=1 https://github.com/1yefuwang1/vectorlite.git
cd vectorlite
make loadable
ls -lah dist/
# dist/vectorlite0.dylib
```

#### 6.6.2 Universal dylib（arm64 + x86_64）

```bash
# arm64 build
make clean
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  CFLAGS="-O3 -arch arm64 -mmacosx-version-min=14.0" \
  LDFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
  make loadable
cp dist/vectorlite0.dylib /tmp/vectorlite0.arm64.dylib

# x86_64 build
make clean
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  CFLAGS="-O3 -arch x86_64 -mmacosx-version-min=14.0" \
  LDFLAGS="-arch x86_64 -mmacosx-version-min=14.0" \
  make loadable
cp dist/vectorlite0.dylib /tmp/vectorlite0.x86_64.dylib

lipo -create \
  /tmp/vectorlite0.arm64.dylib \
  /tmp/vectorlite0.x86_64.dylib \
  -output /tmp/vectorlite0.universal.dylib
```

> 如果 Makefile 不吃 `CFLAGS/LDFLAGS`，改用 `CC="clang -arch ..."` 或直接改 Makefile（但 v1 尽量少改上游）。

#### 6.6.3 放置位置（App Bundle 内固定路径）

原则：

- 只允许从 **App Bundle 内的只读路径** 加载（安全）。
- 绝不从 Application Support（可写目录）加载 dylib（风险极高）。

推荐路径：

- `Scopy.app/Contents/Resources/sqlite_extensions/vectorlite0.dylib`

#### 6.6.4 codesign / notarize（Hardened Runtime）

如果 Scopy 启用 Hardened Runtime：

- 被 `dlopen` 的 dylib 必须通过 library validation（通常要求同 Team ID 签名，并在签名范围内）。
- 确保 dylib 被 Copy Files 进 bundle，最终 `codesign --verify --deep` 通过。

#### 6.6.5 运行时加载（最小化 enable_load_extension）

原则：

- 只在加载时 `sqlite3_enable_load_extension(db, 1)`，加载后立刻关掉。
- 只加载你 bundle 里的绝对路径，禁止用户输入路径。

伪代码：

```swift
import SQLite3

func loadVectorliteExtension(db: OpaquePointer, dylibPath: String) throws {
    sqlite3_enable_load_extension(db, 1)
    defer { sqlite3_enable_load_extension(db, 0) }

    var errMsg: UnsafeMutablePointer<Int8>?
    let rc = sqlite3_load_extension(db, dylibPath, nil, &errMsg)
    if rc != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "sqlite3_load_extension failed: \(rc)"
        sqlite3_free(errMsg)
        throw NSError(domain: "Scopy.Semantic", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
```

> 建议把加载封装到 `SQLiteConnection` 内部，外部不暴露“可加载扩展”的能力（更安全）。

### 6.7 参数与资源预算（100k 的现实：性能 ≠ 不花资源）

#### 6.7.1 向量体积粗估

`dim=384` float32：

- 单条向量：`384 * 4 = 1536 bytes ≈ 1.5KB`
- 100k 条：`~153.6MB`（仅向量本体，不含 HNSW 图）

HNSW 额外开销与 `M` 强相关，因此 v1 默认 `M=32`（召回更稳）。

#### 6.7.2 v1 默认参数（先选一组稳的）

- `M = 32`
- `ef_construction = 200`
- `allow_replace_deleted = true`
- 查询：`k = 200`，`ef_search = 64`（每次 query 显式传入）

#### 6.7.3 调参方法（必须用真实数据校准）

- 召回不够：先加 `ef_search`，再加 `k`，最后才动 `M`。
- 构建慢：降 `ef_construction` 或把 backfill 变得更温和（见第 8.2/8.5）。
- 内存大：降低 `M` 或降低 semantic index max_elements（例如默认 50k，设置里允许开到 100k）。

---

## 7. Hybrid 检索算法（语义强 + 代码/符号稳 + 体验一致）

### 7.1 基本策略（两路召回 + 合并重排）

并行召回：

1. Lexical：复用现有 exact/FTS（`FTSQueryBuilder` + `clipboard_fts MATCH`）
2. Semantic：向量 knn_search（可过滤下推）

合并：

- rowid 去重（同一 row 可能同时被 FTS 与语义命中）
- 统一打分：`hybridScore`
- 回表取 summary（与现有 FTS 两段式一致）

### 7.2 候选集规模（k 的选择）

v1 推荐（limit=50 首屏）：

- semantic：`k = 200`
- lexical：`k = 200`（FTS rowid 上限）

有强过滤时：

- semantic `k` 适度增大（如 400），避免过滤后候选过少

渐进 refine（可选）：

- 首屏不足/`total=-1` 时，后台用更高 `ef` 或更高 `k` 再跑一轮补全（UI 已支持 refine 契约）。

### 7.3 打分与排序（兼容 pinned + 强相关性）

排序建议：

1) pinned（硬约束）  
2) `hybridScore`（高相关优先）  
3) lastUsedAt（同分更近）  
4) id（稳定性）  

`hybridScore`（起点，需用真实数据调权）：

- `sim = 1 - distance`（cosine distance → similarity）
- `lexScore`：FTS rank 归一化（topK 内 `1 - rank/(K-1)`；未命中 0）
- `recency`：`lastUsedAt` 归一化（例如 7 天内线性衰减）

示例：

```
hybridScore = 0.55 * sim + 0.30 * lexScore + 0.15 * recency
```

### 7.4 分页（offset>0 的稳定性）

沿用你 fuzzy 的深分页缓存思路：

- 对同一 `query + filter + model_version`：
  - 缓存已排序候选 rowid（或至少前 N=2000）
  - 深分页只做切片 + 回表
  - 避免每页重跑 embedding + ANN + FTS

缓存失效：

- 插入/删除/Pin 状态变化
- 模型切换或索引重建

---

## 8. 索引构建与增量更新（常驻应用必须“稳”）

### 8.1 写入时机（最省算力策略）

- 新插入（非 dedup）：
  - 生成 passage embedding（`passage: <plainText>`）
  - 写入向量索引
- dedup（只更新 lastUsedAt/useCount）：
  - 不重算 embedding（plainText 不变）
- Pin/unpin：
  - 不影响 embedding（只影响排序）

### 8.2 Backfill（首次启用模型或升级模型）

第一次安装模型：

1) semantic/hybrid 可立即启用（结果可能不完整）  
2) 后台启动 backfill：
   - 从 `clipboard_items` 分页扫描（建议按 `last_used_at DESC` 优先覆盖最近内容）
   - 逐条生成 embedding 并写入索引
3) UI：
   - index 覆盖率低时可返回 `total=-1` 并提示“索引构建中”

### 8.3 删除与清理（与 Storage cleanup 对齐）

单条 delete（按 UUID）：

1) `SELECT rowid FROM clipboard_items WHERE id=?`  
2) `DELETE FROM clipboard_items WHERE id=?`  
3) enqueue 向量删除任务（或直接删向量表；但 v1 推荐 outbox，见第 8.5）

批量 delete（cleanup）：

1) 先取 rowid 列表
2) 批量 enqueue delete 任务

> 注意：vectorlite 不支持事务，不能保证与主表原子一致；v1 必须做最终一致性（第 8.5）。

### 8.4 主键/rowid 策略（SSOT：向量索引用什么 key）

v1 推荐：

- **向量表 rowid = `clipboard_items.rowid`**

理由：

- 你已经在 FTS 路径用 rowid 做 join（`SearchEngineImpl.searchWithFTS`）。
- `clipboard_items` 是 rowid table（`id TEXT PRIMARY KEY`），天然有整数 rowid。
- 复用 rowid 可以把语义检索做成“增量叠加”，不引入额外映射表。

#### 8.4.1 如何拿到 rowid（插入/删除/回表）

插入后拿 rowid（两种方式二选一）：

1) **稳：按 UUID 查**

```sql
SELECT rowid FROM clipboard_items WHERE id = ?;
```

2) **快：sqlite3_last_insert_rowid（需要连接层支持）**

- 插入后立刻读 `sqlite3_last_insert_rowid(db)`（同一连接、期间无其它 insert）

> v1 先用方式 1，稳了再优化。

删除前拿 rowid：

```sql
SELECT rowid FROM clipboard_items WHERE id = ?;
```

回表取 summary：按 rowid join `clipboard_items`。

#### 8.4.2 rowid 稳定性/复用风险（必须显式说明）

- rowid 对同一行在 UPDATE 下保持不变（你的 dedup 是 UPDATE，所以安全）。
- rowid 可能在“删除后再插入”时复用（尤其当删除了当前最大 rowid）。

风险如何被 v1 控制：

- cleanup 通常删旧数据，极少删当前最大 rowid → 复用概率低。
- outbox + reconcile 保证删除最终会落到向量索引（第 8.5）。
- 查询时用 join/IN 子查询确保 rowid 必须存在于 `clipboard_items`，避免幽灵行。

若要把风险压到极低（P2 可选）：

- 给 `clipboard_items` 增加“永不复用”的整数列（例如 `semantic_seq`），作为向量主键（需要 migration + backfill）。

### 8.5 最终一致性（v1 强烈建议就做）：Outbox + Worker + Reconcile

你需要同时满足：

- 写入路径不能卡 UI（embedding 可能很慢）
- vectorlite 不支持事务（不能与主表原子一致）
- 崩溃/退出后能恢复（任务不能丢）

因此 v1 推荐引入 **outbox（持久化任务队列）+ worker + reconcile**。

#### 8.5.1 Outbox 表（持久化任务队列）

建议在主 SQLite（clipboard.db）内新增普通表（可事务）：

```sql
CREATE TABLE IF NOT EXISTS semantic_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_id TEXT NOT NULL,
    model_version TEXT NOT NULL,
    action TEXT NOT NULL,              -- 'upsert' | 'delete'
    item_rowid INTEGER NOT NULL,       -- clipboard_items.rowid
    item_id TEXT NOT NULL,             -- clipboard_items.id (UUID string), 用于诊断/去重
    plain_text_hash TEXT,              -- 可选：用于判断是否需要重算（P1）
    priority INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_retry_at REAL NOT NULL DEFAULT 0,
    created_at REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_semantic_outbox_retry
ON semantic_outbox(next_retry_at, priority DESC, id);
```

关键点：

- outbox 在主库里，可事务、可 WAL、可 crash-recover。
- `model_id/model_version` 必须入表：模型切换/升级会产生新队列。
- `plain_text_hash`（可选）用于 P1：如果 plain_text 没变，可以跳过 upsert。

#### 8.5.2 Producer：谁来写 outbox（两种实现，v1 推荐 A）

A) **应用代码显式写 outbox（v1 推荐）**

- 在 `StorageService`/`SQLiteClipboardRepository` 完成 insert/delete 后，立刻写一条 outbox 记录。
- 优点：逻辑清晰、可测试、可按“是否启用语义”决定是否写队列。
- 缺点：若进程崩溃在“insert 成功但 outbox 未写”之间，会漏任务（可被 reconcile/backfill 修复）。

B) **SQLite trigger 写 outbox（可选，鲁棒但更隐式）**

- `AFTER INSERT ON clipboard_items` 写 outbox（action=upsert）
- `AFTER DELETE ON clipboard_items` 写 outbox（action=delete）
- `AFTER UPDATE OF plain_text` 写 outbox（action=upsert）
- 注意：trigger **只写 outbox**，不要直接写向量表。

> 你当前已经用 trigger 维护 FTS；如果你更在意“绝不漏任务”，可以用 B。v1 为最小侵入建议先用 A + reconcile 兜底。

#### 8.5.3 Worker：如何消费 outbox（必须可取消/限速/低功耗）

新增后台 actor（示意）：`SemanticIndexWorker`

- 循环拉取 `next_retry_at <= now` 的任务（按 `priority DESC, id ASC`）
- 对 `upsert`：
  1) 读取 `clipboard_items` 的 plain_text（或 summary）  
  2) 生成 embedding（passage 前缀 + tokenize + CoreML）  
  3) `INSERT OR REPLACE`/`UPDATE` 写入向量表（按 rowid）  
  4) 删除 outbox 任务（或标记 done）
- 对 `delete`：
  - `DELETE FROM clipboard_vec WHERE rowid = ?`（即便不存在也视为成功）
  - 删除 outbox 任务

限速与功耗：

- backfill 时控制每秒处理条数（例如 50–200/s 视机型）
- Low Power Mode 或 battery 场景可降速/暂停
- 大模型/大库构建必须跑在 `.utility` QoS，避免影响 UI

重试：

- 失败时 `attempts += 1`，并按指数退避设置 `next_retry_at`（例如 `min(60s, 2^attempts)`）
- 超过最大重试次数（例如 10 次）后保留任务但标红/可手动“Retry All”

#### 8.5.4 Reconcile：启动/定时做一致性修复（必须有）

原因：

- outbox 可能漏写（实现 A）或失败堆积
- tombstone 可能导致索引长期膨胀
- 用户可能手动删索引文件/模型目录

reconcile 的目标：

1) 修复缺失：`clipboard_items` 有 rowid，但向量表没有 → enqueue upsert（优先 recent）
2) 修复多余：向量表有 rowid，但主表不存在 → enqueue delete（或直接删）

建议触发时机：

- App 启动后（延迟几秒，避免影响启动）
- 模型安装完成后
- 每天一次（可选）

#### 8.5.5 index 回收策略（tombstone 清理）

vectorlite 删除是 tombstone：

- 短期靠 `allow_replace_deleted=true` 复用
- 长期需要“重建 index file”回收空间（P2/维护任务）

重建策略（P2）：

1) 创建新 index 文件（新路径）  
2) 扫描 `clipboard_items`（按最近优先）重建向量表  
3) 原子切换 index 文件（更新 state.json）  
4) 删除旧 index file  

---

## 9. 兼容“模型缺失/离线/失败”的体验（必须）

### 9.1 行为矩阵

| 场景 | 语义模式 | Hybrid 模式 | 默认模式（fuzzyPlus） |
|------|----------|-------------|------------------------|
| 模型未安装 | 禁用/提示下载 | 退化为 lexical-only（FTS/缓存） | 正常 |
| 模型下载中 | 禁用/提示下载中 | lexical-only + 后台构建 | 正常 |
| 模型损坏/校验失败 | 禁用/提示重装 | lexical-only + 错误提示 | 正常 |
| 离线且已安装 | 正常 | 正常 | 正常 |
| 索引构建中 | 可能不完整（total=-1） | 先出首屏再 refine | 正常 |

### 9.2 UI 提示原则

- 不要弹窗打断；用 Settings 状态与轻量提示。
- 索引构建中：
  - 可显示 “Building semantic index…”
  - 仍优先保证 lexical 结果可用（体验不崩）

---

## 10. 可观测性与性能压测（落地后必须补齐）

### 10.1 分段计时（建议）

在一次 `search` 请求中分段记录：

- `t_tokenize_ms`
- `t_embed_ms`
- `t_vec_ms`
- `t_fts_ms`
- `t_merge_ms`
- `t_fetch_ms`
- `t_total_ms`

输出：

- `/tmp/scopy_semantic.log`（类比热键日志风格）
- 可选：扩展 UI `PerformanceSummary` 展示 semantic/hybrid 指标

### 10.2 性能用例（必须新增，贴合现有 PerformanceTests 风格）

在 `ScopyTests/PerformanceTests.swift` 基础上新增（heavy 测试用 env gate）：

1) **Semantic Query P95**：100k items，中英混合短 query/长 query  
2) **Hybrid Query P95**：同上，包含 app/type filter  
3) **Backfill Throughput**：每秒 embedding 的文档数（限制 CPU 占用）  
4) **Index Warm Start**：重启后首次 semantic query（index load + model load）  
5) **Deep Paging Stability**：offset 深分页不抖动（query-scope cache 生效）  

并在 `DEPLOYMENT.md` 记录：

- 硬件（型号/内存）
- macOS 版本
- Xcode/Swift 版本
- Debug/Release
- 具体数值（P50/P95）

### 10.3 基准数据集（必须覆盖 Scopy 真实形态）

为了避免“纯英文短句”导致误判，建议在 perf tests 的数据生成里覆盖：

- 中英混合（含专业英文术语）
- 代码/路径/命令行（符号密集）
- Markdown/LaTeX 片段
- 长文（1–20KB）

并固定 10–20 个 query 集合（包含跨语言查询），保证每次迭代可对比。

---

## 11. 实施路线（P0 → P1 → P2，最小风险推进）

### P0（先让它“可用且不破坏现有”）

1) 增加 SearchMode：`semantic` / `hybrid`（默认仍 fuzzyPlus）  
2) Model Pack 管理（下载/导入/校验/删除/状态机）  
3) Tokenizer + Core ML 推理：`EmbeddingService.embedQuery/embedPassage`（prefix + pooling + normalize）  
4) vectorlite 集成：加载扩展 + 创建/打开 index file + knn_search  
5) Hybrid：并行拿 FTS topK 与 vector topK → 合并 → 回表 → 排序  
6) 最终一致性：outbox + worker + reconcile（至少 A 方案 + reconcile）  
7) 失败回退：模型缺失/索引未就绪 → lexical-only  

### P1（精度/稳定性加强）

1) 参数调优：`M/ef_construction/ef_search/k` 用真实数据调参  
2) 深分页缓存：query-scope sorted candidates  
3) Backfill 优先级：按最近/使用次数优先，提升“首日体验”  
4) `plain_text_hash` 机制：避免重复重算（内容没变不做 upsert）  
5) Worker 限速：低功耗/电池策略更精细  

### P2（长期维护与“无敌体验”）

1) 可选更强模型（e5-base）作为“高精度模式”（外挂下载）  
2) index 重建回收 tombstone（后台维护任务）  
3) 结果解释：Hybrid 结果的“命中原因”（FTS/snippet/语义相近）  
4) catalog 签名与独立更新  

---

## 12. 工程变更清单（到文件/SQL/设置 UI 的粒度）

> 本节是“照着做就能落地”的 checklist，避免实现阶段到处翻文档。

### 12.1 数据库（SQLiteMigrations）

- 新增 outbox 表：`semantic_outbox`（第 8.5.1）
- （可选）trigger 写 outbox（方案 B）
- 需要 bump `PRAGMA user_version`（新 migration version）

### 12.2 新增服务/模块（建议路径）

- `Scopy/Services/Semantic/EmbeddingModelManager.swift`
- `Scopy/Services/Semantic/EmbeddingService.swift`
- `Scopy/Services/Semantic/SemanticIndexEngine.swift`
- `Scopy/Services/Semantic/SemanticIndexWorker.swift`

### 12.3 SQLite 连接层（SQLiteConnection）

- 增加 `loadExtension(atAbsolutePath:)`（内部 enable/disable load_extension）
- 增加一个“向量专用连接”（避免与现有读连接互相影响；并保留 interrupt 能力）

### 12.4 Settings UI（必须遵循 Save/Cancel）

新增设置项（建议）：

- `searchModeDefault`: fuzzyPlus / hybrid / semantic（默认保持现状）
- `semanticEnabled`: Bool（或隐含：安装模型后可选启用）
- `semanticMaxItems`: Int（默认可低一些，例如 50k；上限 100k）
- “Model Pack 管理”动作：
  - Download / Import / Delete Model / Delete Index / Rebuild Index

> 注意：Download/Import/Delete 属于“动作”，不应绑在 Save/Cancel 的事务里；但“启用/默认模式/最大条数”应走 Save/Cancel。

### 12.5 日志与诊断

- 新增 `/tmp/scopy_semantic.log`（分段耗时 + outbox 状态 + 错误）
- Settings/Debug 面板可展示：
  - 当前模型（id/version）
  - 索引覆盖率（已索引/总数）
  - outbox backlog（待处理条数）

---

## 13. Model Pack 构建与发布（可复现：版本锁定 + 命令级细节）

> 目标：任何人照着这份文档，都能在同样版本锁定下产出一致的 Model Pack（可验证 sha256）。

### 13.1 建议的“固定构建环境”

建议在一台专用构建机（或 CI）固定：

- macOS：14+（与你 app 最低兼容对齐）
- Xcode：固定版本（用于验证 `.mlmodelc` 兼容性）
- Python：建议 3.11/3.12（coremltools 常见支持范围；不要用过新的 Python）

> 注意：本仓库当前开发机可能是 Python 3.14（过新）。Model Pack 构建建议独立环境（pyenv/uv/conda 或 CI）。

### 13.2 依赖版本锁定（v1 建议）

以 2025-12-17 为基线，建议锁定：

- `coremltools==9.0`
- `torch==2.6.0`
- `transformers==4.56.1`
- `numpy==2.1.0`（示例；以你环境可用为准）

建议写一个 `requirements.txt`（示例）：

```
coremltools==9.0
torch==2.6.0
transformers==4.56.1
numpy==2.1.0
```

### 13.3 导出“已 pooling + normalize”的 CoreML 模型（Python 脚本骨架）

关键：把 mean pooling + L2 normalize 放进图里（Swift 侧不做大矩阵 pooling）。

示例骨架（伪代码，需按你具体转换路径调整）：

```python
import torch
import torch.nn.functional as F
from transformers import AutoModel

class E5Embedder(torch.nn.Module):
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, input_ids, attention_mask):
        out = self.base(input_ids=input_ids, attention_mask=attention_mask)
        x = out.last_hidden_state  # [1, T, H]
        mask = attention_mask.unsqueeze(-1).to(dtype=x.dtype)  # [1, T, 1]
        summed = (x * mask).sum(dim=1)
        count = mask.sum(dim=1).clamp(min=1e-9)
        mean = summed / count
        emb = F.normalize(mean, p=2, dim=1)  # [1, H]
        return emb.squeeze(0)  # [H]
```

> 转换阶段最容易踩坑的是 dtype/shape：  
> - input_ids/attention_mask 用 int32（PyTorch Embedding 支持 int32/long），避免 CoreML 不支持 int64。  
> - 固定 `T=512`（或后续做 query=128/passage=512 双模型优化）。

### 13.4 权重量化（W8 weight-only，coremltools 官方路径）

coremltools 官方的线性量化示例（W8）：

```python
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)

op_config = OpLinearQuantizerConfig(mode="linear", nbits=8)
config = OptimizationConfig(global_config=op_config)
quantized = linear_quantize_weights(mlmodel, config)
quantized.save("model.mlpackage")  # 或导出为 mlmodelc 的前置产物
```

> 量化是否带来速度收益必须实测；但体积收益通常确定。

### 13.5 产出 `model.mlmodelc.zip`

v1 推荐产出 `.mlmodelc` 后再 zip：

- 在构建机上 load/compile 一次，得到 `.mlmodelc/` 目录
- `zip -r model.mlmodelc.zip model.mlmodelc/`

然后把：

- `tokenizer.json` + `tokenizer_config.json` + `special_tokens_map.json`
- `manifest.json`
- `model.mlmodelc.zip`

一起打成最终发布 zip。

### 13.6 sha256 生成（zip 整体 + 每文件）

建议同时生成：

- 整体 zip sha256（catalog 用）
- 每文件 sha256（manifest 用）

示例（macOS）：

```bash
shasum -a 256 scopy-model-e5-multilingual-small-1.0.0.zip > scopy-model-e5-multilingual-small-1.0.0.sha256
shasum -a 256 tokenizer.json tokenizer_config.json special_tokens_map.json model.mlmodelc.zip
```

### 13.7 发布与回滚策略

- GitHub Release 中同时发布 zip 与 sha256
- App 侧 catalog 固定到某个版本（不自动追最新）：
  - 新版本模型要随 app 更新 catalog 才能被自动下载
- 回滚：
  - 保留旧模型目录
  - state.json 支持一键切回旧版本

---

## 14. 安全/隐私/发布 Checklist（必须做到的细节）

### 14.1 隐私（用户剪贴板数据）

- embedding 计算与索引完全本地
- index 文件可能间接泄漏文本信息（embedding 可被攻击推断）：
  - Settings 必须提供“一键删除语义索引”
  - 文档明确告知索引位置与清理方式

### 14.2 扩展加载安全（SQLite load_extension）

- 只允许加载 app bundle 内固定路径的 vectorlite dylib
- 只在加载时 enable load_extension，加载后立刻 disable
- 不要把 `load_extension()` 暴露成任何可注入的 SQL

### 14.3 模型包校验

- zip 整体 sha256（防下载损坏）
- manifest per-file sha256（防“解压后被篡改/替换”）
- 校验失败立即禁用模型并提示重装

### 14.4 codesign/notarize（vectorlite）

- 确保 vectorlite dylib 被签名、在 bundle 内、可通过 library validation
- Release 前用 `codesign --verify --deep --strict` 检查

### 14.5 性能回归门禁

- 新增 perf tests 用例后，至少在一台基准机跑出 P50/P95 并写入 `DEPLOYMENT.md`
- 若性能/部署变化，按仓库规范补齐 `doc/profiles/vX.Y-profile.md`（实现后做）

---

## 15. 参考资料（实现前必须读）

- E5 官方仓库与模型说明（prefix、pooling、维度）：  
  - https://github.com/microsoft/unilm/tree/master/e5  
  - https://huggingface.co/intfloat/multilingual-e5-small
- vectorlite（SQLite HNSW 扩展，限制/参数/示例）：  
  - https://github.com/1yefuwang1/vectorlite  
  - https://1yefuwang1.github.io/vectorlite/markdown/overview.html
- sqlite-vec（brute-force 向量扩展，pre-v1，许可证）：  
  - https://github.com/asg017/sqlite-vec
- sqlite-vss（Faiss 扩展，项目状态说明）：  
  - https://github.com/asg017/sqlite-vss
- coremltools 量化（Linear Quantization）：  
  - https://github.com/apple/coremltools/blob/main/docs/source/coremltools_optimize/linear_quantization.md
- SQLite 可加载扩展（load_extension / enable_load_extension）：  
  - https://www.sqlite.org/loadext.html
