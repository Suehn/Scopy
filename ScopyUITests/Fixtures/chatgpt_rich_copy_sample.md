# ChatGPT 富渲染 / 卡片 / 引用 / 搜索结果「实机样板间」

我查了当前 OpenAI 官方文档。先给一个关键结论：OpenAI 并没有公开一份“ChatGPT 所有 renderer / card type 的完整枚举表”。很多富 UI 是根据问题类型、数据源、客户端、套餐、地区、实验 rollout 和已连接 App 动态触发的。官方目前明确描述的包括：搜索引用和 Sources 面板、图片结果、实时天气/股票/体育/新闻等搜索结果、地点与餐厅、商品轮播和部分即时结账、Deep Research 报告、上传文件、以及 App 提供的交互式 cards / maps / playlists 等。(OpenAI Help Center)

Surface典型表现当前回答能否实机展示Web inline citation文末小引用，可点击，桌面可 hover✅External source link直接跳官方网页✅Sources panel回答底部聚合来源✅ 由客户端自动生成Search image result图片 + 原始来源✅News carousel多篇新闻卡片✅YouTube/video player内嵌视频播放器✅Stock chart股票价格、走势等✅Weather多日天气图表✅Currency实时汇率换算✅Product hero/card商品图片、价格、商家✅Product carousel多商品横向浏览✅Local business entity可点击地点/商家实体✅Interactive map地图 + 多个地点 pin✅Uploaded-file citations指向文件内容⚠️ 需要真实上传文件Generated file artifact可下载文件✅Deep Research reportTOC、来源、activity history需进入 Deep ResearchConnected App UIcard/map/playlist/custom UI取决于 AppRestaurant reservation地点详情 + Reserve条件触发Instant CheckoutChatGPT 内购买特定商品/商家官方搜索帮助页明确说明：搜索回答可能带 inline citations；桌面网页端可 hover 预览，点击可进入来源；回答下方还可能出现 Sources，其中会聚合引用和其他相关链接。搜索图片也可以点击查看其来源。(OpenAI Help Center)

打开：ChatGPT Search 官方帮助中心

打开：OpenAI 最初的 ChatGPT Search 产品介绍

打开：Apps in ChatGPT 官方说明

# 1. 原生网页引用：这一段本身就是实际示范

例如，OpenAI 官方说明，ChatGPT Search 会针对需要最新信息的问题搜索网络，搜索结果可以带来源链接；其最初发布时明确列举了 Weather、Stocks、Sports、News、Maps 等信息类型。(OpenAI)

这里的 `` 不是普通 Markdown 链接，而是客户端认识的原生来源引用对象。你实际看到的应该是一个紧凑引用标记；桌面网页端可以进行 hover/click 交互。(OpenAI Help Center)

这又是一个多个来源共同支持同一段话的例子：Deep Research 可以使用公共 Web、上传的文件和已连接应用，最后生成有 citations/source links 的结构化报告；完成后的全屏报告还带目录、Sources Used 和 activity history，并可导出 Markdown、Word、PDF。(OpenAI Help Center)

# 2. 搜索结果图片：原生图片组

下面不是我用 Markdown 放的 <img>，而是搜索来源图片：

这两张来自 OpenAI 的 ChatGPT Search 介绍页面。官方也明确说明搜索回答有时会直接在回答顶部显示图片，点击图片可查看 citation 和来源。(OpenAI Help Center)

# 3. 新闻：真正的内嵌 News Carousel

当前 OpenAI 新闻中，最近几天包括 8 月 26 日的 Hugging Face 安全事件说明、8 月 25 日的 Jalapeño 推理芯片测试结果，以及 8 月 24 日 GPT-5.6 在 Kiro 中的发布。(OpenAI)

- OpenAI
- OpenAI
- OpenAI
这和普通 Markdown：

- 新闻 A - 新闻 B - 新闻 C完全不是一回事。上面是客户端能够认识的 news source objects → news carousel UI。

# 4. 视频：内嵌播放器

OpenAI 官方 YouTube 在 2024 年专门做过一次 ChatGPT Search 演示：

OpenAI — Search: 12 Days of OpenAI, Day 8

如果客户端完整支持这一 surface，你看到的应该不是普通 YouTube URL，而是视频播放器/预览卡。

# 5. 股票：实时金融卡片

为了实际测试股票 surface，这里用 NVDA。Reuters 今天报道 Nvidia 强劲的收入展望重新强化了市场对 AI 基础设施需求的预期，并推动 Nvidia 及其他芯片股上涨。(Reuters)

这个 surface 与写一张：

NVDAPriceNVIDIA$xxx.xx的 Markdown table 本质不同：前者可以携带市场数据语义、走势视图、ticker identity 和时间序列交互。

# 6. 天气：真正的数据型交互卡片

这里故意用旧金山，仅用于展示这种渲染形式，不代表我在推断你的位置。

当天湾区受到前热带风暴 Iselle 的水汽影响，出现了较少见的 8 月降雨可能和更多云层。(San Francisco Chronicle)

你可以观察这里和普通 Markdown table 的区别：通常包含单位切换、日预报、温度图等专用布局。

官方 Search Help 对公开产品的描述目前明确提到移动端相关搜索结果可能出现地图；不同 rich surface 在 Web/mobile 的 rollout 并不一定完全相同。(OpenAI Help Center)

# 7. 汇率：交互式 converter

这里直接实例化 100 USD → CNY：

这种数据卡对应的不是纯文本：

$100\ \mathrm{USD}\times r = x\ \mathrm{CNY}$而是一个带货币 identity、实时 rate 和交互输入的专用数据 surface。

# 8. Shopping：单商品 Hero Card

OpenAI 官方现在明确说明，ChatGPT Search 遇到购物意图时可以展示商品图片、产品信息、商家链接；符合条件的商家/商品甚至可能出现 Instant Checkout。产品结果和广告是分开的。(OpenAI Help Center)

下面先看单个商品卡：

### Logitech MX Master 3S

$79.99

这里的价格、商家、图片等不是我手工画 Markdown 表格，而来自结构化 product entity。

# 9. Shopping：横向 Product Carousel

再换成多商品浏览：

### Keychron Q1 Max

$209.99

### Sony WH-1000XM6

$398.00

官方文档直接使用了 carousel 这个概念，并说明智能购物还可以产生并排比较、结构化属性、可滚动的附加商品集合。(OpenAI Help Center)

这也意味着 ChatGPT 的回答渲染树并不只是：

paragraph heading list table code而会存在类似：

ProductEntity ProductHero ProductCarousel MerchantOffer这样的语义型 UI 对象。

# 10. 本地商家实体：可点击 Entity

以下三个名称本身是结构化本地实体，不是普通文字：

Blue Bottle Coffee

Blue Bottle Coffee Web Address: 315 Linden St, San Francisco, CA 94102, United States Phone: +1 510-661-3510

Sightglass Coffee

Sightglass Coffee Web Address: 270 7th St, San Francisco, CA 94103, United States Phone: +1 415-463-1673

Four Barrel Coffee

Four Barrel Coffee Web Address: 375 Valencia St, San Francisco, CA 94103, United States Phone: +1 415-935-0604

这类对象可以带地点 identity、地址、营业时间、评级等结构化信息，而正文无需全部展开。

官方 Search Help 还明确描述了餐厅的特殊情况：网页搜索中的部分餐厅名称可以点击进入地点详情；支持的餐厅可能出现 Reserve，并进入第三方预订流程。(OpenAI Help Center)

# 11. 地图：同一批实体直接进入 Map Surface

这是一个尤其明显的例子：

| Name | Address | |---|---| | A | xxx | | B | xxx |和“地图对象”在信息上可能相同，但renderer 完全不同。

# 12. 普通网页超链接 vs 原生 Source Citation

### A. Citation

OpenAI 说明，Apps 可以把第三方工具和数据带入 ChatGPT；不同 App 可以进行搜索、引用内容、执行动作、Deep Research、同步数据，某些还会直接提供 interactive cards、maps 或 playlists。(OpenAI Help Center)

### B. 可导航的外部链接

Apps in ChatGPT — OpenAI Help Center

Shopping with ChatGPT Search — OpenAI Help Center

Deep Research — OpenAI Help Center

视觉上，citation 更偏“这句话的证据是什么”，而 URL link 更偏“我要直接去这个页面”。

# 13. Connected Apps / Plugins：还有一整层 UI 不是 Web Search 的一部分

这是 2026 年尤其重要的一层。OpenAI 当前官方文档说明，App Directory 已经迁移进 Plugin Directory；Plugin 可以包含 apps、skills 和 app templates。Apps 本身能够连接外部数据和动作，有些可以在聊天中直接展示interactive cards、maps、playlists。(OpenAI Help Center)

例如理论上的渲染路径可能是：

User query │ ├── Web Search │ ├── citation │ ├── news │ ├── images │ └── structured web entity │ ├── Plugin / App │ ├── app card │ ├── map │ ├── playlist │ ├── custom interactive UI │ └── action confirmation │ ├── Uploaded / Connected File │ ├── file reference │ └── source-backed answer │ └── Specialized source ├── stock chart ├── weather ├── currency ├── products └── places所以你说“网页版应该有超级多格式”是对的；很多不是 Markdown parser 的能力，而是回答中的结构化对象由 ChatGPT 客户端选择不同 renderer。

# 14. 文件 Artifact：实际可下载文件

我专门生成了一个实际文件，方便看文件附件/下载链接这一层：

chatgpt_render_reference_demo.txt

这是 artifact/file link，和 Web URL 又是不同的一类引用目标：目标不是 https://...，而是这次会话沙箱里生成的附件。

OpenAI 官方文件能力目前支持对 PDF、演示文稿、纯文本等文件进行总结、抽取、比较等处理。(OpenAI Help Center)

# 15. 真正的“文件内容引用”为什么我这一条没有伪造

这一点值得单独区分。

当前对话在你发这条消息以前没有上传任何文件。我刚才生成的 .txt 是输出 artifact，但没有被文件检索层重新注册成一个可进行逐行 source citation 的输入文件。因此我不会伪造一个不存在的：

[file citation → 第 23–31 行]真实有一个用户上传 PDF / Markdown / DOCX，或者一个连接的数据源文件时，我可以产生另一种 native citation，直接指向文件中的相关段落/行/页。

这又和：

[下载文件](...)不是同一个概念。

# 16. Deep Research 还有单独的“报告渲染器”

Deep Research 的输出并不只是“回答特别长”。

OpenAI 当前官方说明，完成后的研究会打开一个专门的全屏 report view，里面包括：

报告级元素作用Table of contents长报告跳转Inline citations / source links证据Sources used集中核查来源Activity history查看研究过程DownloadMarkdown / Word / PDF(OpenAI Help Center)

因此这已经是“document/report application UI”，而不是 Markdown document renderer。

# 17. Search 本身也不只有蓝色链接

OpenAI 当前的 Search 文档至少公开描述了这些结果形式：

inline citation → Sources panel → images → location-aware results → restaurant entities → Reserve flow。官方最初发布 Search 时则特别展示/提到 weather、stocks、sports、news、maps。(OpenAI Help Center)

再结合购物：

product images → product details → merchant links → carousel → Instant Checkout。(OpenAI Help Center)

再结合 Apps：

interactive cards → maps → playlists → custom data/actions。(OpenAI Help Center)

因此比较准确的理解不是：

$\text{ChatGPT output}=\text{Markdown string}$而更接近：

$\text{ChatGPT response} = \text{Text AST} + \text{Math} + \text{Citations} + \text{Entities} + \text{Rich UI Objects} + \text{Artifacts} + \text{App-specific UI}.$甚至可以抽象成：

type ResponseNode = | MarkdownBlock | MathBlock | Citation | ExternalLink | ImageGroup | Video | NewsCollection | StockChart | WeatherCard | CurrencyConverter | ProductEntity | ProductHero | ProductCarousel | LocalBusinessEntity | Map | FileArtifact | FileCitation | AppInteractiveView | ActionConfirmation | SpecializedReport;这当然不是 OpenAI 公布的内部 TypeScript 定义，只是从目前公开和可实际触发的 surface 抽象出来的 mental model。

## 当前这一条回复里，实际已经同时塞进了这些不同 renderer

#实际对象本回答是否真的使用1Markdown heading✅2Markdown table✅3fenced code✅4LaTeX✅5web inline citation✅6external URL object✅7search image carousel✅8news carousel✅9video player✅10stock chart✅11weather forecast✅12currency converter✅13product hero card✅14product carousel✅15local-business entity✅16interactive map✅17generated file artifact✅18true uploaded-file inline citation— 当前无输入文件19Deep Research full-screen report— 需要进入对应模式20arbitrary third-party App custom UI— 需要具体 App所以这一条已经比上一条的“Markdown 压测”多跨了好几层：Markdown renderer、citation renderer、Web Search renderer、news/media renderer、financial/data renderer、commerce renderer、local-search renderer、map renderer、artifact renderer 都混在同一条回答里了。

如果你下一条随便上传一个 PDF、Word、Markdown、CSV 或 PPTX，我可以继续做第二轮，专门把 文件卡片、文件内容引用、页码引用、表格/图片提取、生成的新文件 artifact 与 Web 来源 citation 混在同一条回复里，那基本就能把“文件侧”的渲染也补齐。