# SCOPY_UITEST_EXPORT_RESOLUTION_SCALE

This Markdown fixture is used by `ExportMarkdownPNGUITests` to validate that exported PNG content scales with the selected resolution (1x vs 2x).

## Section A

Paragraph 1: The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.

Paragraph 2: 这是一段用于验证导出分辨率缩放的中文文本，长度适中，确保渲染高度可观。

Paragraph 3: Mixed content with inline math $E = mc^2$ and some extra words to increase the rendered height.

## Section B

- Item 1: A bullet point with enough text to wrap at least once in the fixed-width export layout.
- Item 2: Another bullet point to add a bit more vertical height.
- Item 3: Yet another bullet point to keep the content non-trivial.

### Code Block

```text
line 1: 0123456789abcdefghijklmnopqrstuvwxyz
line 2: 0123456789abcdefghijklmnopqrstuvwxyz
line 3: 0123456789abcdefghijklmnopqrstuvwxyz
```
