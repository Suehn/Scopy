#!/usr/bin/env python3
"""Extract ChatGPT Markdown rendering evidence from a WACZ capture.

The script is intentionally dependency-free so it can run on a clean macOS
checkout. It extracts WARC response bodies, identifies the conversation JSON,
exports every assistant Markdown message plus a primary longest-message
compatibility file, and writes structured table / CSS / JS inventories that
respect escaped pipes and pipes inside code spans.
"""

from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import gzip
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Iterable
from urllib.parse import urlparse
from zipfile import ZipFile


CSS_JS_PATTERNS = (
    ".markdown",
    "markdown",
    "markdown-new-styling",
    "wrap-break-word",
    ".prose",
    "blockquote",
    "code",
    "pre",
    "hljs",
    "katex",
    "citation",
    "webpage-citation-pill",
    "task",
    "checkbox",
    "table",
    "TableContainer",
    "TableWrapper",
    "Jc7teW",
    ":where(code)",
    "TyagGW_tableContainer",
    "thread-content",
    "min-w-(--thread-content-width)",
    "data-col-size",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wacz", type=Path, help="Path to a ChatGPT WACZ file")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Extraction directory. Defaults to /tmp/scopy-wacz-extract/<stem>-<date>.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Remove the output directory before extraction.",
    )
    return parser.parse_args()


def safe_slug(url: str, index: int) -> str:
    parsed = urlparse(url)
    source = "_".join(part for part in (parsed.netloc, parsed.path, parsed.query) if part)
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", source).strip("_") or "record"
    return f"{index:04d}_{slug[:160]}"


def extension_for(url: str, mime: str) -> str:
    path = urlparse(url).path.lower()
    if path.endswith(".css") or "text/css" in mime:
        return ".css"
    if path.endswith(".js") or "javascript" in mime:
        return ".js"
    if path.endswith(".html") or "text/html" in mime:
        return ".html"
    if path.endswith(".json") or "json" in mime:
        return ".json"
    if path.endswith(".svg") or "svg" in mime:
        return ".svg"
    if path.endswith(".png") or "png" in mime:
        return ".png"
    if path.endswith(".jpg") or path.endswith(".jpeg") or "jpeg" in mime:
        return ".jpg"
    if path.endswith(".webp") or "webp" in mime:
        return ".webp"
    return ".bin"


def split_http_payload(payload: bytes) -> tuple[dict[str, str], bytes]:
    marker = b"\r\n\r\n"
    if marker not in payload:
        marker = b"\n\n"
    if marker not in payload:
        return {}, payload
    header_blob, body = payload.split(marker, 1)
    headers: dict[str, str] = {}
    for raw_line in header_blob.splitlines()[1:]:
        if b":" not in raw_line:
            continue
        key, value = raw_line.split(b":", 1)
        headers[key.decode("latin1").strip().lower()] = value.decode("latin1").strip()
    return headers, body


def iter_warc_content_records(wacz_path: Path) -> Iterable[dict[str, object]]:
    with ZipFile(wacz_path) as archive:
        with archive.open("archive/data.warc.gz") as compressed:
            with gzip.GzipFile(fileobj=compressed) as warc:
                index = 0
                while True:
                    line = warc.readline()
                    if not line:
                        break
                    if not line.strip():
                        continue
                    if not line.startswith(b"WARC/"):
                        continue

                    headers: dict[str, str] = {}
                    while True:
                        header_line = warc.readline()
                        if not header_line or not header_line.strip():
                            break
                        if b":" not in header_line:
                            continue
                        key, value = header_line.split(b":", 1)
                        headers[key.decode("latin1").strip()] = value.decode("latin1").strip()

                    length = int(headers.get("Content-Length", "0") or "0")
                    payload = warc.read(length)
                    record_type = headers.get("WARC-Type", "")
                    if record_type not in ("response", "resource"):
                        continue

                    index += 1
                    if record_type == "response":
                        http_headers, body = split_http_payload(payload)
                    else:
                        http_headers = {"content-type": headers.get("Content-Type", "")}
                        body = payload
                    yield {
                        "index": index,
                        "record_type": record_type,
                        "url": headers.get("WARC-Target-URI", ""),
                        "date": headers.get("WARC-Date", ""),
                        "warc_headers": headers,
                        "http_headers": http_headers,
                        "body": body,
                    }


def scan_warc_record_counts(wacz_path: Path) -> dict[str, int]:
    counts: Counter[str] = Counter()
    with ZipFile(wacz_path) as archive:
        with archive.open("archive/data.warc.gz") as compressed:
            with gzip.GzipFile(fileobj=compressed) as warc:
                while True:
                    line = warc.readline()
                    if not line:
                        break
                    if not line.strip():
                        continue
                    if not line.startswith(b"WARC/"):
                        continue

                    headers: dict[str, str] = {}
                    while True:
                        header_line = warc.readline()
                        if not header_line or not header_line.strip():
                            break
                        if b":" not in header_line:
                            continue
                        key, value = header_line.split(b":", 1)
                        headers[key.decode("latin1").strip()] = value.decode("latin1").strip()

                    record_type = headers.get("WARC-Type", "unknown") or "unknown"
                    counts[record_type] += 1
                    length = int(headers.get("Content-Length", "0") or "0")
                    if length > 0:
                        warc.read(length)
    return dict(sorted(counts.items()))


def decode_text(raw: bytes) -> str:
    for encoding in ("utf-8", "utf-8-sig", "latin1"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def assistant_markdown_messages_from_conversation(data: dict[str, object]) -> list[dict[str, object]]:
    mapping = data.get("mapping")
    if not isinstance(mapping, dict):
        return []
    candidates: list[dict[str, object]] = []
    for node_id, node in mapping.items():
        if not isinstance(node, dict):
            continue
        message = node.get("message")
        if not isinstance(message, dict):
            continue
        author = message.get("author")
        if not isinstance(author, dict) or author.get("role") != "assistant":
            continue
        content = message.get("content")
        if not isinstance(content, dict):
            continue
        parts = content.get("parts")
        if isinstance(parts, list):
            text = "\n".join(part for part in parts if isinstance(part, str)).strip()
            if text:
                create_time = message.get("create_time")
                candidates.append(
                    {
                        "node_id": str(node_id),
                        "create_time": create_time if isinstance(create_time, (int, float)) else None,
                        "chars": len(text),
                        "markdown": text,
                    }
                )
    candidates.sort(key=lambda item: (item.get("create_time") is None, item.get("create_time") or 0, item.get("node_id") or ""))
    return candidates


def assistant_markdown_from_conversation(data: dict[str, object]) -> str:
    messages = assistant_markdown_messages_from_conversation(data)
    return str(max(messages, key=lambda item: int(item.get("chars", 0)), default={}).get("markdown", ""))


def fence_mask(lines: list[str]) -> list[bool]:
    mask: list[bool] = []
    in_fence = False
    fence_marker = ""
    for line in lines:
        stripped = line.lstrip()
        starts = stripped.startswith("```") or stripped.startswith("~~~")
        if starts:
            marker = stripped[:3]
            mask.append(True)
            if in_fence and marker == fence_marker:
                in_fence = False
                fence_marker = ""
            elif not in_fence:
                in_fence = True
                fence_marker = marker
            continue
        mask.append(in_fence)
    return mask


def split_table_row(row: str) -> list[str]:
    text = row.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|") and not text.endswith(r"\|"):
        text = text[:-1]

    cells: list[str] = []
    current: list[str] = []
    code_run = 0
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\":
            if i + 1 < len(text):
                current.append(text[i : i + 2])
                i += 2
                continue
        if char == "`":
            j = i
            while j < len(text) and text[j] == "`":
                j += 1
            run_len = j - i
            run = text[i:j]
            if run_len >= 3:
                current.append(run)
                i = j
                continue
            if code_run == 0:
                if text.find(run, j) != -1:
                    code_run = run_len
            elif code_run == run_len:
                code_run = 0
            current.append(text[i:j])
            i = j
            continue
        if char == "|" and code_run == 0:
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        i += 1
    cells.append("".join(current).strip())
    return cells


def is_separator_cell(cell: str) -> bool:
    return bool(re.fullmatch(r":?-{3,}:?", cell.replace(" ", "")))


def normalize_cell_text(cell: str) -> str:
    text = re.sub(r"`+", "", cell)
    text = text.replace(r"\|", "|")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def column_size(length: int) -> str:
    if length > 160:
        return "xl"
    if length > 100:
        return "lg"
    if length > 40:
        return "md"
    return "sm"


def extract_tables(markdown: str) -> list[dict[str, object]]:
    lines = markdown.splitlines()
    fenced = fence_mask(lines)
    tables: list[dict[str, object]] = []
    i = 0
    while i < len(lines) - 1:
        if fenced[i] or fenced[i + 1] or "|" not in lines[i] or "|" not in lines[i + 1]:
            i += 1
            continue
        header = split_table_row(lines[i])
        separator = split_table_row(lines[i + 1])
        if len(header) < 2 or len(header) != len(separator) or not all(is_separator_cell(cell) for cell in separator):
            i += 1
            continue

        rows: list[list[str]] = []
        j = i + 2
        while j < len(lines) and not fenced[j] and "|" in lines[j] and lines[j].strip():
            cells = split_table_row(lines[j])
            if len(cells) != len(header):
                break
            rows.append(cells)
            j += 1

        columns = len(header)
        all_rows = [header] + rows
        max_lengths = [
            max((len(normalize_cell_text(row[col])) for row in all_rows if col < len(row)), default=0)
            for col in range(columns)
        ]
        total_length = sum(max_lengths)
        max_length = max(max_lengths, default=0)
        inventory_overflow_hint = columns >= 4 or (columns >= 3 and (max_length >= 40 or total_length >= 96))
        tables.append(
            {
                "start_line": i + 1,
                "end_line": j,
                "columns": columns,
                "data_rows": len(rows),
                "header": header,
                "max_cell_text_lengths": max_lengths,
                "wacz_column_sizes": [column_size(length) for length in max_lengths],
                "inventory_overflow_hint": inventory_overflow_hint,
            }
        )
        i = j
    return tables


def write_relevant_css_js(out_dir: Path, extracted: list[dict[str, object]]) -> Path:
    target = out_dir / "relevant-css-js-lines.txt"
    lines: list[str] = []
    for item in extracted:
        path = Path(str(item["path"]))
        if path.suffix not in (".css", ".js"):
            continue
        text = decode_text(path.read_bytes())
        for line_number, line in enumerate(text.splitlines(), start=1):
            if any(pattern in line for pattern in CSS_JS_PATTERNS):
                snippet = line.strip()
                if len(snippet) > 260:
                    snippet = snippet[:257] + "..."
                lines.append(f"{path.name}:{line_number}: {snippet}")
    target.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return target


def write_css_js_coverage(out_dir: Path, extracted: list[dict[str, object]]) -> Path:
    target = out_dir / "markdown-css-js-coverage.json"
    files: list[dict[str, object]] = []
    totals: Counter[str] = Counter()
    for item in extracted:
        path = Path(str(item["path"]))
        if path.suffix not in (".css", ".js"):
            continue
        text = decode_text(path.read_bytes())
        matches: dict[str, int] = {}
        for pattern in CSS_JS_PATTERNS:
            count = text.count(pattern)
            if count:
                matches[pattern] = count
                totals[pattern] += count
        if matches:
            files.append(
                {
                    "path": str(path),
                    "content_type": item.get("content_type"),
                    "bytes": path.stat().st_size,
                    "matches": dict(sorted(matches.items())),
                }
            )
    payload = {
        "patterns": list(CSS_JS_PATTERNS),
        "matched_files": files,
        "totals": dict(sorted(totals.items())),
    }
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return target


def write_model(out_dir: Path, model: dict[str, object]) -> None:
    json_path = out_dir / "wacz-markdown-rendering-model.json"
    md_path = out_dir / "wacz-markdown-rendering-model.md"
    json_path.write_text(json.dumps(model, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    tables = model.get("markdown_tables", [])
    all_tables = model.get("all_markdown_tables", [])
    css_files = model.get("css_files", [])
    js_files = model.get("js_files", [])
    content_type_counts = model.get("content_type_counts", {})
    lines = [
        "# WACZ Markdown Rendering Model",
        "",
        f"- WACZ: `{model.get('wacz')}`",
        f"- Page URL: `{model.get('page_url')}`",
        f"- WARC record counts: `{json.dumps(model.get('warc_record_counts', {}), ensure_ascii=False)}`",
        f"- Extracted response/resource bodies: {model.get('extracted_content_record_count')}",
        f"- Content-type counts: `{json.dumps(content_type_counts, ensure_ascii=False)}`",
        f"- Conversation JSON files: {len(model.get('conversation_jsons', []))}",
        f"- Assistant Markdown messages: {len(model.get('assistant_messages', []))}",
        f"- Conversation JSON: `{model.get('conversation_json')}`",
        f"- Assistant Markdown: `{model.get('assistant_markdown')}`",
        f"- All assistant Markdown directory: `{model.get('assistant_markdown_dir')}`",
        f"- CSS files: {len(css_files)}",
        f"- JS files: {len(js_files)}",
        f"- CSS/JS coverage: `{model.get('css_js_coverage')}`",
        "",
        "## Primary Assistant Table Inventory",
        "",
        "| Start line | Columns | Data rows | Inventory overflow hint | Column sizes | Max cell text lengths |",
        "| ---: | ---: | ---: | --- | --- | --- |",
    ]
    for table in tables if isinstance(tables, list) else []:
        lines.append(
            "| {start_line} | {columns} | {data_rows} | {wide} | `{sizes}` | `{lengths}` |".format(
                start_line=table.get("start_line"),
                columns=table.get("columns"),
                data_rows=table.get("data_rows"),
                wide=table.get("inventory_overflow_hint"),
                sizes=", ".join(table.get("wacz_column_sizes", [])),
                lengths=", ".join(str(value) for value in table.get("max_cell_text_lengths", [])),
            )
        )
    lines.extend(
        [
            "",
            "## All Assistant Table Inventory",
            "",
            "| Message | Start line | Columns | Data rows | Inventory overflow hint | Column sizes |",
            "| --- | ---: | ---: | ---: | --- | --- |",
        ]
    )
    for table in all_tables if isinstance(all_tables, list) else []:
        lines.append(
            "| `{message}` | {start_line} | {columns} | {data_rows} | {hint} | `{sizes}` |".format(
                message=table.get("assistant_markdown"),
                start_line=table.get("start_line"),
                columns=table.get("columns"),
                data_rows=table.get("data_rows"),
                hint=table.get("inventory_overflow_hint"),
                sizes=", ".join(table.get("wacz_column_sizes", [])),
            )
        )
    lines.extend(
        [
            "",
            "## Width And Table Rules",
            "",
            "- ChatGPT Markdown pipe-table JS assigns column sizes by text length: `>160 -> xl`, `>100 -> lg`, `>40 -> md`, otherwise `sm`; the separate TableContainer component path also has an `xs` bucket.",
            "- Markdown table parsing here ignores escaped pipes and pipes inside code spans, so table columns match the Markdown source structure instead of naive `|` counts.",
            "- `Inventory overflow hint` is an audit hint only; it is not an official WACZ branch and must not be used to decide whether Scopy applies the TableContainer model.",
            "- CSS/JS evidence snippets are written to `relevant-css-js-lines.txt` for manual review.",
            "- CSS/JS pattern coverage counts are written to `markdown-css-js-coverage.json` so broad Markdown-related asset coverage can be audited without relying on truncated snippets.",
        ]
    )
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    wacz = args.wacz.expanduser().resolve()
    if not wacz.exists():
        print(f"WACZ not found: {wacz}", file=sys.stderr)
        return 2

    date = dt.datetime.now().strftime("%Y%m%d")
    out_dir = args.out_dir or Path("/tmp/scopy-wacz-extract") / f"{wacz.stem}-{date}"
    out_dir = out_dir.resolve()
    if out_dir.exists() and args.force:
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    assistant_dir = out_dir / "assistant-messages"
    assistant_dir.mkdir(parents=True, exist_ok=True)
    warc_record_counts = scan_warc_record_counts(wacz)

    pages_url = ""
    try:
        with ZipFile(wacz) as archive:
            if "pages/pages.jsonl" in archive.namelist():
                pages_text = decode_text(archive.read("pages/pages.jsonl"))
                for page_line in pages_text.splitlines():
                    page = json.loads(page_line)
                    if isinstance(page, dict) and page.get("url"):
                        pages_url = str(page.get("url", ""))
                        break
    except Exception:
        pages_url = ""

    extracted: list[dict[str, object]] = []
    content_type_counts: Counter[str] = Counter()
    conversation_path = None
    conversation_data: dict[str, object] | None = None
    conversation_jsons: list[dict[str, object]] = []
    assistant_messages: list[dict[str, object]] = []

    for record in iter_warc_content_records(wacz):
        url = str(record["url"])
        record_type = str(record.get("record_type", ""))
        http_headers = record["http_headers"]
        if not isinstance(http_headers, dict):
            http_headers = {}
        mime = str(http_headers.get("content-type", ""))
        body = record["body"]
        if not isinstance(body, bytes):
            continue
        ext = extension_for(url, mime)
        path = out_dir / f"{safe_slug(url, int(record['index']))}{ext}"
        path.write_bytes(body)
        content_type_counts[mime or "(none)"] += 1
        meta = {
            "url": url,
            "date": record["date"],
            "warc_type": record_type,
            "content_type": mime,
            "bytes": len(body),
        }
        path.with_suffix(path.suffix + ".meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        extracted.append({"url": url, "path": str(path), "record_type": record_type, "content_type": mime, "bytes": len(body)})

        if "/backend-api/conversation/" in url and ext == ".json":
            try:
                data = json.loads(decode_text(body))
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            messages = assistant_markdown_messages_from_conversation(data)
            conversation_entry = {
                "url": url,
                "path": str(path),
                "assistant_message_count": len(messages),
            }
            conversation_jsons.append(conversation_entry)
            for message_index, message in enumerate(messages, start=1):
                markdown = str(message.get("markdown", ""))
                message_path = assistant_dir / f"{int(record['index']):04d}_{message_index:03d}.md"
                message_path.write_text(markdown + "\n", encoding="utf-8")
                message_meta = {
                    "source_conversation": str(path),
                    "source_url": url,
                    "node_id": message.get("node_id"),
                    "create_time": message.get("create_time"),
                    "chars": len(markdown),
                    "path": str(message_path),
                }
                message_path.with_suffix(".md.meta.json").write_text(
                    json.dumps(message_meta, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8",
                )
                assistant_messages.append(message_meta)
            markdown = assistant_markdown_from_conversation(data)
            if markdown and (conversation_data is None or len(markdown) > len(assistant_markdown_from_conversation(conversation_data))):
                conversation_data = data
                conversation_path = path

    assistant_path = None
    markdown = ""
    if conversation_data is not None:
        markdown = assistant_markdown_from_conversation(conversation_data)
        assistant_path = out_dir / "assistant-message.md"
        assistant_path.write_text(markdown + "\n", encoding="utf-8")

    css_files = [item["path"] for item in extracted if Path(str(item["path"])).suffix == ".css"]
    js_files = [item["path"] for item in extracted if Path(str(item["path"])).suffix == ".js"]
    relevant_path = write_relevant_css_js(out_dir, extracted)
    coverage_path = write_css_js_coverage(out_dir, extracted)
    all_markdown_tables: list[dict[str, object]] = []
    for message in assistant_messages:
        message_path = Path(str(message["path"]))
        message_markdown = message_path.read_text(encoding="utf-8")
        for table in extract_tables(message_markdown):
            table_entry = dict(table)
            table_entry["assistant_markdown"] = str(message_path)
            table_entry["source_conversation"] = message.get("source_conversation")
            table_entry["node_id"] = message.get("node_id")
            all_markdown_tables.append(table_entry)
    model = {
        "wacz": str(wacz),
        "page_url": pages_url,
        "output_dir": str(out_dir),
        "warc_record_counts": warc_record_counts,
        "extracted_content_record_count": len(extracted),
        "content_type_counts": dict(sorted(content_type_counts.items())),
        "conversation_jsons": conversation_jsons,
        "conversation_json": str(conversation_path) if conversation_path else None,
        "assistant_markdown": str(assistant_path) if assistant_path else None,
        "assistant_markdown_dir": str(assistant_dir),
        "assistant_messages": assistant_messages,
        "css_files": css_files,
        "js_files": js_files,
        "relevant_css_js_lines": str(relevant_path),
        "css_js_coverage": str(coverage_path),
        "markdown_tables": extract_tables(markdown) if markdown else [],
        "all_markdown_tables": all_markdown_tables,
    }
    write_model(out_dir, model)

    print(f"Extracted {len(extracted)} response/resource bodies to {out_dir}")
    print(f"WARC records: {warc_record_counts}")
    print(f"Conversation JSON files: {len(conversation_jsons)}")
    print(f"Assistant Markdown messages: {len(assistant_messages)}")
    print(f"Conversation JSON: {conversation_path}")
    print(f"Assistant Markdown: {assistant_path}")
    print(f"Markdown tables: {len(model['markdown_tables'])}")
    print(f"All assistant Markdown tables: {len(all_markdown_tables)}")
    print(f"CSS/JS coverage: {coverage_path}")
    print(f"Model: {out_dir / 'wacz-markdown-rendering-model.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
