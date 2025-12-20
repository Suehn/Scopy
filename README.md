# Scopy

A native macOS clipboard manager with unlimited history, intelligent storage, and high-performance search.

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-blue)
![License MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Unlimited History** - Store 10k+ clipboard items with intelligent cleanup
- **Multi-type Support** - Text, RTF, HTML, Images, Files
- **Fast Search** - FTS5 full-text search with fuzzy/exact/regex modes
- **Pin Items** - Keep important items always accessible
- **App Filtering** - Filter history by source application
- **Hover Preview** - Markdown/LaTeX/image previews with scrollable content
- **Export PNG** - One-click export from Markdown/LaTeX preview
- **Image Thumbnails** - Inline thumbnails with configurable size
- **Global Hotkey** - Quick access with customizable shortcut (default: ⇧⌘C)

## Installation

### Homebrew (Recommended)

```bash
brew tap Suehn/scopy
brew install --cask scopy

# Upgrade
brew upgrade --cask scopy
```

> App is not signed. On first launch: Right-click → Open → Open

**If Scopy.app does not appear in /Applications:**

```bash
brew reinstall --cask scopy --appdir=/Applications
# or copy manually
cp -R /opt/homebrew/Caskroom/scopy/<version>/Scopy.app /Applications/
```

### Manual Download

Download the latest `.dmg` from Releases.

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
- Hover image/text for preview
- In Markdown/LaTeX preview, use Export PNG

---

## Build from Source

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 16.0+
- Homebrew (for xcodegen)

### Quick Build

```bash
# Debug build
./deploy.sh

# Release build
./deploy.sh release

# Only build (no launch)
./deploy.sh --no-launch
```

### Development

```bash
# Generate Xcode project (if needed)
xcodegen generate

# Unit tests
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests
```

### Release (Maintainers)

Releases are **tag-driven**:

```bash
make release-validate
make tag-release

git push origin main
git push origin vX.Y.Z
```

Homebrew cask is updated by CI when `HOMEBREW_GITHUB_API_TOKEN` is available; otherwise update the tap manually.

---

## Architecture

Scopy follows a **protocol-first, frontend-backend separation** design:

```
┌─────────────────────────────────────────────────────────┐
│                      UI Layer                           │
│   ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│   │ MenuBar  │  │ Floating │  │      Settings        │ │
│   │  Icon    │  │  Panel   │  │       Window         │ │
│   └──────────┘  └──────────┘  └──────────────────────┘ │
│                        │                                │
│              ClipboardServiceProtocol                   │
└────────────────────────┼────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│                  Backend Services                       │
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
| `StorageService` | SQLite + FTS5, inline/external storage split |
| `SearchService` | Multi-mode search with caching and timeouts |
| `AppState` | Observable state management, event-driven updates |
| `FloatingPanel` | NSPanel-based popup near cursor |

### Data Storage

```
~/Library/Application Support/Scopy/
├── clipboard.db          # SQLite database with FTS5
├── content/              # Large content (images, files)
│   └── <uuid>.png
└── thumbnails/           # Image thumbnail cache
```

---

## Documentation

- `doc/README.md` - Documentation structure
- `doc/implementation/README.md` - Current status and release index
- `doc/implementation/CHANGELOG.md` - Changelog
- `doc/specs/v0.md` - Product spec
- `doc/profiles/` - Performance baselines

---

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

For maintainers: update release docs (`doc/implementation/releases/`), index, and CHANGELOG for every shipped change.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Acknowledgments

Inspired by [Maccy](https://github.com/p0deje/Maccy) and other great clipboard managers.
