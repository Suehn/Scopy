#!/usr/bin/env python3
"""Extract ChatGPT Markdown rendering evidence from a WACZ capture.

The script is intentionally dependency-free so it can run on a clean macOS
checkout. It extracts WARC response bodies, identifies the conversation JSON,
exports the longest assistant Markdown message, and writes a structured table
inventory that respects escaped pipes and pipes inside code spans.
"""

from __future__ import annotations

import argparse
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
    "markdown-new-styling",
    "wrap-break-word",
    ".prose",
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


def iter_warc_responses(wacz_path: Path) -> Iterable[dict[str, object]]:
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
                    if record_type != "response":
                        continue

                    index += 1
                    http_headers, body = split_http_payload(payload)
                    yield {
                        "index": index,
                        "url": headers.get("WARC-Target-URI", ""),
                        "date": headers.get("WARC-Date", ""),
                        "warc_headers": headers,
                        "http_headers": http_headers,
                        "body": body,
                    }


def decode_text(raw: bytes) -> str:
    for encoding in ("utf-8", "utf-8-sig", "latin1"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def assistant_markdown_from_conversation(data: dict[str, object]) -> str:
    mapping = data.get("mapping")
    if not isinstance(mapping, dict):
        return ""
    candidates: list[str] = []
    for node in mapping.values():
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
                candidates.append(text)
    return max(candidates, key=len, default="")


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
        is_wide = columns >= 4 or (columns >= 3 and (max_length >= 40 or total_length >= 96))
        tables.append(
            {
                "start_line": i + 1,
                "end_line": j,
                "columns": columns,
                "data_rows": len(rows),
                "header": header,
                "max_cell_text_lengths": max_lengths,
                "wacz_column_sizes": [column_size(length) for length in max_lengths],
                "wide_by_static_wacz_heuristic": is_wide,
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


def write_model(out_dir: Path, model: dict[str, object]) -> None:
    json_path = out_dir / "wacz-markdown-rendering-model.json"
    md_path = out_dir / "wacz-markdown-rendering-model.md"
    json_path.write_text(json.dumps(model, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    tables = model.get("markdown_tables", [])
    css_files = model.get("css_files", [])
    js_files = model.get("js_files", [])
    lines = [
        "# WACZ Markdown Rendering Model",
        "",
        f"- WACZ: `{model.get('wacz')}`",
        f"- Page URL: `{model.get('page_url')}`",
        f"- Conversation JSON: `{model.get('conversation_json')}`",
        f"- Assistant Markdown: `{model.get('assistant_markdown')}`",
        f"- CSS files: {len(css_files)}",
        f"- JS files: {len(js_files)}",
        "",
        "## Table Inventory",
        "",
        "| Start line | Columns | Data rows | Static WACZ wide | Column sizes | Max cell text lengths |",
        "| ---: | ---: | ---: | --- | --- | --- |",
    ]
    for table in tables if isinstance(tables, list) else []:
        lines.append(
            "| {start_line} | {columns} | {data_rows} | {wide} | `{sizes}` | `{lengths}` |".format(
                start_line=table.get("start_line"),
                columns=table.get("columns"),
                data_rows=table.get("data_rows"),
                wide=table.get("wide_by_static_wacz_heuristic"),
                sizes=", ".join(table.get("wacz_column_sizes", [])),
                lengths=", ".join(str(value) for value in table.get("max_cell_text_lengths", [])),
            )
        )
    lines.extend(
        [
            "",
            "## Width And Table Rules",
            "",
            "- ChatGPT table JS assigns Markdown column sizes by rendered text length: `>160 -> xl`, `>100 -> lg`, `>40 -> md`, otherwise `sm`.",
            "- Markdown table parsing here ignores escaped pipes and pipes inside code spans, so table columns match the Markdown source structure instead of naive `|` counts.",
            "- CSS/JS evidence snippets are written to `relevant-css-js-lines.txt` for manual review.",
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
    conversation_path = None
    conversation_data: dict[str, object] | None = None

    for record in iter_warc_responses(wacz):
        url = str(record["url"])
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
        meta = {
            "url": url,
            "date": record["date"],
            "content_type": mime,
            "bytes": len(body),
        }
        path.with_suffix(path.suffix + ".meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        extracted.append({"url": url, "path": str(path), "content_type": mime})

        if "/backend-api/conversation/" in url and ext == ".json":
            try:
                data = json.loads(decode_text(body))
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
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
    model = {
        "wacz": str(wacz),
        "page_url": pages_url,
        "output_dir": str(out_dir),
        "conversation_json": str(conversation_path) if conversation_path else None,
        "assistant_markdown": str(assistant_path) if assistant_path else None,
        "css_files": css_files,
        "js_files": js_files,
        "relevant_css_js_lines": str(relevant_path),
        "markdown_tables": extract_tables(markdown) if markdown else [],
    }
    write_model(out_dir, model)

    print(f"Extracted {len(extracted)} response bodies to {out_dir}")
    print(f"Conversation JSON: {conversation_path}")
    print(f"Assistant Markdown: {assistant_path}")
    print(f"Markdown tables: {len(model['markdown_tables'])}")
    print(f"Model: {out_dir / 'wacz-markdown-rendering-model.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
