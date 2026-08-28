# ChatGPT Rich Surfaces Contract Fixture

> Evidence boundary: the 2026-08-28 WACZ archives prove captured runtime paths, saved text, selected structured response fields, and bundled response bytes only. They do not contain a final hydrated assistant DOM or computed-style snapshot. Live Microsoft Edge observations and deterministic Scopy fixture values are labeled separately below; none is presented as a recovered final DIL payload.

## External links and Codex file-link semantics

- [社区版 OpenCode](https://github.com/anomalyco/opencode)：开源 coding agent 与桌面应用。
- [OpenAI Codex 开源仓库](https://github.com/openai/codex)：CLI、TUI 与 App Server 源码。
- [Codex TUI Markdown 渲染器](https://github.com/openai/codex/blob/main/codex-rs/tui/src/markdown_render.rs)：终端 Markdown 的实际实现。
- [Scopy renderer source](/Users/hh/Documents/code/Scopy/Tools/MarkdownRenderer/src/render.js:1)：Codex 风格的绝对本地路径与一基行号后缀。

The HTTP(S) destinations are ordinary outbound links. The absolute local path is preserved as a local Markdown destination, including its `:1` line suffix; it receives a file-kind icon rather than an external-link arrow and is never promoted to a source citation. Only an explicit preview click may hand that validated absolute path and line suffix to the native workspace opener; static export freezes links and controls.

## Inline source citation with real destinations

QQQ（Invesco QQQ Trust）最新常规交易价格为 **US$721.11**，当日上涨 **US$9.79（+1.38%）**；日内区间约 **US$714.54–US$721.40**。([investing.com][qqq-investing], [Google Finance][qqq-google])

[qqq-investing]: https://www.investing.com/etfs/powershares-qqqq "Investing.com QQQ ETF page"
[qqq-google]: https://www.google.com/finance/quote/QQQ:NASDAQ "Google Finance QQQ quote"

The saved text preserves the QQQ prose and an `investing.com +1` label. The supporting Google Finance destination is an explicit real fixture URL, not a recovered private ChatGPT attribution. Scopy may promote this parenthesized, source-like HTTP(S) group to one primary citation plus one concrete supporting source; an ordinary parenthesized local file link or generic `[guide]` link must remain ordinary.

## Public Copy degradation: news becomes ordinary links

- [OpenAI](https://openai.com/index/hugging-face-incident-and-the-road-ahead/)
- [OpenAI](https://openai.com/index/jalapeno-first-results/)
- [OpenAI](https://openai.com/index/gpt-5-6-in-kiro/)

The public Copy action loses article titles, dates, thumbnails, and private navigation metadata. Scopy must not reconstruct a card from these links alone.

## WACZ structured search-result fields mapped to strict v2 news

The secondary WACZ preserves a complete `search_result_group` with the following titles, URLs, publication timestamps, source attribution, thumbnail URLs, and thumbnail response bytes. The objects are not literally a `news` payload. This strict v2 fixture maps those frozen visual fields, presents the captured OpenAI identity and timestamps using the reference-visible `OpenAI` / relative-date labels, and uses the already-copied local asset IDs; it does not claim that linked article bodies were archived.

~~~scopy-rich
{
  "version": 2,
  "type": "news",
  "title": "OpenAI latest results",
  "state": "ready",
  "message": "Three frozen visual results mapped from messages[17].metadata.search_result_groups[0].",
  "source": "2026-08-28 secondary WACZ search_result_group",
  "asOf": "2026-08-28 archive capture",
  "items": [
    {
      "title": "The Hugging Face incident and the road ahead",
      "url": "https://openai.com/index/hugging-face-incident-and-the-road-ahead/",
      "source": "OpenAI",
      "date": "Yesterday",
      "image": { "asset": "news-openai-hugging-face", "alt": "The Hugging Face incident and the road ahead thumbnail" },
      "favicon": { "asset": "favicon-openai-32", "alt": "OpenAI" }
    },
    {
      "title": "Jalapeño’s first results show industry-leading speed and efficiency in AI inference",
      "url": "https://openai.com/index/jalapeno-first-results/",
      "source": "OpenAI",
      "date": "2 days ago",
      "image": { "asset": "news-openai-jalapeno", "alt": "Jalapeño inference results thumbnail" },
      "favicon": { "asset": "favicon-openai-32", "alt": "OpenAI" }
    },
    {
      "title": "Advancing price-performance for developers with GPT‑5.6 in Kiro",
      "url": "https://openai.com/index/gpt-5-6-in-kiro/",
      "source": "OpenAI",
      "date": "3 days ago",
      "image": { "asset": "news-openai-kiro", "alt": "GPT-5.6 in Kiro thumbnail" },
      "favicon": { "asset": "favicon-openai-32", "alt": "OpenAI" }
    }
  ]
}
~~~

## Captured local v2 image-group assets

Public Copy retained two remote image URLs, but Scopy never fetches them during offline rendering. This visual fixture therefore uses the corresponding WACZ response bytes through closed local asset IDs, with real images, lightbox navigation, captions, and a deterministic initial index. The remote-only degradation path remains covered by isolated renderer tests rather than displaying browser broken-image chrome in the reference fixture.

~~~scopy-rich
{
  "version": 2,
  "type": "image_group",
  "title": "ChatGPT Search image results",
  "state": "ready",
  "message": "Two WACZ response images copied into the deterministic fixture asset set.",
  "source": "2026-08-28 WACZ response resources",
  "asOf": "2026-08-28 archive capture",
  "layout": "search",
  "initialIndex": 0,
  "images": [
    { "asset": "image-group-chatgpt-search-results", "alt": "ChatGPT Search image result showing search results", "title": "Search results", "source": "WACZ response asset" },
    { "asset": "image-group-chatgpt-search-button", "alt": "ChatGPT Search image result showing a search button", "title": "Search button result", "source": "WACZ response asset" }
  ]
}
~~~

## Live Edge finance values plus deterministic v2 interaction series

Provenance split: the QQQ quote, after-hours line, one-day axis/domain, headline metrics, and visible one-day curve shape were read from the supplied ChatGPT capture and live Edge DOM on 2026-08-28. The WACZ ordinary Copy did not preserve a reconstructable finance card. The plotted one-day samples below are a deterministic visual fixture constrained to the captured 714–722 axis and visible intraday shape, not recovered exchange ticks; the other ranges reuse frozen visible checkpoints only to exercise the complete eight-range control.

~~~scopy-rich
{
  "version": 2,
  "type": "finance",
  "title": "Invesco QQQ Trust Series 1 (QQQ)",
  "state": "ready",
  "message": "1D is a captured-shape visual fixture; the other seven controls reuse frozen visible checkpoints as deterministic interaction fixtures.",
  "source": "2026-08-28 supplied ChatGPT capture, live Edge DOM, and labeled deterministic Scopy series",
  "asOf": "2026年8月27日美股交易时段",
  "asset": { "name": "Invesco QQQ Trust Series 1", "ticker": "QQQ" },
  "quote": {
    "price": "US$721.11",
    "afterHours": { "price": "US$718.74", "change": "-US$2.37", "changePercent": "0.33%", "label": "营业时间之后", "trend": "down" }
  },
  "selectedRange": "1D",
  "series": [
    {
      "label": "1D",
      "dateRange": "8月27日，20:15:00 EDT",
      "change": "+US$9.79",
      "changePercent": "1.38%",
      "trend": "up",
      "points": [
        { "label": "10:00 上午", "value": 715.50, "displayValue": "US$715.50" },
        { "label": "10:15 上午", "value": 718.10, "displayValue": "US$718.10" },
        { "label": "10:30 上午", "value": 715.80, "displayValue": "US$715.80" },
        { "label": "10:45 上午", "value": 717.50, "displayValue": "US$717.50" },
        { "label": "11:00 上午", "value": 716.10, "displayValue": "US$716.10" },
        { "label": "11:15 上午", "value": 717.00, "displayValue": "US$717.00" },
        { "label": "11:30 上午", "value": 718.40, "displayValue": "US$718.40" },
        { "label": "11:45 上午", "value": 719.10, "displayValue": "US$719.10" },
        { "label": "12:00 下午", "value": 719.20, "displayValue": "US$719.20" },
        { "label": "12:15 下午", "value": 718.20, "displayValue": "US$718.20" },
        { "label": "12:30 下午", "value": 717.60, "displayValue": "US$717.60" },
        { "label": "12:45 下午", "value": 719.00, "displayValue": "US$719.00" },
        { "label": "1:00 下午", "value": 719.30, "displayValue": "US$719.30" },
        { "label": "1:15 下午", "value": 719.80, "displayValue": "US$719.80" },
        { "label": "1:30 下午", "value": 720.00, "displayValue": "US$720.00" },
        { "label": "1:45 下午", "value": 720.40, "displayValue": "US$720.40" },
        { "label": "2:00 下午", "value": 719.70, "displayValue": "US$719.70" },
        { "label": "2:15 下午", "value": 719.40, "displayValue": "US$719.40" },
        { "label": "2:30 下午", "value": 718.80, "displayValue": "US$718.80" },
        { "label": "2:45 下午", "value": 718.20, "displayValue": "US$718.20" },
        { "label": "3:00 下午", "value": 717.20, "displayValue": "US$717.20" },
        { "label": "3:15 下午", "value": 717.90, "displayValue": "US$717.90" },
        { "label": "3:30 下午", "value": 718.80, "displayValue": "US$718.80" },
        { "label": "3:45 下午", "value": 719.60, "displayValue": "US$719.60" },
        { "label": "4:00 下午", "value": 721.40, "displayValue": "US$721.40" }
      ]
    },
    {
      "label": "5D",
      "dateRange": "Deterministic interaction span from frozen visible checkpoints",
      "change": "+US$9.79",
      "changePercent": "+1.38%",
      "trend": "up",
      "points": [
        { "label": "Open", "value": 717.00, "displayValue": "US$717.00" },
        { "label": "Close", "value": 721.11, "displayValue": "US$721.11" }
      ]
    },
    {
      "label": "1M",
      "dateRange": "Deterministic interaction span from frozen 6M checkpoints",
      "change": "+US$29.45",
      "changePercent": "+4.26%",
      "trend": "up",
      "points": [
        { "label": "7月26日", "value": 687.99, "displayValue": "US$687.99" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    },
    {
      "label": "6M",
      "dateRange": "2026年3月1日 – 2026年8月26日",
      "change": "+US$113.02",
      "changePercent": "+18.59%",
      "trend": "up",
      "points": [
        { "label": "3月1日", "value": 608.09, "displayValue": "US$608.09" },
        { "label": "3月8日", "value": 607.76, "displayValue": "US$607.76" },
        { "label": "3月15日", "value": 600.38, "displayValue": "US$600.38" },
        { "label": "3月22日", "value": 588.00, "displayValue": "US$588.00" },
        { "label": "3月29日", "value": 558.28, "displayValue": "US$558.28" },
        { "label": "4月5日", "value": 588.59, "displayValue": "US$588.59" },
        { "label": "4月12日", "value": 628.60, "displayValue": "US$628.60" },
        { "label": "4月19日", "value": 644.33, "displayValue": "US$644.33" },
        { "label": "4月26日", "value": 657.55, "displayValue": "US$657.55" },
        { "label": "5月3日", "value": 681.61, "displayValue": "US$681.61" },
        { "label": "5月10日", "value": 707.24, "displayValue": "US$707.24" },
        { "label": "5月17日", "value": 701.53, "displayValue": "US$701.53" },
        { "label": "5月24日", "value": 729.45, "displayValue": "US$729.45" },
        { "label": "5月31日", "value": 744.21, "displayValue": "US$744.21" },
        { "label": "6月7日", "value": 693.69, "displayValue": "US$693.69" },
        { "label": "6月14日", "value": 722.51, "displayValue": "US$722.51" },
        { "label": "6月21日", "value": 716.38, "displayValue": "US$716.38" },
        { "label": "6月28日", "value": 712.60, "displayValue": "US$712.60" },
        { "label": "7月5日", "value": 725.51, "displayValue": "US$725.51" },
        { "label": "7月12日", "value": 695.33, "displayValue": "US$695.33" },
        { "label": "7月19日", "value": 684.23, "displayValue": "US$684.23" },
        { "label": "7月26日", "value": 687.99, "displayValue": "US$687.99" },
        { "label": "8月2日", "value": 723.03, "displayValue": "US$723.03" },
        { "label": "8月9日", "value": 731.07, "displayValue": "US$731.07" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    },
    {
      "label": "YTD",
      "dateRange": "Deterministic interaction span from frozen 6M checkpoints",
      "change": "+US$113.02",
      "changePercent": "+18.59%",
      "trend": "up",
      "points": [
        { "label": "3月1日", "value": 608.09, "displayValue": "US$608.09" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    },
    {
      "label": "1Y",
      "dateRange": "Deterministic interaction span from frozen 6M checkpoints",
      "change": "+US$113.02",
      "changePercent": "+18.59%",
      "trend": "up",
      "points": [
        { "label": "3月1日", "value": 608.09, "displayValue": "US$608.09" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    },
    {
      "label": "5Y",
      "dateRange": "Deterministic interaction span from frozen 6M checkpoints",
      "change": "+US$113.02",
      "changePercent": "+18.59%",
      "trend": "up",
      "points": [
        { "label": "3月1日", "value": 608.09, "displayValue": "US$608.09" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    },
    {
      "label": "MAX",
      "dateRange": "Deterministic interaction span from frozen 6M checkpoints",
      "change": "+US$113.02",
      "changePercent": "+18.59%",
      "trend": "up",
      "points": [
        { "label": "3月1日", "value": 608.09, "displayValue": "US$608.09" },
        { "label": "8月20日", "value": 713.44, "displayValue": "US$713.44" }
      ]
    }
  ],
  "metrics": [
    { "label": "打开", "value": "717" },
    { "label": "交易量", "value": "28.7M" },
    { "label": "市值", "value": "343.79B" },
    { "label": "当日最低价", "value": "714.54" },
    { "label": "年度最低价", "value": "555.6" },
    { "label": "当日最高价", "value": "721.4" },
    { "label": "每股收益（滚动 12 个月）", "value": "—" },
    { "label": "年度最高价", "value": "748.65" },
    { "label": "市盈率", "value": "—" }
  ]
}
~~~

## Saved-text boundary, live Edge weather values, and deterministic unit pairs

Provenance split: archived saved text proves only that the weather strings survived; it does not prove the card DOM, layout, or controls. The Fahrenheit values and eight visible daily columns were inspected in the live Edge DOM. Celsius display/numeric pairs, per-day hourly grouping, and the copied local weather asset IDs are deterministic Scopy fixture data used to exercise unit/day switching and chart probes.

~~~scopy-rich
{
  "version": 2,
  "type": "weather",
  "title": "旧金山天气",
  "state": "ready",
  "message": "Eight-day visible forecast; Fahrenheit is live-Edge-derived and Celsius/hourly pairs are deterministic fixture conversions.",
  "source": "2026-08-28 live Edge values plus deterministic Scopy unit pairs",
  "asOf": "2026-08-28 capture session",
  "location": "旧金山, 加利福尼亚, 美国",
  "selectedUnit": "F",
  "selectedDay": 0,
  "days": [
    {
      "label": "周四",
      "condition": "大部分多云，下午局部地区有阵雨",
      "icon": { "asset": "weather-sun-shower-light", "alt": "局部阵雨" },
      "current": { "f": "61°", "c": "16°" },
      "high": { "f": "71°", "c": "22°" },
      "low": { "f": "58°", "c": "14°" },
      "hourly": [
        { "label": "12上午", "temperature": { "f": "60°", "c": "16°" }, "value": { "f": 60, "c": 15.6 } },
        { "label": "3上午", "temperature": { "f": "59°", "c": "15°" }, "value": { "f": 59, "c": 15.0 } },
        { "label": "6上午", "temperature": { "f": "58°", "c": "14°" }, "value": { "f": 58, "c": 14.4 } },
        { "label": "9上午", "temperature": { "f": "60°", "c": "16°" }, "value": { "f": 60, "c": 15.6 } },
        { "label": "12下午", "temperature": { "f": "64°", "c": "18°" }, "value": { "f": 64, "c": 17.8 } },
        { "label": "3下午", "temperature": { "f": "68°", "c": "20°" }, "value": { "f": 68, "c": 20.0 } },
        { "label": "6下午", "temperature": { "f": "65°", "c": "18°" }, "value": { "f": 65, "c": 18.3 } },
        { "label": "9下午", "temperature": { "f": "60°", "c": "16°" }, "value": { "f": 60, "c": 15.6 } }
      ]
    },
    {
      "label": "周五",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "大部分多云" },
      "current": { "f": "59°", "c": "15°" },
      "high": { "f": "68°", "c": "20°" },
      "low": { "f": "57°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "57°", "c": "14°" }, "value": { "f": 57, "c": 13.9 } },
        { "label": "3下午", "temperature": { "f": "68°", "c": "20°" }, "value": { "f": 68, "c": 20.0 } }
      ]
    },
    {
      "label": "周六",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "58°", "c": "14°" },
      "high": { "f": "67°", "c": "19°" },
      "low": { "f": "56°", "c": "13°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "56°", "c": "13°" }, "value": { "f": 56, "c": 13.3 } },
        { "label": "3下午", "temperature": { "f": "67°", "c": "19°" }, "value": { "f": 67, "c": 19.4 } }
      ]
    },
    {
      "label": "周日",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "60°", "c": "16°" },
      "high": { "f": "67°", "c": "19°" },
      "low": { "f": "58°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "58°", "c": "14°" }, "value": { "f": 58, "c": 14.4 } },
        { "label": "3下午", "temperature": { "f": "67°", "c": "19°" }, "value": { "f": 67, "c": 19.4 } }
      ]
    },
    {
      "label": "周一",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "60°", "c": "16°" },
      "high": { "f": "66°", "c": "19°" },
      "low": { "f": "58°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "58°", "c": "14°" }, "value": { "f": 58, "c": 14.4 } },
        { "label": "3下午", "temperature": { "f": "66°", "c": "19°" }, "value": { "f": 66, "c": 18.9 } }
      ]
    },
    {
      "label": "周二",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "59°", "c": "15°" },
      "high": { "f": "65°", "c": "18°" },
      "low": { "f": "57°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "57°", "c": "14°" }, "value": { "f": 57, "c": 13.9 } },
        { "label": "3下午", "temperature": { "f": "65°", "c": "18°" }, "value": { "f": 65, "c": 18.3 } }
      ]
    },
    {
      "label": "周三",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "60°", "c": "16°" },
      "high": { "f": "67°", "c": "19°" },
      "low": { "f": "58°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "58°", "c": "14°" }, "value": { "f": 58, "c": 14.4 } },
        { "label": "3下午", "temperature": { "f": "67°", "c": "19°" }, "value": { "f": 67, "c": 19.4 } }
      ]
    },
    {
      "label": "周四",
      "condition": "—",
      "icon": { "asset": "weather-mostly-cloudy-light", "alt": "多云" },
      "current": { "f": "60°", "c": "16°" },
      "high": { "f": "69°", "c": "21°" },
      "low": { "f": "57°", "c": "14°" },
      "hourly": [
        { "label": "6上午", "temperature": { "f": "57°", "c": "14°" }, "value": { "f": 57, "c": 13.9 } },
        { "label": "3下午", "temperature": { "f": "69°", "c": "21°" }, "value": { "f": 69, "c": 20.6 } }
      ]
    }
  ]
}
~~~

## Live Edge exchange rate plus deterministic v2 conversion

Provenance split: the `1 USD = 6.7199 CNY` rate was read from the live Edge DOM. The WACZ ordinary Copy did not preserve a reconstructable currency card. The numeric amount, `fractionDigits`, reverse-edit behavior, and displayed result are deterministic Scopy fixture behavior; the renderer uses only the frozen numeric rate and never refreshes it.

~~~scopy-rich
{
  "version": 2,
  "type": "currency",
  "title": "美元兑人民币",
  "state": "ready",
  "message": "Frozen live-Edge rate; deterministic bidirectional fixture conversion only.",
  "source": "2026-08-28 live Edge rate plus deterministic Scopy conversion",
  "asOf": "2026-08-28 04:06 UTC",
  "from": { "code": "USD", "name": "美元", "symbol": "$", "flag": "🇺🇸" },
  "to": { "code": "CNY", "name": "人民币", "symbol": "¥", "flag": "🇨🇳" },
  "amount": 100,
  "rate": 6.7199,
  "fractionDigits": 2
}
~~~

## WACZ-derived web-results snapshot

~~~scopy-rich
{
  "version": 2,
  "type": "web_results",
  "title": "ChatGPT Search sources",
  "state": "ready",
  "message": "Two frozen results from captured search-result fields.",
  "source": "2026-08-28 WACZ conversation response",
  "asOf": "2026-08-28 archive capture",
  "items": [
    { "title": "ChatGPT Search | OpenAI Help Center", "url": "https://help.openai.com/en/articles/9237897-chatgpt-search", "source": "help.openai.com", "favicon": { "asset": "favicon-help-openai-32", "alt": "OpenAI Help Center" } },
    { "title": "Introducing ChatGPT search | OpenAI", "url": "https://openai.com/index/introducing-chatgpt-search/", "source": "openai.com", "date": "2024-10-31", "favicon": { "asset": "favicon-openai-32", "alt": "OpenAI" } }
  ]
}
~~~

## Strict v2 state and rejection edges

This explicit empty state is valid and must remain visibly different from a zero, a literal `—`, a partial snapshot, and an acquisition error:

~~~scopy-rich
{
  "version": 2,
  "type": "news",
  "title": "No matching stories",
  "state": "empty",
  "message": "The frozen producer positively returned zero matching stories.",
  "source": "Deterministic Scopy state fixture",
  "asOf": "2026-08-28"
}
~~~

The following outer code fence documents rejection inputs without turning them into rich surfaces. Any non-`2` version, an unknown asset ID, a remote image pretending to be a local asset, unknown keys, wrong numeric types, a meta-bearing `scopy-rich` fence, or an out-of-range selected index must remain ordinary code. There is no legacy compatibility path.

````text
```scopy-rich
{"version":3,"type":"news","items":[]}
```

```scopy-rich preview
{"version":2,"type":"currency","from":{"code":"USD"},"to":{"code":"CNY"},"amount":100,"rate":6.7199,"fractionDigits":2}
```
````
