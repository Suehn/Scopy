# UI Fixture Provenance

Fixtures in this directory are deterministic local inputs for Scopy UI/export checks. They are not automatically evidence of ChatGPT DOM or visual behavior.

- `rich_markdown.md` covers the broad Markdown surface.
- `markdown_safe_html_torture.md` covers literal raw HTML and safe rendering.
- `resolution_scale.md` covers fixed-output resolution scaling.
- `user_markdown_stress.md` is the first user-supplied 2,728-line Markdown/Math/table/Unicode edge-case corpus, preserved byte-for-byte as a release regression input. Deliberately malformed Markdown remains malformed; passing means stable parsing, literal-safe degradation, complete export, and no layout corruption rather than inventing missing escapes.
- `chatgpt_rich_copy_sample.md` is the second user-supplied copied visible-text sample. It intentionally contains no reconstructable `scopy-rich` payload, so it must remain stable ordinary Markdown and must not synthesize cards, citations, or private metadata.
- `chatgpt_public_copy_markdown_sample.md` is the exact 19,825-byte public Markdown copy supplied separately from the flattened visible-text sample. It intentionally has no trailing newline and preserves real reference definitions, two remote Markdown images, three display-math blocks, and one session-scoped `sandbox:` artifact target. The renderer may form an offline image group from the two present image nodes, but must not infer private news, finance, weather, currency, product, or artifact data.
- `chatgpt_rich_surfaces.md` is the strict `scopy-rich` v2 fixture. It separates WACZ structured fields and copied response bytes from live Edge observations and deterministic interaction-only values; exercises real OpenCode/Codex HTTP links, Codex absolute file paths with `:line`, grouped source citations, allowlisted local news/image/weather assets, interactive weather/finance/currency/chart/lightbox states, and explicit empty/partial/rejection edges. Remote image URLs remain provenance and never create a network dependency. Preview hydrates the shared document; export freezes the same HTML, CSS, assets, and runtime in the envelope-selected state.

## Source-icon regression fixture

`markdown_link_icons.md` is a synthetic presentation fixture based on the user's 2026-09-05 link comparison. It covers verified EleBank/HSBC favicons, unknown-host globe, long CJK and RTL links, local file kinds, inert plugin links, task markers, footnotes, citation sources, and news/search source rows. Its prose is for rendering verification, not banking advice. The original icon provenance is in `Tools/MarkdownRenderer/THIRD_PARTY_NOTICES.md`. Node `source-icons.test.js` and real-app `testAutoExportSourceIconsFixture` share this fixture.

`markdown_codex_icons.md` covers the original installed Codex file/media and 22 application glyphs, repeated Office gradients, bank favicons and long labels. `testAutoExportCodexIconsPreservesOriginalColors` enables palette reduction and verifies the actual export keeps true color. Immutable SVG provenance fixtures live under `Tools/MarkdownRenderer/test/fixtures/codex-*` (Node-only to avoid Xcode flattening same-name assets).
