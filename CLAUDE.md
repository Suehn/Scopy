# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

要求设计的时候要读dev-doc的文件，避免偏离，每次写完代码后，要提醒我：切换模型到haiku，然后完整输出精炼的本次改动的实现路线、当前状态改动、walkthrough和遗留点等doc/implemented-doc/下的文档，一个dev-doc/vx.md可以对应一个实现的implemented-doc文档，多次修改知道完全实现。方便新启动对话的时候可以直接从这个文档读到开发记录和当前状态来进行继续开发。

## Project Overview

**Scopy** is a native macOS clipboard manager designed to provide unlimited history, intelligent storage, and high-performance search. The project is currently in the specification phase with a detailed architecture document (`doc/dev-doc/v0.md`) that serves as the complete Phase 1 requirements.

## Architecture

Scopy follows a **strict front-end/back-end separation** pattern to enable component swappability and independent testing:

### Backend Layer

- **ClipboardService**: Monitors and manages clipboard events
- **StorageService**: Handles data persistence with hierarchical storage (SQLite for small content, external files for large content)
- **SearchService**: Provides multi-mode search (exact, fuzzy, regex) with FTS5 indexing
- Core data model: `ClipboardItem` with fields for content hash, plain text, app source, timestamps, pin status, and storage references
- Deduplication at write time using content hashing

### Frontend Layer

- UI Shell: menubar icon + popup window + settings window
- Native macOS (SwiftUI preferred, AppKit compatibility considered)
- Communicates exclusively through protocol-based interfaces
- Can operate in "mock backend" mode for development

### Key Architectural Patterns

1. **Protocol-First Design**: All communication between UI and backend uses explicit interfaces, enabling testing and future replacement of either layer
2. **Hierarchical Storage**: Small content (<X KB) in SQLite, large content (≥X KB) as external files with metadata in DB
3. **Lazy Loading**: Initial load of 50-100 recent items, pagination of 100 items per page to prevent UI freezing
4. **Deduplication**: Compute content hash on clipboard change, update timestamps/usage count on duplicates rather than creating new entries
5. **Multi-Mode Search**: Exact (FTS/LIKE), Fuzzy (FTS + fuzzy rules), Regex (limited to small subsets)

## Development Commands

### Setting Up and Building

Since the project is in specification phase, no build commands are yet defined. Refer to `doc/dev-doc/v0.md` for architectural guidance before implementing.

### Testing

Future testing strategy should verify:

- Backend services can be tested independently via CLI or unit tests without UI code
- UI can run in "mock backend" mode (frontend depends only on protocols, not concrete implementations)

### Running Tests

To be defined during implementation phase.

## Key Design Requirements

### Performance Targets (P95 latencies)

- ≤5k items: search latency ≤ 50ms
- 10k-100k items: first 50 results within 100-150ms
- Search debounce: 150-200ms during continuous input

### Data Management

- Support "logically unlimited" history with configurable cleanup strategies:
  - By count (default: 10k items)
  - By time (default: unlimited)
  - By disk usage (default: 200MB for small content, 800MB for large content)

### Search Interface

All search requests follow this structure:

```typescript
interface SearchRequest {
  query: string;
  mode: "exact" | "fuzzy" | "regex";
  appFilter?: string;   // Filter by source app
  typeFilter?: string;  // Filter by content type
  limit: number;
  offset: number;
}
```

Results return paginated responses with hasMore flag for progressive rendering.

## Important Notes for Implementers

1. **This is a specification-driven project**: The detailed requirements in `doc/dev-doc/v0.md` define Phase 1 scope and acceptance criteria
2. **Start with backend**: Implement ClipboardService, StorageService, and SearchService before UI
3. **UI comes last**: The protocol-based architecture allows UI development to happen independently
4. **Performance is first-class**: Quantified SLOs guide implementation choices and should inform testing strategy
5. **Extensibility built-in**: The separation of concerns anticipates future features like daemon mode or distributed access

## Specification Reference

The complete Phase 1 specification is in `doc/dev-doc/v0.md` with the four core goals:

1. Native beautiful UI + complete backend/frontend decoupling
2. Unlimited history + hierarchical storage + lazy loading
3. Data structures and indexing for deduplication and search
4. High-performance search + progressive result rendering
