# Current Storage Commit Failure Map

Date: 2026-07-11
Audited tree: `main` at `8544df6`
Authority: `.trellis/tasks/07-11-storage-commit-protocol/prd.md`
Scope: current external-payload ingest, durable envelope/spool handling, image replacement, repository mutation, search synchronization, UI publication, deletion/cleanup, and restart recovery. This is a read-only audit; it does not select or implement the replacement protocol.

## Executive conclusion

Scopy already has two strong local consistency mechanisms:

1. SQLite row mutations, persistent FTS triggers, metadata counters, and `mutation_seq` advance inside one `BEGIN IMMEDIATE` transaction (`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:1090-1130`; `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:247-289`, `315-344`).
2. Explicit image optimization never rewrites the currently referenced managed file. It transforms a hidden stage, publishes a unique UUID path, compare-and-swaps the row, and treats the previous file as a reclaimable orphan (`Scopy/Application/ClipboardService.swift:1595-1798`; `Scopy/Services/StorageService.swift:597-649`).

There is nevertheless no single end-to-end commit protocol. The highest-severity break is the normal external ingest path: a durable spool payload is moved out of the spool before the SQLite insert commits, and the insert failure path then deletes the managed copy. The envelope survives but points at a missing payload and is terminally discarded on replay. A recoverable capture can therefore become unrecoverable without a committed row (`Scopy/Services/StorageService.swift:435-500`; `Scopy/Services/ClipboardMonitor.swift:802-810`).

The second systemic break is cleanup: repository planning and deletion are separate transactions. A row selected while unpinned can be pinned before the unconditional ID delete and still be removed; cleanup also invalidates search but emits no UI deletion/reload event (`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:832-870`, `873-953`, `983-1062`; `Scopy/Services/StorageService.swift:1457-1478`; `Scopy/Application/ClipboardService.swift:2202-2224`).

Repository APIs are only partly outcome-aware. Payload CAS and metadata methods return an optional current row, but they conflate `notFound` and `conflict`; pin and raw payload update return no affected-row result at all. Search and UI side effects must consequently infer authority by rereading, and event ordering is reservation order rather than database commit order (`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:215-300`, `302-315`; `Scopy/Application/ClipboardService.swift:1817-1921`).

## 1. Authority and durability domains

| Domain | Current owner | Durable authority | Projection / cache |
| --- | --- | --- | --- |
| Pasteboard capture | `ClipboardMonitor` on `@MainActor` | None | `RawClipboardData` in memory (`ClipboardMonitor.swift:189-216`) |
| Pending large ingest | `ClipboardMonitor` | Envelope JSON plus optional payload file under `~/Library/Caches/Scopy/ingest` (`ClipboardMonitor.swift:218-231`, `273-293`, `965-986`) | pending URL arrays and metrics (`ClipboardMonitor.swift:242-250`, `993-1003`) |
| Managed payload | `StorageService` | UUID-named file under Application Support `Scopy/content` (`StorageService.swift:236-260`, `1765-1775`) | filename protection counts and process-wide path reservations (`StorageService.swift:7-96`, `223-229`) |
| Item metadata | `SQLiteClipboardRepository` | `clipboard_items` row and transaction (`SQLiteClipboardRepository.swift:148-189`, `1094-1130`) | `ClipboardStoredItem` snapshots |
| Persistent text index | SQLite migration triggers | FTS / trigram rows in the same transaction as `clipboard_items` (`SQLiteMigrations.swift:247-289`, `315-344`) | None |
| Interactive search | `SearchEngineImpl` actor | SQLite remains authority | recent cache, short-query index, full fuzzy index, disk cache (`SearchEngineImpl.swift:901-950`) |
| UI publication | `ClipboardEventQueue` | None; process-memory only | bounded event ring plus per-item publication tokens (`ClipboardService.swift:362-537`) |
| Visible history | `HistoryViewModel` on `@MainActor` | Backend fetch/search | list state plus bounded revision/deletion registry (`HistoryViewModel.swift:24-182`, `275-312`) |

Important distinction: the ingest spool is restart-persistent but is located in the caches domain, not Application Support (`ClipboardMonitor.swift:273-289`). The OS may purge it. File and directory contents are also not explicitly `fsync`ed before ownership advances: the shared writer writes a temp file and renames it, but does not synchronize the file or parent directory (`StorageService.swift:1710-1725`). The current design therefore gives useful process-crash isolation, not a proven power-loss durability contract.

## 2. Canonical clipboard ingest flow

### 2.1 Capture and spool

Call order for an image or content at/above the hash-offload threshold:

1. `ClipboardMonitor.checkClipboard()` detects a changed pasteboard, extracts `RawClipboardData`, and chooses asynchronous handling for every image or payload at least 50 KiB (`ClipboardMonitor.swift:673-725`; `Scopy/Infrastructure/Configuration/ScopyThresholds.swift:5-10`).
2. `processLargeContentAsync` calls `persistPendingEnvelope` before it puts the work in any memory queue (`ClipboardMonitor.swift:731-767`).
3. `persistPendingEnvelope` writes `<id>.payload` first, then writes `<id>.envelope.json` (`ClipboardMonitor.swift:965-986`). Both use the temp-plus-rename helper (`ClipboardMonitor.swift:1006-1009`; `StorageService.swift:1710-1725`).
4. A detached ingest worker loads both artifacts, normalizes TIFF to PNG if needed, computes the hash, and chooses `.data` or `.file` (`ClipboardMonitor.swift:780-870`). The spool-to-file threshold equals the 100 KiB external-storage threshold (`ClipboardMonitor.swift:889-923`; `ScopyThresholds.swift:10`, `19`).
5. If bytes are unchanged and already have a payload file, `buildPayload` reuses the envelope's payload URL rather than copying it (`ClipboardMonitor.swift:835-847`, `899-905`). If bytes changed, it creates a second unrecorded UUID file in the spool directory (`ClipboardMonitor.swift:907-922`).
6. The worker enqueues `ClipboardContent` on the bounded content stream with the envelope URL attached (`ClipboardMonitor.swift:862-872`). The envelope still owns the recoverable capture at this point.

### 2.2 Application preparation and storage

7. `ClipboardService.start()` consumes the monitor stream serially and calls `handleNewContent` (`ClipboardService.swift:905-911`).
8. Disabled image/file policy is an intentional terminal outcome: the payload file is removed and the envelope is acknowledged (`ClipboardService.swift:2053-2068`).
9. Automatic pngquant preparation may replace a file-backed spool payload in place through a temp output plus POSIX `rename` (`ClipboardService.swift:2101-2163`; `PngquantService.swift:153-233`). The envelope continues to point to the same path and will replay the optimized bytes if the process stops before storage.
10. `StorageService.upsertItemWithOutcome` performs a hash lookup. A duplicate commits a usage increment, then removes the ingest file and returns `.updated` (`StorageService.swift:381-395`; `SQLiteClipboardRepository.swift:191-213`).
11. A new payload chooses inline or external storage (`StorageService.swift:397-463`):
    - `.data` at least 100 KiB is copied to a unique managed path while that path is reserved (`StorageService.swift:411-431`). The spool artifact, when one exists, remains recoverable until acknowledgement.
    - `.file` at least 100 KiB is passed to `moveOrCopyFile` (`StorageService.swift:435-455`). The normal same-volume path is a move; the fallback copies and then removes the source (`StorageService.swift:1745-1762`). In either case the envelope's payload path is gone before the database owns the destination.
12. Only after the filesystem step does the repository insert the row (`StorageService.swift:465-479`; `SQLiteClipboardRepository.swift:148-189`). SQLite triggers update persistent FTS and counters in that same transaction.
13. On success, `ClipboardService` rereads the authoritative row, updates the in-memory search indexes, constructs a DTO, and publishes `.newItem` or `.itemUpdated` (`ClipboardService.swift:2073-2092`, `1817-1921`).
14. The envelope is acknowledged only after the publication attempt, then cleanup is scheduled (`ClipboardService.swift:2094-2095`). Acknowledgement removes in-memory tracking first and then best-effort deletes envelope and payload (`ClipboardMonitor.swift:361-372`, `1060-1073`).

### 2.3 Ownership transition table

| State | Envelope | Spool payload | Managed file | DB row | Current recovery |
| --- | --- | --- | --- | --- | --- |
| Payload write started | absent | temp/partial possible | absent | absent | No sweep for standalone spool files or `.tmp` files |
| Envelope committed | present | present when payload exists | absent | absent | Startup replay (`ClipboardMonitor.swift:944-963`) |
| Work enqueued | present | present or derived file present | absent | absent | Replay original envelope; derived file is not recorded |
| External `.data` staged | present | still present | present, unreferenced | absent | Managed orphan cleanup plus spool replay |
| External `.file` moved | present | **missing** | present, unreferenced | absent | Managed orphan cleanup can delete the only bytes; envelope cannot replay |
| Insert committed | present | varies | referenced or inline | present | SQLite reopen; duplicate replay is possible until ack completes |
| Search/UI published | present | varies | referenced or inline | present | Search cache repair; volatile UI event |
| Ack complete | absent | absent | referenced or inline | present | DB fetch on restart |

## 3. Ingest failure map

### F-I1 — P0: spool ownership moves before SQLite commit

The same spool file named by the envelope becomes `ClipboardContent.Payload.file` (`ClipboardMonitor.swift:835-847`, `899-905`). `StorageService` moves that file into managed storage (`StorageService.swift:435-455`, `1745-1762`) and only then begins the insert (`StorageService.swift:465-479`).

If insert or commit fails, the catch path best-effort removes both the managed `storageRef` and the old ingest URL, then rethrows (`StorageService.swift:486-500`). `ClipboardService` deliberately does not acknowledge on storage failure (`ClipboardService.swift:2096-2098`), but the surviving envelope now points to a missing payload. On restart the monitor classifies that as corrupt, acknowledges it, and deletes the envelope (`ClipboardMonitor.swift:802-810`, `989-990`).

Result: no row, no managed file, no spool payload, and no retry. This directly violates the PRD requirement that insert failure leave a replayable payload or a durable terminal idempotent outcome.

The same gap exists for cancellation or process termination after the move and before the insert. A process restart sees a missing spool payload, while startup managed-orphan cleanup is free to remove the unreferenced managed destination (`StorageService.swift:925-927`, `1263-1320`). There is no durable link between the envelope and that destination.

### F-I2 — P0/P1: envelope creation is not a recoverable two-file transaction

`persistPendingEnvelope` writes payload first and envelope second without cleaning the payload if envelope encoding/write fails (`ClipboardMonitor.swift:965-986`). `processLargeContentAsync` only logs and returns false (`ClipboardMonitor.swift:732-739`). `checkClipboard` then leaves `lastChangeCount` unchanged (`ClipboardMonitor.swift:710-714`), so the same pasteboard can be retried every poll and create additional orphan payloads.

Recovery enumerates only `*.envelope.json` (`ClipboardMonitor.swift:1028-1040`). It never sweeps standalone `.payload`, derived `.png/.rtf/.html/.dat`, or writer `.tmp` files. A corrupt envelope with a valid payload is also discarded without knowing the payload filename, so the private payload remains (`ClipboardMonitor.swift:795-810`, `1011-1025`, `1060-1073`). The existing regression explicitly expects a missing-payload envelope to be discarded (`ScopyTests/ClipboardMonitorTests.swift:973-998`); it does not distinguish genuine corruption from the pre-commit ownership loss in F-I1.

### F-I3 — P1: acknowledgement is non-idempotent and its success is unverified

Acknowledgement removes tracking before deleting either durable artifact (`ClipboardMonitor.swift:361-369`). Deletion is best effort and returns no success/failure result (`BestEffortFileOps.swift:4-23`), yet the acknowledged metric is always incremented (`ClipboardMonitor.swift:370-372`).

If the process stops after the DB commit but before both files are removed, the envelope can replay. There is no envelope ID, terminal state, or item ID recorded in SQLite (`PendingIngestEnvelope` has only capture fields at `ClipboardMonitor.swift:218-231`). Replay therefore cannot distinguish “not committed” from “committed but ack interrupted.” Depending on which payload representation survived, it can increment usage again through deduplication or re-run transformation work (`StorageService.swift:381-395`).

### F-I4 — P1 safety: spool filenames and acknowledgement URLs are not contained

Managed `storageRef` values receive UUID/root/symlink validation (`StorageService.swift:1782-1821`). Spool envelope payload names do not. `pendingPayloadURL` and cleanup append the decoded `payloadFileName` directly to the spool directory (`ClipboardMonitor.swift:1042-1057`, `1066-1071`). A malformed local envelope can use path separators/traversal. `acknowledgeIngestEnvelope(at:)` is public and does not verify that the supplied envelope URL itself belongs to the configured spool (`ClipboardMonitor.swift:361-369`).

Even if the threat model treats the cache as same-user trusted input, recovery should not be able to read or delete outside its owned directory.

### F-I5 — P1: derived spool files have no durable owner

When TIFF conversion or another transform changes bytes, `buildPayload` creates a second UUID file that is not named in the envelope (`ClipboardMonitor.swift:835-847`, `907-922`). `cleanupPayloadIfNeeded` exists but has no call site (`ClipboardMonitor.swift:925-928`). If content is queued and the service/consumer stops before storage handles it, the envelope replays the original while the derived file remains untracked. Repeated interruptions can accumulate private data and duplicate transform work.

### F-I6 — P1: accepted external payloads can be unreadable by design

The insert path has no upper payload limit and stores any payload at least 100 KiB externally (`StorageService.swift:404-479`). The read path rejects managed files above 100 MiB (`StorageService.swift:1778-1780`, `1824-1845`). A successfully committed image/RTF/HTML payload over that limit remains visible and searchable but cannot be copied or previewed through `loadPayloadData` (`StorageService.swift:1970-1996`).

`copyRichPayload` silently returns when the load fails, but the outer copy command still increments usage and publishes `.itemUpdated` (`ClipboardService.swift:1131-1159`, `1186-1215`). Delete/optimize races can produce the same false-success shape: the row is fetched, its file disappears before load, no pasteboard write occurs, and the command still returns normally.

## 4. Explicit image optimization and replacement

### 4.1 Inline image sequence

1. Read the row and inline data (`ClipboardService.swift:1455-1514`).
2. Compress in a cancellation-aware detached task (`ClipboardService.swift:1537-1553`).
3. Compute new hash/size and CAS the exact payload snapshot (`ClipboardService.swift:1565-1575`; `SQLiteClipboardRepository.swift:248-300`). Metadata-only changes intentionally do not invalidate payload ownership.
4. Reread/publish authoritative search and UI state. Return `.optimized` only if the published payload still matches the committed result (`ClipboardService.swift:1576-1585`, `1801-1814`).

This path has no filesystem split-brain window. A missing row or competing payload is currently reported as the same “superseded” optional-nil outcome.

### 4.2 External image sequence

1. Validate the source managed path and copy it to a unique hidden `.scopy-optimize-<UUID>.stage` (`ClipboardService.swift:1595-1627`).
2. Hash the staged source, optionally transcode, compress only the stage, and require a smaller complete output (`ClipboardService.swift:1628-1684`).
3. Acquire a process-wide lease for the original source and verify that live bytes still match the staged fingerprint (`ClipboardService.swift:1685-1732`; `StorageService.swift:651-685`).
4. Rename the complete stage to a new UUID-named managed path and CAS the row from its exact input payload to the new path (`ClipboardService.swift:1734-1751`; `StorageService.swift:603-649`). The old path is never overwritten or eagerly removed.
5. Recheck the old source. If an external writer won, attempt to adopt stable live bytes; if the source is unstable, restore the known optimized row before retry/exit (`ClipboardService.swift:1753-1787`, `1938-1967`; `StorageService.swift:687-855`).
6. Synchronize search, build a current DTO, enqueue the event, and only then return proof of optimization (`ClipboardService.swift:1789-1814`).

### 4.3 Existing crash/recovery behavior

| Crash/failure point | Current result |
| --- | --- |
| During stage copy/compression | Old row/file remain authoritative; hidden stage may remain and is eligible only after 24 hours (`StorageService.swift:1373-1402`) |
| After new-file rename, before CAS | Old row/file remain; new UUID file is an orphan reclaimed by full/startup orphan cleanup (`StorageService.swift:1263-1320`) |
| CAS conflict or normal repository error | New file is removed and old row/file remain (`StorageService.swift:636-647`) |
| After CAS, before any old-file reclamation | Row points to complete new file; old file remains as a safe orphan |
| Source changed after CAS | Bounded adoption/restore loop attempts to leave the row on verified bytes (`StorageService.swift:742-855`) |
| Search/UI publication loses a later race | Search is repaired from the current row; optimized proof is suppressed (`ClipboardService.swift:1801-1921`) |

### 4.4 Residual replacement risks

- `compareAndSwapItemPayload` returns `nil` for both row deletion and payload conflict (`SQLiteClipboardRepository.swift:255-300`). Recovery and caller reporting cannot distinguish them.
- A repository throw is treated as proof that CAS did not commit, and the new file is unconditionally removed (`StorageService.swift:643-647`). The repository attempts rollback and reopen if rollback itself fails (`SQLiteClipboardRepository.swift:1094-1130`), but the storage layer does not reread after an ambiguous commit before deleting the candidate file. An uncertain commit can therefore leave a row referencing a removed file.
- Neither stage publication nor final publication explicitly synchronizes file and directory metadata (`StorageService.swift:1710-1743`). POSIX rename gives atomic namespace replacement within the filesystem, not a documented power-loss barrier here.
- Old files are reclaimed only by generic orphan scans, launched best-effort at startup and on full cleanup (`ClipboardService.swift:925-927`; `StorageService.swift:1241-1252`). There is no exact post-commit delete intent, completion record, or retry counter.
- Content-hash deduplication is lookup-only; `content_hash` has a non-unique index (`SQLiteMigrations.swift:235-244`). Optimization can produce the same hash as another row without coalescing it.

## 5. Repository mutation semantics

| Repository method | Transaction behavior | Returned authority | Gap relevant to side effects |
| --- | --- | --- | --- |
| `insertItem` (`SQLiteClipboardRepository.swift:148-189`) | Unconditional write transaction | `Void` | No commit token/item returned; caller synthesizes the row (`StorageService.swift:503-520`) |
| `incrementUsageReturningCurrent` (`SQLiteClipboardRepository.swift:191-213`) | Fetch/update/reread in conditional transaction | current row or nil | Good missing-row signal; no envelope idempotency key |
| `updatePin` (`SQLiteClipboardRepository.swift:215-223`) | Unconditional update transaction | `Void` | Missing row still looks successful and still bumps `mutation_seq`; ClipboardService applies search pin side effect before reread (`ClipboardService.swift:1035-1056`) |
| raw `updateItemPayload` (`SQLiteClipboardRepository.swift:225-246`) | Unconditional ID update | `Void` | No missing/conflict outcome; currently production-unreferenced but remains an unsafe seam (`StorageService.swift:563-577`) |
| payload CAS (`SQLiteClipboardRepository.swift:248-300`) | exact payload compare + update + returned row | row or nil | `notFound` and `conflict` conflated |
| note update (`SQLiteClipboardRepository.swift:302-305`, `1133-1167`) | current-row update + reread | row or nil | Last-writer-wins; no conflict kind, although publication rereads authority |
| file-size update (`SQLiteClipboardRepository.swift:307-315`, `1133-1167`) | expected payload compare + update | row or nil | `notFound`, unchanged, and conflict are conflated |
| delete one (`SQLiteClipboardRepository.swift:327-348`) | captures ref and deletes in one transaction | optional ref | Existing inline row and nonexistent row both return nil; caller always publishes deletion (`ClipboardService.swift:1082-1092`) |
| clear unpinned (`SQLiteClipboardRepository.swift:356-371`) | captures refs and deletes with the pin predicate in one transaction | captured refs | Correctly preserves the transaction boundary; no actual deleted IDs for per-item events |
| cleanup plan + batch delete (`SQLiteClipboardRepository.swift:832-1065`) | selection outside later unconditional ID-delete transaction | no actual deleted set | Plan can become stale; captured refs can differ from deleted row state |

`performWriteTransaction` always increments `mutation_seq` after its body, even if an `UPDATE` or `DELETE` changed zero rows (`SQLiteClipboardRepository.swift:1090-1109`). The connection already exposes `sqlite3_changes` (`SQLiteConnection.swift:97-100`), but most mutation methods do not use it to construct a typed result.

## 6. Cleanup and deletion failure map

### F-D1 — P0: cleanup can delete an item that became pinned

All cleanup planners select only rows where `is_pinned = 0` (`SQLiteClipboardRepository.swift:848-870`, `878-901`, `914-953`, `996-1032`, `1038-1061`). The selected IDs and storage refs are returned to `StorageService`. Later, `applyDeletePlan` calls `deleteItemsBatchInTransaction(ids:)`, whose SQL deletes solely by ID (`StorageService.swift:1457-1478`; `SQLiteClipboardRepository.swift:1064-1073`, `1293-1304`).

Both `ClipboardService` and `StorageService` are reentrant across these awaits. A user pin can commit after plan selection and before batch deletion. The unconditional delete then removes the newly pinned row. By contrast, `deleteAllExceptPinnedReturningStorageRefs` performs select and predicate-based delete in one transaction (`SQLiteClipboardRepository.swift:356-371`) and does not have this particular gap.

The same stale-plan structure can delete a row after an optimization changed its payload and can delete a different ref than the row owned at deletion time. The newly committed payload then becomes an orphan; the old captured ref is removed.

### F-D2 — P1: successful cleanup leaves visible ghost rows

Scheduled cleanup compares only item counts and invalidates search caches when the count changed (`ClipboardService.swift:2202-2224`). It does not publish `.itemDeleted`, `.itemsCleared`, or a reload event. `HistoryViewModel` therefore retains deleted rows in the unfiltered visible list until another load or operation happens. Copying such a row can silently do nothing yet still return success through F-I6.

The persistent FTS index is correct because deletion triggers run in the SQLite transaction, and the next search is protected by invalidation. The visible list is the stale projection.

### F-D3 — P1: DB-first deletion is safe but cleanup completion is best effort

Explicit delete captures and removes the row transactionally, then validates/removes the external file (`StorageService.swift:875-906`). Clear-all does the same for all unpinned refs with bounded deletion (`StorageService.swift:908-930`). This correctly favors a DB-committed deletion plus an orphan over a live row with a missing file.

If file removal fails or the process stops after DB commit, only the later orphan scan repairs the leak. File-removal failure is logged but not durably queued, and explicit delete does not invalidate the external-size cache (`StorageService.swift:875-906`). Startup orphan cleanup is unawaited and errors are discarded (`ClipboardService.swift:925-927`), so privacy-sensitive old bytes may remain for an unbounded number of failed cleanup attempts.

## 7. Search synchronization

### 7.1 Durable search state

SQLite FTS and trigram FTS are external-content tables maintained by insert/delete/update triggers (`SQLiteMigrations.swift:247-289`, `292-344`). Because triggers execute in the repository transaction, a committed row mutation and its durable text index do not depend on a later application callback.

### 7.2 In-memory search state

`SearchEngineImpl` owns a separate read-only SQLite connection plus recent, short-query, and full fuzzy indexes (`SearchEngineImpl.swift:901-950`, `3734-3766`). Post-commit callbacks update or invalidate those projections:

- upsert: `SearchEngineImpl.swift:1050-1089`
- pin: `SearchEngineImpl.swift:1091-1116`
- delete: `SearchEngineImpl.swift:1118-1151`
- clear/invalidate: `SearchEngineImpl.swift:1041-1048`, `1153-1186`

The engine records the repository `mutation_seq`. A callback accepts the expected `+1` commit; larger/unobserved deltas reset in-memory indexes, and every search also checks for external changes (`SearchEngineImpl.swift:1722-1789`). Reopen rebuilds from SQLite. Thus an app crash after DB commit but before callback does not corrupt durable search.

`ClipboardService.synchronizeSearchWithCurrentItem` rereads before and after each upsert, repairs up to three times, deletes from search if the row vanished, and invalidates all search caches if state remains unstable (`ClipboardService.swift:1876-1921`). This is a strong eventual-authority guard.

### F-S1 — P1: a committed mutation can have no immediate projection event

If the three-pass repair cannot stabilize or a storage read fails, search is invalidated and `publishAuthoritativeItemState` discards the UI publication when a row still exists (`ClipboardService.swift:1824-1840`, `1883-1921`). Ingest ignores the publication result and still acknowledges the envelope (`ClipboardService.swift:2073-2095`). The database and persistent FTS are safe, but the current UI can miss the item until a later reload. There is no durable outbox or “reload required” event.

### F-S2 — P1: size-only external reconciliation deliberately leaves hash/projections inconsistent

The supported “external image size sync” explicitly updates only `size_bytes`, not `content_hash` (`StorageService.swift:971-1021`). `ClipboardService` logs a count but emits no item event or search callback (`ClipboardService.swift:1440-1447`). If the external bytes were actually replaced, DB hash, thumbnail key, dedup identity, and payload bytes can disagree. The CAS protects against overwriting a newer payload tuple, but it does not validate file content.

## 8. UI event flow and ghost-event risks

### 8.1 Current flow

1. A mutation commits in storage/repository.
2. `publishAuthoritativeItemState` reserves a per-item publication token (`ClipboardService.swift:1817-1825`).
3. Search is synchronized against the current row (`ClipboardService.swift:1825-1840`, `1876-1921`).
4. A DTO/event is built from that row and enqueued (`ClipboardService.swift:1842-1873`).
5. `AppState` consumes the process-memory stream and forwards item events to `HistoryViewModel` (`AppState.swift:226-246`).
6. `HistoryViewModel` merges, removes, or tombstones items (`HistoryViewModel.swift:457-574`). The bounded revision registry suppresses stale async projections after deletion (`HistoryViewModel.swift:24-182`, `1140-1187`).

The event queue is bounded at 2,048 and backpressures senders rather than dropping on capacity (`ClipboardService.swift:384-468`; `ScopyThresholds.swift:22`). A later token suppresses an older publication that has not yet enqueued, and clear-generation invalidation rejects outstanding pre-clear tokens (`ClipboardService.swift:401-425`, `449-468`, `504-518`).

### F-U1 — P1: token order is not commit order

Publication tokens are reserved after the database mutation and often after another actor hop. For example, delete commits the row removal, awaits `search.handleDeletion`, and only then reserves its token (`ClipboardService.swift:1082-1091`). Other mutations similarly enter publication after commit (`ClipboardService.swift:1035-1051`, `1059-1079`, `1565-1579`).

An older mutation can therefore enqueue a DTO after a newer delete/replace committed but before the newer operation reserves its token. The later event normally corrects the UI, but the queue can transiently deliver a ghost row/state, and cancellation/stop between the two publications leaves the in-session projection stale. The row has no monotonic revision/commit sequence in either `ClipboardStoredItem`, `ClipboardItemDTO`, or `ClipboardEvent` (`ClipboardStoredItem.swift:5-20`; `ClipboardEvent.swift:4-18`).

### F-U2 — P1: event acceptance is not durable completion

Once an event is buffered, the publication token is completed (`ClipboardService.swift:459-468`). There is no consumer acknowledgement or replay log. A process stop loses buffered events; restart correctness relies on `AppState.start()` subscribing and then loading current rows (`AppState.swift:179-199`). That is sufficient for restart convergence, not for same-session guarantee after a publication failure.

### F-U3 — P1: search-membership changes are not represented by `itemContentUpdated`

Note updates change persistent FTS membership, but `HistoryViewModel` handles `.itemContentUpdated` only if the item is already visible and never reruns active search or re-evaluates filters (`HistoryViewModel.swift:530-539`). A note edit can therefore leave an item in results that it no longer matches, or omit one that now matches, even though SQLite/search authority is current. Cleanup has the broader no-event variant in F-D2.

### Existing UI protections

- Deletion records a bounded tombstone and cancels stale search/load/refine work (`HistoryViewModel.swift:540-551`, `1140-1187`).
- Thumbnail events carry expected type/hash and are ignored if the visible content revision changed (`HistoryViewModel.swift:479-507`).
- `itemUpdated` / `itemContentUpdated` refuse to revive a known deleted ID (`HistoryViewModel.swift:508-539`).
- `newItem` may explicitly revive a deleted ID (`HistoryViewModel.swift:459-460`); safety therefore depends on backend token/event ordering for same-ID stale new-item events.

## 9. Restart and recovery inventory

| Recovery mechanism | What it proves | What it does not prove |
| --- | --- | --- |
| SQLite WAL open with `synchronous=NORMAL` (`SQLiteClipboardRepository.swift:78-100`) | SQLite-consistent committed rows/FTS after ordinary process restart | Managed file existence/hash/size; power-loss durability of file+DB pair |
| Spool envelope replay (`ClipboardMonitor.swift:944-963`) | Re-enqueues decodable envelopes whose named payload still exists | Idempotent prior commit, moved payload recovery, corrupted envelope quarantine, orphan payload sweep |
| Managed orphan cleanup (`StorageService.swift:1263-1320`) | Deletes unreferenced non-hidden files after repeated DB reference checks and path reservations | Rows whose referenced file is missing/corrupt; exact old-file delete completion; spool artifacts |
| Optimization-stage cleanup (`StorageService.swift:1373-1402`) | Reclaims narrowly named hidden stages older than 24 hours | Immediate stage cleanup or durable transform state |
| External source reconciliation (`StorageService.swift:687-855`) | Repairs a live post-CAS source race while process state/leases exist | Recovery after restart from a dangling or hash-mismatched row |
| Search mutation token (`SearchEngineImpl.swift:1722-1789`) | Invalidates in-memory indexes when SQLite changed without matching callbacks | UI list reconciliation |
| UI initial load (`AppState.swift:179-199`; `HistoryViewModel.swift:634-677`) | Rebuilds visible rows from current DB on restart | In-session event loss/cleanup ghosts |

There is no startup pass that verifies every external row has a regular managed file whose bytes match `content_hash` and `size_bytes`. `cleanupOrphanedFiles` is one-directional: file → DB reference. `loadPayloadData` detects a failed read only when a user action happens, returns nil, and leaves the row untouched (`StorageService.swift:1970-1996`).

## 10. Race narratives that must become deterministic tests

### R1: external insert failure after spool move

1. Envelope and `<id>.payload` committed.
2. Worker reuses `<id>.payload` as `.file`.
3. Storage moves it to `content/<item-id>.png`.
4. Inject insert/COMMIT failure.
5. Catch removes managed file; envelope remains.
6. Restart discards missing-payload envelope.

Expected future invariant: exactly one recoverable owner remains until a typed committed/duplicate terminal result is durable.

### R2: crash after DB commit before ack

1. DB row and persistent FTS commit.
2. Stop before envelope and payload deletion complete.
3. Restart replays the envelope.

Expected future invariant: replay identifies the committed envelope without incrementing use count, changing recency, inserting another row, or republishing a false “new” event.

### R3: pin between cleanup plan and delete

1. Cleanup plan selects unpinned ID/ref.
2. User pin transaction commits.
3. Cleanup deletes by ID only.

Expected future invariant: the delete result reports conflict/skipped and neither row nor payload is removed.

### R4: delete/cleanup versus optimize publication

1. Optimization publishes unique new file and CAS commits.
2. Delete or cleanup wins before/after search synchronization.
3. Verify row, old/new files, search, outcome proof, and UI event all converge.

Current explicit delete plus payload CAS generally converges through DB serialization and authoritative rereads, but cleanup uses a stale plan and emits no event.

### R5: note/search membership versus delete/event ordering

1. Note commit changes FTS membership.
2. Pause before publication.
3. Delete commits and/or active search runs.
4. Release publications in both orders.

Expected future invariant: no event older than the DB commit sequence is applied; active search membership matches the committed row set.

### R6: dangling managed reference on restart

1. Commit row referencing an external file.
2. Remove/corrupt file or inject ambiguous COMMIT/file-cleanup outcome.
3. Restart.

Expected future invariant: startup deterministically restores from a retained source, rolls back to a valid version, or marks a bounded terminal repair state; it must not silently keep a searchable/copyable-looking row with no payload.

## 11. Existing tests and missing evidence

Current coverage is strongest for image replacement:

- same-ID inline/external CAS races and immutable UUID payloads (`ScopyTests/ClipboardServiceImageOptimizationTests.swift:160-333`)
- concurrent metadata and post-CAS payload publication repair (`ClipboardServiceImageOptimizationTests.swift:334-373`, `474-577`)
- external source change/deletion reconciliation (`ClipboardServiceImageOptimizationTests.swift:578-762`)
- orphan cleanup reservation races and size-reconciliation races (`ScopyTests/StorageServiceTests.swift:1238-1420`)
- event queue suppression when a newer token is already reserved (`ScopyTests/ThumbnailPipelineTests.swift:265-316`)
- envelope replay across monitor restart (`ScopyTests/ClipboardMonitorTests.swift:892-933`)

Missing direct evidence:

- insert/COMMIT failure after `.file` spool move
- process restart at every envelope payload/envelope/queue/move/insert/ack boundary
- ack deletion failure and duplicate replay idempotency
- orphan spool/derived/temp reclamation
- payload filename containment
- cleanup plan racing pin, payload CAS, note, and explicit delete
- actual deleted-ID/ref results from batch cleanup
- ambiguous commit reread before candidate-file deletion
- dangling external row recovery and hash/size verification
- >100 MiB stored payload replay/copy behavior
- event ordering where the newer DB commit has not reserved its publication token yet
- cleanup-driven visible-list convergence
- note edits entering/leaving active search results

The current test seams are also uneven. Image optimization has application and storage interlocks (`ClipboardService.swift:648-660`, `758-759`; `StorageService.swift:140-148`, `228-229`), and deletion injects only a file remover (`StorageService.swift:176-188`). Normal insert file write/move, repository begin/body/commit/rollback, envelope persist/ack, and process-restart transitions have no deterministic fault-injection interface.

## 12. Required protocol properties derived from current evidence

The implementation phase should not patch only image optimization; that path is already the strongest one. A systemic protocol must provide all of the following:

1. **One durable mutation identity.** Envelope ID (or equivalent idempotency key) must survive into the repository result so replay can return the same terminal result without changing user-visible usage/recency twice.
2. **Copy/immutable publication before transfer.** The last replayable spool payload cannot be moved or deleted before DB commit. A managed candidate is provisional until a typed repository outcome commits.
3. **Typed repository results.** At minimum: `inserted`, `deduplicated`, `updated`, `notFound`, `conflict`, and an explicitly handled uncertain/failure state. Delete/cleanup must return the rows/refs actually deleted in the transaction.
4. **Conditional cleanup in one transaction.** Pin/payload/revision predicates used during planning must be revalidated by the delete that returns actual refs; stale plans are advisory only.
5. **Post-commit side effects from a commit identity.** Search projections and UI events must be derived from committed authority, and stale events need a monotonic row/global mutation sequence rather than only in-memory reservation order.
6. **Bounded restart reconciliation in both directions.** Reclaim unreferenced candidates/stages and detect referenced-but-missing/hash-mismatched payloads. Never guess from arbitrary filenames or content outside validated owned roots.
7. **Explicit acknowledgement result.** Ack should be durable/idempotent, containment-checked, and observable; failed cleanup remains retryable without reapplying the logical mutation.
8. **Failure injection at every ownership edge.** Payload write, envelope write, candidate copy/rename, DB begin/body/commit/rollback, post-commit delete, search update, event enqueue, ack, and restart must each be independently stoppable in tests.
9. **Copy uses a valid snapshot or fails.** A copy command must not increment usage or report success if no payload was written to the pasteboard.
10. **No user-visible shape drift.** `ClipboardItemDTO`, item IDs, copy/paste semantics, optimization outcome surface, search ranking, and normal list behavior can remain unchanged; the typed state machine can stay internal.

## Bottom line

The current immutable/CAS optimization design should be reused as the baseline, but it is not yet a complete storage commit protocol. External ingest, cleanup, repository outcome typing, and volatile projection publication still have independent ownership rules. Until those four paths share one idempotent commit identity and conditional transaction result, crash/retry and actor reentrancy can still produce lost captures, deleted pinned items, dangling payload references, stale search/UI state, and non-auditable recovery.
