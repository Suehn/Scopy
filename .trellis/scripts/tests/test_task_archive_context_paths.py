#!/usr/bin/env python3
"""Regression tests for archived Trellis task context manifests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from common.task_utils import archive_task_complete, rewrite_archived_task_context_paths


class ArchiveContextPathRewriteTests(unittest.TestCase):
    def test_archive_rewrites_task_local_context_paths_and_preserves_others(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            source_rel = ".trellis/tasks/05-07-example"
            task_dir = repo_root / source_rel
            research_dir = task_dir / "research"
            research_dir.mkdir(parents=True)
            (task_dir / "task.json").write_text("{}\n", encoding="utf-8")
            (task_dir / "prd.md").write_text("prd\n", encoding="utf-8")
            (research_dir / "note.md").write_text("note\n", encoding="utf-8")

            spec_path = repo_root / ".trellis/spec/backend/quality-guidelines.md"
            spec_path.parent.mkdir(parents=True)
            spec_path.write_text("quality\n", encoding="utf-8")

            sibling_path = repo_root / ".trellis/tasks/05-07-example-other/research/note.md"
            sibling_path.parent.mkdir(parents=True)
            sibling_path.write_text("sibling\n", encoding="utf-8")

            implement_rows = [
                {"_example": "seed row should be preserved"},
                {"file": f"{source_rel}/research/note.md", "reason": "task-local research"},
                {"file": f"./{source_rel}/prd.md", "reason": "leading dot slash"},
                {"file": source_rel, "type": "directory", "reason": "task directory"},
                {"file": source_rel.replace("/", "\\") + "\\research\\note.md", "reason": "windows separators"},
                {"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "spec path stays"},
                {"file": ".trellis/tasks/05-07-example-other/research/note.md", "reason": "prefix sibling stays"},
                {
                    "file": f"{source_rel}/research/note.md",
                    "reason": f"reason text is not rewritten: {source_rel}/research/note.md",
                },
            ]
            self._write_jsonl(task_dir / "implement.jsonl", implement_rows, extra_line="[]\nnot-json\n")
            self._write_jsonl(
                task_dir / "check.jsonl",
                [{"file": f"{source_rel}/research/note.md", "reason": "check context"}],
            )

            result = archive_task_complete(task_dir, repo_root)

            archive_dest = Path(result["archived_to"])
            archive_rel = archive_dest.relative_to(repo_root).as_posix()
            self.assertEqual(result["context_paths_rewritten"], "6")
            self.assertFalse(task_dir.exists())
            self.assertTrue((archive_dest / "research/note.md").is_file())

            implement_lines = (archive_dest / "implement.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(implement_lines[-2], "[]")
            self.assertEqual(implement_lines[-1], "not-json")
            implement_entries = [json.loads(line) for line in implement_lines[:-2]]

            self.assertNotIn("file", implement_entries[0])
            self.assertEqual(implement_entries[1]["file"], f"{archive_rel}/research/note.md")
            self.assertEqual(implement_entries[2]["file"], f"{archive_rel}/prd.md")
            self.assertEqual(implement_entries[3]["file"], archive_rel)
            self.assertEqual(implement_entries[3]["type"], "directory")
            self.assertEqual(implement_entries[4]["file"], f"{archive_rel}/research/note.md")
            self.assertEqual(implement_entries[5]["file"], ".trellis/spec/backend/quality-guidelines.md")
            self.assertEqual(implement_entries[6]["file"], ".trellis/tasks/05-07-example-other/research/note.md")
            self.assertEqual(implement_entries[7]["file"], f"{archive_rel}/research/note.md")
            self.assertIn(f"{source_rel}/research/note.md", implement_entries[7]["reason"])

            check_entries = self._read_jsonl(archive_dest / "check.jsonl")
            self.assertEqual(check_entries[0]["file"], f"{archive_rel}/research/note.md")

            self.assertEqual(rewrite_archived_task_context_paths(task_dir, archive_dest, repo_root), 0)

    @staticmethod
    def _write_jsonl(path: Path, rows: list[dict[str, object]], extra_line: str | None = None) -> None:
        content = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
        if extra_line is not None:
            content += extra_line
        path.write_text(content, encoding="utf-8")

    @staticmethod
    def _read_jsonl(path: Path) -> list[dict[str, object]]:
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


if __name__ == "__main__":
    unittest.main()
