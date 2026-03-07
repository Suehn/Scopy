# Clipboard Image Fixtures

`history-replay-real-screenshot-paletted.png` is a safe real screenshot fixture.

It exists to lock down the Codex/macOS clipboard regression where a historical
palette PNG can look fine in most apps but still fail when replayed through
Codex's narrow `arboard` image path. The replay fix preserves the original
`public.png` bytes and adds a rasterized `public.tiff` fallback for readers that
cannot decode the original representation reliably.
