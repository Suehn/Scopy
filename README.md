# Scopy

A native macOS clipboard manager with unlimited history, intelligent storage, and high-performance search.

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Unlimited History** - Store 10k+ clipboard items with intelligent cleanup
- **Multi-type Support** - Text, RTF, HTML, Images, Files
- **Fast Search** - FTS5 full-text search with fuzzy/exact/regex modes
- **Pin Items** - Keep important items always accessible
- **App Filtering** - Filter history by source application
- **Image Thumbnails** - Preview images with hover-to-zoom
- **Global Hotkey** - Quick access with customizable shortcut (default: ⇧⌘C)
- **Lightweight** - ~50MB memory for 10k items (90% less than naive implementation)

## Installation

### Homebrew (Recommended)

```bash
brew tap Suehn/scopy
brew install --cask scopy
```

> App is not signed. On first launch: Right-click → Open → Open

### Manual Download

Download the latest `.dmg` from [Releases](https://github.com/Suehn/Scopy/releases).

---

## Usage

| Action | Shortcut |
|--------|----------|
| Open/Close Panel | ⇧⌘C (customizable) |
| Navigate | ↑ / ↓ |
| Select & Paste | Enter |
| Clear Search / Close | Esc |
| Delete Item | ⌥⌫ |
| Open Settings | ⌘, |

**Mouse:**
- Click item to copy
- Right-click for context menu (Copy / Pin / Delete)
- Hover image for preview

---

## Build from Source

### Prerequisites

- macOS 14.0+
- Xcode 16.0+
- Homebrew (for xcodegen)

### Quick Build

```bash
# Install dependencies and build
make setup && make build

# Or use deploy script
./deploy.sh release
```

### Development

```bash
# Build and run (Debug)
make run

# Run tests (161 tests)
make test

# Build Release DMG
./scripts/build-release.sh
```

---

## Architecture

Scopy follows a **protocol-first, frontend-backend separation** design:

```
┌─────────────────────────────────────────────────────────┐
│                      UI Layer                            │
│   ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│   │ MenuBar  │  │ Floating │  │      Settings        │ │
│   │  Icon    │  │  Panel   │  │       Window         │ │
│   └──────────┘  └──────────┘  └──────────────────────┘ │
│                        │                                │
│              ClipboardServiceProtocol                   │
└────────────────────────┼────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│                  Backend Services                        │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│   │  Clipboard   │  │   Storage    │  │    Search    │ │
│   │   Monitor    │  │   Service    │  │   Service    │ │
│   │  (polling)   │  │  (SQLite)    │  │   (FTS5)     │ │
│   └──────────────┘  └──────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Description |
|-----------|-------------|
| `ClipboardMonitor` | Polls system clipboard, detects changes, computes content hash |
| `StorageService` | SQLite + FTS5, hierarchical storage (inline < 50KB, external files) |
| `SearchService` | Multi-mode search with caching, timeout protection |
| `AppState` | Observable state management, event-driven updates |
| `FloatingPanel` | NSPanel-based popup, appears at mouse position |

### Data Storage

```
~/Library/Application Support/Scopy/
├── clipboard.db          # SQLite database with FTS5
├── content/              # Large content (images, files)
│   └── <uuid>.png
└── thumbnails/           # Image thumbnail cache
```

---

## Performance

| Metric | Target | Actual |
|--------|--------|--------|
| Search ≤5k items | P95 ≤ 50ms | ~5ms |
| Search 10k items | P95 ≤ 150ms | ~25ms |
| Memory (10k items) | < 100MB | ~50MB |
| First load (50 items) | < 100ms | ~5ms |

---

## Configuration

Settings available in the app (⌘,):

- **General**: Global hotkey, search mode (fuzzy/exact/regex)
- **Storage**: Max items (default 10k), max size, auto-cleanup
- **Appearance**: Thumbnail height, preview delay
- **About**: Version info, storage statistics

---

## Tech Stack

- **UI**: SwiftUI + AppKit (NSPanel, NSStatusItem)
- **Storage**: SQLite3 + FTS5 (full-text search)
- **Concurrency**: Swift async/await, actors
- **Build**: XcodeGen + Makefile

---

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Acknowledgments

Inspired by [Maccy](https://github.com/p0deje/Maccy) and other great clipboard managers.
