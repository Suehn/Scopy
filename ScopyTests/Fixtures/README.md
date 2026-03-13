# Clipboard Image Fixtures

`history-replay-real-screenshot-paletted.png` is a safe real screenshot fixture.

It exists to lock down the Codex/macOS clipboard regression where a historical
palette PNG can look fine in most apps but still fail when replayed through
Codex's narrow `arboard` image path.

Normal history replay keeps the original `public.png` bytes only. The explicit
`Paste-optimized for Codex` action preserves those same PNG bytes as the
primary representation and adds a rasterized `public.tiff` only as a
compatibility fallback for readers that cannot decode the original
representation reliably.
