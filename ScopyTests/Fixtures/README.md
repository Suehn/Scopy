# Clipboard Fixtures

`history-replay-real-screenshot-paletted.png` is a safe real screenshot fixture.

It exists to lock down the Codex/macOS clipboard regression where a historical
palette PNG can look fine in most apps but still fail when replayed through
Codex's narrow `arboard` image path.

Normal history replay keeps the original `public.png` bytes only. The explicit
`Paste-optimized for Codex` action preserves those same PNG bytes as the
primary representation and adds a rasterized `public.tiff` only as a
compatibility fallback for readers that cannot decode the original
representation reliably.

## ChatGPT Chinese table copy

`chatgpt_copy_chinese_table.md` and `.html` are a synthetic paired-MIME
reproduction based on the 2026-09-05 user screenshots, not an original browser
capture. They cover Chinese emphasis, a four-column table, currency, and a
KaTeX annotation later in the same response. `ClipboardMonitorTests` verifies
the production capture preserves the Markdown and unchanged HTML bytes.

The compact inline fixture in `testCaptureClipboardPreservesCompactChineseTableAndInlineEmphasis`
failed before the fix: HTML extraction kept the heading/math but flattened the
table and stripped bold; word-level overlap then rejected the equivalent Chinese
Markdown. Ideograph comparison must be independent of those formatting boundaries.
The unrelated-Chinese and existing unrelated-tail tests retain the rejection contract.
