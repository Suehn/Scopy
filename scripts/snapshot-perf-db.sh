#!/bin/bash
# Snapshot Scopy's real clipboard.db for realistic performance testing.
#
# Default source:
#   ~/Library/Application Support/Scopy/clipboard.db
#
# Default destination (repo-local, ignored by git):
#   ./perf-db/clipboard.db

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DB_DEFAULT="${HOME}/Library/Application Support/Scopy/clipboard.db"
DEST_DB_DEFAULT="${PROJECT_DIR}/perf-db/clipboard.db"

SOURCE_DB="${SOURCE_DB_DEFAULT}"
DEST_DB="${DEST_DB_DEFAULT}"

print_help() {
    cat <<EOF
Snapshot Scopy clipboard database for local performance benchmarks.

Usage:
  bash scripts/snapshot-perf-db.sh [--source <path>] [--dest <path>]

Defaults:
  --source  ${SOURCE_DB_DEFAULT}
  --dest    ${DEST_DB_DEFAULT}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SOURCE_DB="${2:-}"
            shift 2
            ;;
        --dest)
            DEST_DB="${2:-}"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "" >&2
            print_help >&2
            exit 2
            ;;
    esac
done

if [[ -z "${SOURCE_DB}" ]]; then
    echo "Error: --source must not be empty" >&2
    exit 2
fi
if [[ -z "${DEST_DB}" ]]; then
    echo "Error: --dest must not be empty" >&2
    exit 2
fi

if [[ ! -f "${SOURCE_DB}" ]]; then
    echo "Error: source db not found: ${SOURCE_DB}" >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "Error: sqlite3 is required but not found in PATH" >&2
    exit 1
fi

DEST_DIR="$(dirname "${DEST_DB}")"
mkdir -p "${DEST_DIR}"

TMP_DB="${DEST_DB}.tmp.$$"
cleanup() {
    rm -f "${TMP_DB}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Snapshotting:"
echo "  from: ${SOURCE_DB}"
echo "  to:   ${DEST_DB}"

# Use SQLite online backup API via sqlite3 CLI to avoid WAL/SHM inconsistencies.
sqlite3 "${SOURCE_DB}" ".timeout 10000" ".backup ${TMP_DB}"
mv -f "${TMP_DB}" "${DEST_DB}"
# Remove stale WAL/SHM files that may belong to an older snapshot.
rm -f "${DEST_DB}-wal" "${DEST_DB}-shm" 2>/dev/null || true
# Ensure WAL/SHM files exist for read-only connections (Scopy search engine opens DB with query_only=1).
sqlite3 "${DEST_DB}" "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

# Best-effort: prepare optional trigram FTS table for substring-heavy search benchmarks.
# This mirrors app-side migrations while keeping the snapshot workflow lightweight.
if sqlite3 "${DEST_DB}" "SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts_trigram';" | grep -q "clipboard_fts_trigram"; then
    :
else
    if sqlite3 "${DEST_DB}" "CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts_trigram USING fts5(plain_text, note, content='clipboard_items', content_rowid='rowid', tokenize='trigram');" >/dev/null 2>&1; then
        sqlite3 "${DEST_DB}" "CREATE TRIGGER IF NOT EXISTS clipboard_trigram_ai AFTER INSERT ON clipboard_items BEGIN INSERT INTO clipboard_fts_trigram(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note); END;" >/dev/null
        sqlite3 "${DEST_DB}" "CREATE TRIGGER IF NOT EXISTS clipboard_trigram_ad AFTER DELETE ON clipboard_items BEGIN INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note); END;" >/dev/null
        sqlite3 "${DEST_DB}" "DROP TRIGGER IF EXISTS clipboard_trigram_au;" >/dev/null
        sqlite3 "${DEST_DB}" "CREATE TRIGGER clipboard_trigram_au AFTER UPDATE OF plain_text, note ON clipboard_items WHEN OLD.plain_text IS NOT NEW.plain_text OR OLD.note IS NOT NEW.note BEGIN INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note); INSERT INTO clipboard_fts_trigram(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note); END;" >/dev/null
        sqlite3 "${DEST_DB}" "INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram) VALUES('rebuild');" >/dev/null
    else
        echo "Warning: SQLite trigram tokenizer not available; skip clipboard_fts_trigram build." >&2
    fi
fi

bytes="$(wc -c < "${DEST_DB}" | tr -d ' ')"
echo "Done: ${DEST_DB} (${bytes} bytes)"
