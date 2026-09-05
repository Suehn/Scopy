# Third-Party Notices

## Phosphor Icons

The currency selector's combined up/down control retains the unchanged SVG path
from `@phosphor-icons/core` 2.1.1 `assets/regular/caret-up-down.svg`.
File, source, application and other rich-control artwork now uses the original
Codex assets documented below; the obsolete substitute paths were removed.

MIT License

Copyright (c) 2023 Phosphor Icons

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## CJK-Friendly Markdown Parsing

`remark-cjk-friendly` 2.3.1, `micromark-extension-cjk-friendly` 2.0.1,
and `micromark-extension-cjk-friendly-util` are MIT licensed under the terms above.
They include adaptations of remark-gfm and micromark utilities.

Copyright (c) 2025 Tatsunori Uchino <tats.u@live.jp>

Copyright (c) Titus Wormer <tituswormer@gmail.com>

The transitive `get-east-asian-width` package is also MIT licensed under the same terms.

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)


## Official Website Favicons

The following original PNG files were downloaded unchanged on 2026-09-05 from
the banks' official website icon links. They identify destinations in rendered
links and citations; they do not imply endorsement. The logos and trademarks
remain the property of their respective owners and are not covered by the
Phosphor MIT license above.

| Bundled asset | Official declaring page | Original icon URL | Original size | SHA-256 |
| --- | --- | --- | --- | --- |
| `rich/favicon-elebank-150.png` | [EleBank help center](https://support.platform.elebank.com/personal/zh-hk), `rel="shortcut icon"` | [Original EleBank PNG](https://cdn.wm.elebank.com/user-consult-node/assets/ele-favico.png) | 150 × 150 | `da74bf5a184e841e81a90f4bd59928f0ce489fe63ea48b09d0a5f2238617c806` |
| `rich/favicon-hsbc-hk-32.png` | [HSBC HK FPS FAQ](https://www.hsbc.com.hk/campaigns/fps/faq/), `rel="icon"`, `sizes="32x32"` | [Original HSBC HK PNG](https://www.hsbc.com.hk/etc.clientlibs/dpws/clientlibs-public/clientlib-site/resources/favicons/favicon-32x32.png) | 32 × 32 | `e3fbe878da9f2a357e7e3f556d0c3e32b6a7c82f5bb7507f5b0878bad2a4c395` |

Matching fixture copies live in `ScopyUITests/Fixtures/Assets/chatgpt-rich/`.
EleBank's official identity and help-center host are linked from
[the bank's website](https://www.elebank.com/zh-hk/).
Only the explicitly listed hosts in `scopyLocalImageAssets.js` select these
assets; lookalike domains and arbitrary subdomains do not inherit a logo.

## Codex File and Attachment Icons

`src/codexFileIconAssets.json` preserves the original SVG geometry, colors,
gradients, view boxes, and intrinsic dimensions extracted from the locally
installed Codex application on 2026-09-05:

- Application bundle: `/Applications/ChatGPT.app` (`com.openai.codex`).
- Version: `26.901.41600`, build `7982`.
- Source JavaScript asset: `app-initial-86767c3d23e5.js`.
- Source SHA-256: `fb72076ee44f6596f8dafa9a3effe37a3527a87db21fde8b4042233957b554bb`.
- File selection source: `HV` → `_5r` → `b5r` (28 file-type entries; YAML uses the
  same SVG as the generic file icon).
- Audio and video source: `NVr` and `LVr`, respectively, using the source `pz`
  SVG wrapper. These two attachment icons are explicit Scopy adaptations for
  audio/video files; the Codex `HV` resolver itself does not select them.

Extraction evaluated only individually isolated literal SVG JSX expressions
with a minimal JSX-to-HAST adapter. It did not execute the application bundle.
JSX fragments were flattened without changing SVG visual data. No path was
redrawn or simplified and no brand color was substituted. Runtime code may
namespace SVG definition IDs and apply the requested display dimensions;
the stored originals retain their source IDs and dimensions.

Standalone SVG fixtures and per-icon source-expression, HAST-node, and SVG-file
SHA-256 values are recorded in
`Tools/MarkdownRenderer/test/fixtures/codex-icons/manifest.json`. Source ranges in that
manifest are zero-based UTF-16 code-unit ranges in the source JavaScript asset.

The original application artwork belongs to OpenAI. These icons are separate
from the Phosphor assets and are not covered by the Phosphor MIT license above.
This provenance record is not a grant of redistribution rights.

## Codex Plugin and Connector Icons

`src/codexPluginIconAssets.json` separately preserves all 22 entries from the
same Codex application's `PQr` → `IQr` → `LQr` → `RQr` plugin-name resolver.
This includes its original Figma, Git, Gmail, Google Calendar, Google Docs,
Google Drive, Google Sheets, Google Slides, GitHub, Linear, Notion, Salesforce,
Sites, and Slack artwork, plus Computer Use, Wallet, and file-format icons.
`presentations` and `file-presentation` share the same original SVG component.

- Codex version: `26.901.41600`, build `7982`, `com.openai.codex`.
- Extraction date: 2026-09-05.
- Source JavaScript asset: `app-initial-86767c3d23e5.js`.
- Source SHA-256: `fb72076ee44f6596f8dafa9a3effe37a3527a87db21fde8b4042233957b554bb`.
- Standalone SVGs and source-expression/HAST/SVG hashes:
  `Tools/MarkdownRenderer/test/fixtures/codex-plugin-icons/manifest.json`.

Only isolated literal SVG JSX expressions were evaluated with the same minimal
JSX-to-HAST adapter described above. The full application was not executed.
Original paths, colors, gradients, view boxes, and intrinsic sizes were
preserved. Names and normalization in this source resolver identify its actual
supported keys; unknown app identifiers do not establish a brand match.

This artwork and the represented trademarks remain the property of their
respective owners. They are separate from the Phosphor assets and are not
covered by the Phosphor MIT license. This record documents provenance and
provides no grant of redistribution rights.

## Original Codex globe and rich controls (2026-09-05)

The same installed Codex version supplies original 12/16 light globes (`Tni`/`Dni`) and seven rich-control glyphs. See `src/codexGlobeAssets.json`, `src/codexControlIconAssets.json` and `test/fixtures/codex-control-icons/PROVENANCE.md` for exact definitions, source hashes and semantic limits. The `play-fill` integration key uses the original outlined `play-light-20`; no filled source was invented. Only the combined currency selector retains Phosphor artwork. These original application assets are separate from the Phosphor MIT license.
