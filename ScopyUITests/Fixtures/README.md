# UI Fixture Provenance

Fixtures in this directory are deterministic local inputs for Scopy UI/export checks. They are not automatically evidence of ChatGPT DOM or visual behavior.

- `rich_markdown.md` covers the broad Markdown surface.
- `markdown_safe_html_torture.md` covers literal raw HTML and safe rendering.
- `resolution_scale.md` covers fixed-output resolution scaling.
- `user_markdown_stress.md` is the first user-supplied 2,728-line Markdown/Math/table/Unicode edge-case corpus, preserved byte-for-byte as a release regression input. Deliberately malformed Markdown remains malformed; passing means stable parsing, literal-safe degradation, complete export, and no layout corruption rather than inventing missing escapes.
- `chatgpt_rich_copy_sample.md` is the second user-supplied copied visible-text sample. It intentionally contains no reconstructable `scopy-rich` payload, so it must remain stable ordinary Markdown and must not synthesize cards, citations, or private metadata.
- `chatgpt_public_copy_markdown_sample.md` is the exact 19,825-byte public Markdown copy supplied separately from the flattened visible-text sample. It intentionally has no trailing newline and preserves real reference definitions, two remote Markdown images, three display-math blocks, and one session-scoped `sandbox:` artifact target. The renderer may form an offline image group from the two present image nodes, but must not infer private news, finance, weather, currency, product, or artifact data.
- `chatgpt_rich_surfaces.md` is the strict `scopy-rich` v2 fixture. It separates WACZ structured fields and copied response bytes from live Edge observations and deterministic interaction-only values; exercises real OpenCode/Codex HTTP links, Codex absolute file paths with `:line`, grouped source citations, allowlisted local news/image/weather assets, interactive weather/finance/currency/chart/lightbox states, and explicit empty/partial/rejection edges. Remote image URLs remain provenance and never create a network dependency. Preview hydrates the shared document; export freezes the same HTML, CSS, assets, and runtime in the envelope-selected state.
