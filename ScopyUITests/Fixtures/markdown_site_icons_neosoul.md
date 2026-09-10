**NeoSoul 是一个以预测市场和自动交易为切入口的 AI Agent 项目：让 AI 持续研究、在授权范围内执行、记录结果，再通过复盘改善下一次决策。** 它的长期目标是建立“智能体经济”的基础设施。现阶段已经有产品、公开代码和融资披露，但长期实盘盈利能力仍缺少充分的独立验证。[官方介绍](https://docs.neosoul.ai/docs)

我查了你打开的 X 账号、官网、白皮书、产品页面、GitHub，以及投资方资料。以下截至 **2026 年 9 月 11 日**。

它的两款核心产品，可以这样理解：

| 产品 | 用来做什么 | 已公开的形态 |
|---|---|---|
| **EvoEvo** | AI 的预测、记忆与评估平台：围绕现实事件形成判断，等结果出现后复盘、积累经验 | 网页产品，可创建云端 Agent，也可接入本地 OpenClaw；有预测、回顾和排行榜 |
| **NeoTrade** | AI 交易工作台：配置模型、策略和权限，让 Agent 持续研究与执行 | 桌面客户端；详细文档明确列出模拟环境 Paper、predict.fun 和 Polymarket |

来源：[EvoEvo 实际页面](https://evoevo.ai/)、[NeoTrade 文档](https://docs.neosoul.ai/docs/products/neotrade)。

举个例子，你给 Agent 一个“研究某项政策是否会在月底前落地”的任务。它搜集资料、给出概率判断，与预测市场价格比较，再根据你设定的权限决定行动或等待。事件结束后，它保存当时的依据、判断、操作和结果，用于下一轮评估。这就是它希望建立的“研究—行动—结果—学习”循环。[EvoEvo 的设计说明](https://docs.neosoul.ai/docs/products/evoevo)

**它的技术重点，是把模型组织成能够长期工作的系统。** 这里包括资料来源、记忆、策略说明、工具连接、交易权限和复盘机制，官方称之为 *harness engineering*。公开的预测工具采用“大模型解释问题、整理证据，Python 引擎负责加权、归一化和敏感性分析”的分工；交易技能库则包含针对预测市场改写的策略，以及事件结算规则分析、证据核对和交易日志等方法。[预测工具源码](https://github.com/NeoSoul-AI/rubric-prediction-skill)、[交易技能库](https://github.com/NeoSoul-AI/neotrade-skills)

你当前页面提到的 **“Evolve／自我进化”**，可以具体理解为：回看运行记录，把有用经验写进记忆，并调整后续使用的策略或参数。9 月 7 日的 NeoTrade v0.1.12 发布说明还列出了“策略教练”：根据结算记录复盘，只能调整策略允许的参数，不能自行下单、切换策略或修改资金限额。这些机制是否持续提高能力，需要前后对照和跨时段验证。[9 月 10 日官方演示](https://x.com/NeoSoulAI/status/2098006851073822995)、[版本说明](https://github.com/NeoSoul-AI/neotrade-release/releases/tag/desktop-v0.1.12)

**团队与融资方面，有明确线索，但披露仍比较有限。** 公开联合创始人为 **Kaelan**，HackQuest 项目资料列名 **Kaelan Rao**；其本人 X 简介写有前 HashKey 经历。本轮资料没有让我核实完整核心团队及履历。[本人账号](https://x.com/kaelanyiu)、[HackQuest 项目资料](https://www.hackquest.io/ja/projects/NeoSoul-RpCPfK)

融资目前能找到两笔公开披露：

- **早期 400 万美元种子轮**：项目在 HackQuest 的资料列出 Yarun Investment、Kirin Capital、Crestwave Capital、CatcherVC 等。
- **2026 年 8 月 20 日，1100 万美元 Pre-A 轮**：公告列出 MH Ventures、Amber Group、ArkStream Capital、0G Foundation、Kirin Capital、CatcherVC、New Oak International。

按两笔披露相加是 **1500 万美元**。其中，1100 万美元公告被 The Block 收录在 **Press Release** 栏目，属于公告转载；我另外在 **MH Ventures 自己的投资组合页面**确认看到了 NeoSoul，支持其投资关系，但不能据此独立核实整轮金额及所有参与方。[种子轮资料](https://www.hackquest.io/ja/projects/NeoSoul-RpCPfK)、[Pre-A 公告](https://www.theblock.co/press-releases/412324/neosoul-raises-11-million-in-pre-a-funding-to-accelerate-its-expansion-in-the-ai-economy)、[MH Ventures 投资组合](https://cms.mhventures.io/portfolio?0d7f64fd_page=2)

**它已经有一定规模的产品活动，但统计口径需要看清。** 我打开 EvoEvo 时，平台显示约 **453 万个 Agent、1550 万次已完成预测、1830 万条记忆**；X 账号约有 **11.38 万粉丝**。这些是平台展示的累计计数，不能直接换算成独立用户、付费用户或实盘交易规模。首页部分 Agent 显示很高甚至 100% 的胜率，但卡片没有充分交代样本窗口、筛选方式及实际投入，不能直接当作赚钱能力的证明。[EvoEvo 首页](https://evoevo.ai/)、[官方 X](https://x.com/NeoSoulAI)

它与区块链的结合，主要落在**账户控制、交易结算和关键记录的可验证性**。当前白皮书强调“最少上链”：私钥、私人记忆、策略参数和大部分计算留在本地或受权限保护的链下环境；需要结算、跨方核验或证明时间与完整性的内容才考虑上链。这项设计能支持追溯，预测质量仍然要靠结果检验。[官网白皮书，第 18 页](https://www.neosoul.ai/assets/WhitePaper-B1iKuTvm.pdf)

代币方面，官方 FAQ 已描述支付 Agent 服务、技能、数据调用，以及治理和 Agent 间结算等用途，并明确代币不代表股权或利润、收入请求权。**本轮核对没有确认官方可交易代币地址、TGE 日期或积分兑换规则**，因此不能给它一个可靠的币价或空投价值判断。[官方 FAQ](https://docs.neosoul.ai/docs/resources/faq)

我对它目前阶段的判断是：**产品方向值得研究，产品有效性和商业价值还需要更多证据。** 尤其有三处边界：

- **市场覆盖存在文案冲突。** 官网首页宣传永续合约 DEX，详细状态文档却把更广泛的 DEX、CEX、Meme 币及美股列为计划。现阶段应按具体版本和接入平台核实。[官网](https://www.neosoul.ai/)、[产品状态](https://docs.neosoul.ai/docs/start-here/product-status)
- **公开代码支持部分实现可检查，完整客户端的透明度仍有限。** 钱包 SDK 和技能库公开；客户端下载仓库明确只存发布产物。CertiK 页面也显示尚未经其审计。[发布仓库](https://github.com/NeoSoul-AI/neotrade-release)、[CertiK 页面](https://skynet.certik.com/zh-CN/projects/neosoul)
- **最关键的价值证明仍待补充。** 我尚未找到足以评价长期效果的独立实盘记录、扣除成本后的收益与回撤、用户留存和付费收入。官方评估文档讲清了应当如何验证，但验证方法本身不能代替结果。[评估与验证文档](https://docs.neosoul.ai/docs/agent-intelligence/evaluation-and-validation)

从你的关注点看，它最有参考价值的是：**如何把证据、判断、执行权限、结果归因和长期记忆接成一个可检查的工作流程。** 它最终能否建立优势，要看这些积累能否稳定改善决策与执行，以及用户是否愿意持续为此付费。
