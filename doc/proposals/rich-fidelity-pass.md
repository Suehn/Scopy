---
doc_type: proposal
status: implemented
owner: hh
created: 2026-08-29
implemented: 2026-08-29 (by the reviewing architect; see 实现记录 at the end)
audience: implementing agent (Codex/GPT) + maintainer review
---

# 富渲染保真第二波（Rich Fidelity Pass）

用户观感：硬化门槛落地后，富渲染卡片仍"不像官网"。本方案由架构审查亲自完成三方对照——①用户发给 Codex 的 5 张 ChatGPT 桌面实景截图（`~/.codex/attachments/`，2026-08-28 14:40–15:56，下称"参考截图"）、②WACZ 三个提取目录（含官方天气图标 PNG 与 4K hydrated 视口截图）、③当前构建的真实导出（`chatgpt_rich_surfaces.md` → 1080×6029，直接启动 app 二进制导出）——并把差距定位到常量/CSS 行级。结论：**三个根因，一个是结构性的，两个是观感性的**；全部有手术单。

证据分级补充：参考截图是用户自己捕获的 ChatGPT 桌面完成态实景，按契约归为 `live/runtime-derived` 视觉参考——可以据其定颜色、比例与布局意图，但取值需注明"取样自参考截图"。

## 0. 三个根因

### R1（结构性，最高杠杆）：默认渲染的是 40rem 窄态，参考全是 48rem 宽态

证据链，每一环都已核实：

1. 契约明文：*"the current 816px output surface reaches the 48rem state"*（`markdown-chatgpt-wacz-style-contract.md` Rich thread 行）。
2. 代码却是：`MarkdownRenderLayoutConstants.chatGPTWideThreadMinimumViewportWidth = 856`（`Scopy/Services/Export/MarkdownRenderLayoutConstants.swift:70`），816 < 856 ⇒ `threadContentWidth(816) = 640`。**契约与代码矛盾，代码把 100% 缩放锁死在窄态。**
3. 像素证据（当前导出实测）：新闻卡宽 ≈245pt = `--scopy-rich-news-card-ideal-width: 15.33rem`（builder :349，窄态固定宽），容器 640pt 居中 ⇒ 3×245+2×16=767 > 640 ⇒ **第三张新闻卡被裁**（导出把可滚动轨道冻结在 offset 0）；`@container (min-width: 48rem)` 的三等分规则（builder :1215）从未激活。
4. 同族症状：天气 8 天条第 8 天被裁、小时图右缘被裁；金融 metrics `minmax(12rem,1fr)` 在 640−40=600 容器只排出 **2 列**（参考为 3 列；768 宽态下 728≥3×192+64 恰好 3 列）。

参考截图全部来自 ChatGPT 桌面（窗口远宽于 53.5rem ⇒ 恒为 48rem 态）。Scopy 默认给用户看的却是移动端式窄态——这就是"整体不像"的主感来源。

**D1 手术单**：
- `chatGPTWideThreadMinimumViewportWidth: 856 → 816`。语义：100% 及更小缩放（逻辑视口 ≥816）= 48rem 宽态；放大（>100%，视口 <816）= 40rem 窄态（放大阅读 = 窄栏，合理且与 CQ 语义一致）。
- 契约 Rich thread 行同步措辞（816 输出面 = 宽态；两态阈值 816）；`ChatGPTMarkdownRendererTests` 钉两条：`threadContentWidth(816)==768`、`threadContentWidth(816/1.25)==640`。
- 验收（像素级）：直接导出 rich fixture @100%——三张新闻卡完整无裁切、天气 8 天完整、小时图不裁右缘、metrics 3 列；@125% 保持窄态行为（轨道局部滚动是契约行为，文档注明导出冻结于 offset 0）。
- 禁止顺手改：输出面 816、导出 1080 映射、`15.33rem` 窄态 ideal 宽（窄态仍需要它）。

### R2（观感性）：色彩语义缺失——参考卡片是有颜色的，Scopy 几乎全灰

逐卡对照结果：

| Surface | 参考截图（ChatGPT 实景） | Scopy 当前 | 差距编号 |
| --- | --- | --- | --- |
| 金融图表 | **饱和绿**折线 + 绿→透明渐变填充（涨日）；涨跌行绿色 `+US$9.79 (1.38%)`；盘后跌幅**红色** | 灰绿寡淡折线、灰填充；涨跌行与盘后行均灰/黑 | F-1/F-2 |
| 天气日条图标 | 每天**彩色**图标（白云+橙日、蓝雨滴；源自 `persistent.oaistatic.com/sonic_sa_weather_light_*`，其中两张已被 WACZ 捕获且**恰是 Scopy 已打包的两张 PNG**） | 除命中打包 PNG 的条件外全部灰色单色兜底 SVG，且偏小 | W-2 |
| 天气选中日 | **淡蓝**圆角底（≈#EAF2FD 取样） | 灰底 | W-3 |
| 天气小时图 | 黑线 + **暖桃色**渐变填充 | 黑线 + 灰填充 | W-5 |

**D2 手术单（色 token 化，全部走 baseStyle 单点定义）**：
- 新增 rich 色 tokens：`--scopy-rich-positive` / `--scopy-rich-negative` / `--scopy-rich-weather-selected-bg` / `--scopy-rich-weather-chart-fill` / `--scopy-rich-finance-fill-*`。数值从参考截图取样定案（绿 ≈ #0E9F6E 档、红 ≈ #E02E2A 档、选中蓝 ≈ #EAF2FD、暖填充 ≈ #F7E9D9→透明），提交时在契约记录"取样自 2026-08-28 参考截图（live/runtime-derived）"。
- 金融：折线、渐变填充、涨跌行、盘后行全部按该行 `trend`/符号着色；换 range 时随所选 series 的 trend 切色。零值/`—` 保持中性色。
- 天气：选中日底色、`aria-selected` 同步；小时图填充换暖渐变。
- 导出与预览同 DOM 同 CSS，无导出特调。

**D3 手术单（天气彩色图标集）**：为 v2 `icon`/`condition` 枚举补一套**封闭、确定性、本地彩色 SVG**（白云 + 橙日 + 蓝雨滴风格，以两张已捕获官方 PNG 为风格锚；这两个条件继续用捕获 PNG 原件）。尺寸对齐参考（日条内 ≈28px）。标注为 Scopy stability adaptation（官方全集未被归档，不冒充捕获资产）；禁止运行时取网、禁止 emoji 替代。

### R3（观感性）：比例与密度——参考更大、更透气

| Surface | 参考 | Scopy 当前 | 手术单 |
| --- | --- | --- | --- |
| 汇率卡金额 | ≈34px 大数字，行高充裕（每行区 ≈88pt），symbol 次级灰、略小 | ≈24px，行紧 | **D4**：金额 32px/权重 600/tabular；行区上下 padding 提到参考比例；symbol `0.6em` 次级色、与数字基线对齐；分隔线保持贯通。 |
| 金融 metrics 顺序 | 3 列 row-major：打开·交易量·市值 / 当日最低价·年度最低价·每股收益 / 当日最高价·年度最高价·市盈率 | 数据序不同 ⇒ 网格错位感 | **D5**：改 **fixture 数据顺序**为上述序（渲染器按 payload 序填充是正确行为，不改代码）；文档注明 producer 建议序。 |
| 引用 pill 图标 | 站点 favicon（OpenAI/SF Chronicle/investing 实图） | 一律 globe | **D6（推荐）**：新增**封闭 host→已打包 favicon 映射**（仅现有 4 个 favicon 资产：openai/help-openai/investing/reuters 对应的精确 host），命中才用，其余保持 globe；绝不抓取。契约"Ordinary links do not fetch or guess favicons"段同步为"…may use only an exact-host entry from the closed bundled favicon map"。 |

### R4（观感性）：Codex 文件链接图标——分类已同构，输在光学质量

用户观感"图标不如 Codex"。对照 Codex 参考截图（`~/.codex/attachments/e95382ee-*/`：.md→文档图标、.js→JS 徽章、.html→`</>` 代码图标、.png→图片图标）与 Scopy 现状：

- **自适应机制本身 Scopy 已经实现且同构**（回答"Codex 是怎么做的"：就是扩展名→类型→图标的封闭映射，无网络无魔法）：`render.js` `localFileKind()` 按扩展名分四类——document（md/markdown/txt/rtf）、javascript（js/jsx/mjs/cjs）、image（png/jpg/…7 种）、code（swift/html/css/json/py/ts/… ~24 种），兜底 document；每类映射到 `scopyIcons.js` 的 Phosphor 图标。分类广度不输参考。
- **差距全在视觉呈现**：①Phosphor 256 网格字形自带 ~13% 内边距 ⇒ 同为 1em 盒时**光学上小一圈**（Codex 图标满格、更醒目）；②`javascript-badge` 为描边风格，参考是**实心圆角方块 + "JS" 字**的徽章；③图标与 label 间距偏紧（视觉 ~4px，参考 ~6–8px）；④基线 `-0.125em` 在徽章类图标上显得偏高。

**D7 手术单（光学校准，闭集内改，不加图标依赖）**：
1. 图标盒 1em 不动，`scopyIcons.js` 内对文件类图标做**满格化**：路径按 256 网格重排至 ~4% 边距（或统一加 `transform: scale(1.13)` 于 `.scopy-link .scopy-icon`——二选一，推荐改路径保持单一来源）。
2. `javascript-badge` 重绘为实心圆角方块 + 镂空 "JS"（对齐参考风格），保持 currentColor 单色、精确路径入闭集。
3. `.scopy-link__label` 前间距定 6px；徽章类图标 `vertical-align` 单独校到与文字 cap 对齐。
4. 验收：与参考截图 200% 并排目检四种链接（md/js/html/png 各一条），图标醒目度、对齐、间距一致；Node `scopy-icons.test.js` 更新路径哈希断言。
5. 不做：按语言出彩色徽章、TS/PY 等新徽章（参考只证明了 JS 徽章）、图标字体或运行时图标库。

## 1. 明确不做（本波次）

- "Give feedback"、消息操作栏（复制/分享/刷新）：消息级 chrome，不属于 Markdown 文档，参考截图中它们在卡片之外。
- YouTube/视频卡、地图卡、商品卡：v2 不支持类型（WACZ 里有 mapbox/yt 流量不构成实现义务）。
- favicon/图标网络抓取；官方图标全集仿冒为"捕获资产"。
- 新闻卡 hover 效果等纯交互态修饰（导出不可见，另立小项可选）。

## 2. 执行顺序与验收

1. **D1**（先做，单独提交）：常量 + 契约 + 两条 pinned 测试 → 直接导出 rich fixture @100%/@125% 各一张，@100% 逐项核对：新闻 3 卡完整、天气 8 天完整、小时图完整、metrics 3 列。
2. **D2+D3**（一次提交）：tokens + 着色 + 图标集 → Node 测试钉：finance 涨/跌/平三种 series 的类名或 style 断言、weather 选中日类名、图标集对每个 condition 输出确定 SVG；导出对照参考截图目检（金融绿线、盘后红、天气彩色图标、选中蓝）。
3. **D4+D5+D6+D7**：汇率比例 + fixture 序 + favicon 映射 + 链接图标光学校准 → 同法目检 + Node 断言（favicon 仅精确 host 命中；图标路径哈希更新）。
4. 全量回归：`npm test && npm run build && npm run verify:assets`、`make build && make test-unit && make test-strict`、rich/公共拷贝/stress 三张直接导出与既有证据对照，全部收档 `artifacts/render-validation/`。
5. 文档：契约（宽度态、色 token 取样来源、favicon 映射、图标集标注）、`doc/current/development-guide.md` 第 16 条补一句色彩/图标属 token 单点定义。

护栏重申：所有取值走 `--scopy-*` token 单点定义（禁止组件内裸色值）；两态（640/768）都必须有断言；fail-closed 不变（未知 condition → 现有中性兜底图标；未知 host → globe）；不引入任何网络路径。

## 3. 实现记录（2026-08-29）

实施前先做了逐像素取样核查，**修正了本方案 R2 的一处误判**：对参考截图取样显示，金融涨行绿 `rgb(44,103,50)`、折线绿 `rgb(73,160,76)`、盘后红 `rgb(250,66,62)`、天气选中日底 `rgb(240,247,253)` 与 Scopy 现值（`rgb(38,112,46)` / `rgb(75,158,83)` / `rgb(239,65,70)` / `rgba(140,195,235,0.13)` 合成后）全部在噪声内一致——"全灰"是窄态挤压下的观感错觉，不是色值缺陷。据此 D2 收敛为"色值收单点"（值不动），D3（自绘天气图标集）取消：v2 schema 的 `icon` 本就是 asset 引用而非 condition 枚举，且日条图标已是捕获的官方 PNG（28px 符合参考比例）。

实际落地：

- **D1**：`chatGPTWideThreadMinimumViewportWidth = chatGPTOutputSurfaceWidth`（856→816），附注释；`testThreadWidthUsesLogicalLayoutViewportThreshold` 更新为 815.999/816 边界 + 125% 反例 + 常量恒等断言；契约 Rich thread 行同步两态语义。
- **D2**：新增 token `--scopy-rich-trend-up-text/-up-stroke/-down/--scopy-rich-weather-chart-warm`（值=原值，注明取样来源）；金融涨跌行/盘后行/图表颜色与汇率非法输入色全部改引 token；`renderChartGradient` 去掉颜色参数、stop 改 `currentColor`（天气图表 figure 设 `color: var(--scopy-rich-weather-chart-warm)` 供渐变继承，线与文字保持显式色）——图表配色自此单点定义于 baseStyle。
- **D4**：汇率输入 `font-weight: 500` + `font-variant-numeric: tabular-nums`（尺寸经测量与参考一致，未改）。
- **D5**：`chatgpt_rich_surfaces.md` metrics 改为参考行序（打开/交易量/市值 · 当日最低/年度最低/每股收益 · 当日最高/年度最高/市盈率）。
- **D6**：`scopyLocalImageAssets.js` 新增 `CITATION_FAVICON_HOSTS`（7 个精确 host → 4 个已打包 favicon）与 `bundledFaviconAssetForCitationHost`；`citationOriginIcon(url)` 命中才渲 `<img src="rich/favicon-*">`，否则 globe；新增 CSS `img.scopy-source-citation-favicon`；契约与开发指南第 14 条同步；新增 Node 测试（命中/未命中/绝不远程）+ 公共拷贝 fixture 断言（favicon>0 且所有带 src 图均为本地资产，放过无 src 的 lightbox 延迟占位）。
- **D7**：`a.scopy-link--file .scopy-file-icon { transform: scale(1.15) }` 光学补偿（作用于 svg 元素整体、无内部裁剪、不改授权路径数据），附注释；JS 徽章实心重绘按方案记为可选未做。
- 验证：Node 100/100；`npm run build` + `verify:assets` 通过（renderer `11727ec7…`）；Swift 构建/单测/导出验证见 runbook 与本会话记录。
