#!/usr/bin/env python3
"""Extract the latest numeric p95_ms value from a JSONL benchmark file."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract_p95.py <jsonl-path>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"missing file: {path}", file=sys.stderr)
        return 1

    value: float | None = None
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                payload = json.loads(line)
            except Exception:
                continue
            p95 = payload.get("p95_ms")
            if isinstance(p95, (int, float)):
                value = float(p95)

    if value is None:
        print(f"no numeric p95_ms in {path}", file=sys.stderr)
        return 1

    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
