#!/usr/bin/env python3
"""Regression tests for evidence admission and snapshot safety, without app launches."""
import copy
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "perf-scroll"))
from compare import schedule, summarize
from compare_search import clone_database, run_bench, sha


class ComparisonEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.plan = schedule()
        self.metrics = {"latency": {"unit": "ms", "run_statistic": "maximum"}}
        self.runs = [{**run, "valid": True, "proof": {"rows": 10000},
                      "metrics": {"latency": 100 + (index % 2) if run["variant"] == "A" else 50 + (index % 2)}}
                     for index, run in enumerate(self.plan)]

    def test_plan_has_warmups_noise_pairs_then_abba(self):
        self.assertEqual([r["variant"] for r in self.plan[:2]], ["A", "B"])
        self.assertEqual([r["variant"] for r in self.plan[2:8]], ["A"] * 6)
        self.assertEqual("".join(r["variant"] for r in self.plan[8:]), "ABBA" * 3)
        self.assertEqual(len(set(r["id"] for r in self.plan)), 20)

    def test_missing_failed_reordered_or_unproven_run_cannot_pass(self):
        for mutate in (
            lambda runs: runs.pop(0),
            lambda runs: runs[-1].update(valid=False),
            lambda runs: runs[-1].update(proof={}),
            lambda runs: runs.reverse(),
            lambda runs: runs[-1].update(variant="A" if runs[-1]["variant"] == "B" else "B"),
            lambda runs: runs[0].update(variant="B"),
            lambda runs: runs[-1]["metrics"].update(latency=float("nan")),
        ):
            runs = copy.deepcopy(self.runs)
            mutate(runs)
            self.assertNotEqual(summarize(runs, self.plan, self.metrics)["status"], "complete")

    def test_resolved_improvement_and_max_headline(self):
        result = summarize(self.runs, self.plan, self.metrics)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["metrics"]["latency"]["outcome"], "improved")
        self.assertEqual(result["metrics"]["latency"]["headline_statistic"], "median")

    def test_overlap_inside_noise_is_not_a_gain(self):
        for index, run in enumerate(self.runs):
            run["metrics"]["latency"] = 100 + (index % 4) * 3 + (1 if run["variant"] == "B" else 0)
        result = summarize(self.runs, self.plan, self.metrics)
        self.assertEqual(result["metrics"]["latency"]["outcome"], "within_noise")


class SnapshotSafetyTests(unittest.TestCase):
    def test_copy_preserves_source_and_rejects_nonempty_wal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.db"
            with sqlite3.connect(source) as connection:
                connection.execute("CREATE TABLE evidence(value INTEGER)")
                connection.execute("INSERT INTO evidence VALUES (7)")
            digest = sha(source)
            target = root / "runtime" / "clipboard.db"
            self.assertEqual(clone_database(source, target), digest)
            self.assertEqual(sha(source), digest)
            self.assertEqual(sha(target), digest)
            Path(str(source) + "-wal").write_bytes(b"pending transaction")
            with self.assertRaisesRegex(RuntimeError, "nonempty WAL"):
                clone_database(source, root / "rejected" / "clipboard.db")
            self.assertFalse((root / "rejected").exists())

    def test_process_resources_belong_to_one_child_and_failure_is_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "ScopyBench"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' '{\"median_ms\":1}'\n")
            fake.chmod(0o700)
            good = root / "good"
            good.mkdir()
            payload, resources = run_bench(fake, root / "unused.db", [], good)
            self.assertEqual(payload["median_ms"], 1)
            self.assertGreater(resources["process_wall_ms"], 0)
            self.assertGreater(resources["process_peak_rss_bytes"], 0)
            fake.write_text("#!/bin/sh\nprintf '%s\\n' 'deliberate harness error' >&2\nexit 7\n")
            bad = root / "bad"
            bad.mkdir()
            with self.assertRaisesRegex(RuntimeError, "exited 7"):
                run_bench(fake, root / "unused.db", [], bad)
            self.assertIn("deliberate harness error", (bad / "stderr.txt").read_text())
            self.assertTrue((bad / "resources.json").is_file())


if __name__ == "__main__":
    unittest.main()
