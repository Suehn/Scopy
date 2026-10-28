#!/usr/bin/env python3
"""Exercise the production report consumer using canonical raw profile records."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/perf-frontend-profile.sh"


class ProfileReportTests(unittest.TestCase):
    def test_report_consumes_canonical_callback_and_attribution_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            self.seed(output)
            result = self.report(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "frontend-scroll-profile-summary.json").read_text())
            mixed = summary["variants"]["current"]["real-snapshot-mixed"]
            self.assertEqual(mixed["animation_callback_p95_ms"]["median"], 18)
            self.assertEqual(mixed["active_animation_callback_p95_ms"]["median"], 22)
            self.assertEqual(mixed["animation_callback_over_threshold_ratio"]["median"], 0.15)
            attribution = mixed["long_animation_callback_attribution"]
            self.assertEqual(attribution["long_callback_count"], 2)
            self.assertEqual(attribution["total_callback_interval_ms"], 70)
            self.assertEqual(attribution["top_metrics"][0]["callback_count"], 2)
            markdown = (output / "frontend-scroll-profile-summary.md").read_text()
            self.assertIn("Long Animation Callback Attribution", markdown)
            self.assertIn("do not measure compositor presentation", markdown)
            self.assertNotIn("Long Frames", markdown)

    def test_missing_callback_evidence_cannot_become_a_successful_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            self.seed(output)
            raw = output / "raw/current/real-snapshot-mixed.json"
            payload = json.loads(raw.read_text())
            payload["frame_ms"] = payload.pop("animation_callback_interval_ms")
            raw.write_text(json.dumps(payload))
            result = self.report(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing animation callback evidence", result.stderr)

    @staticmethod
    def report(output):
        # Execute the actual report body without starting Xcode or an application.
        script = SCRIPT.read_text().split('"$COMPARE_SUMMARY" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]
        return subprocess.run([sys.executable, "-", str(output), "1", "10", "260", "0", ""],
                              input=script, capture_output=True, text=True)

    @staticmethod
    def seed(output):
        raw = output / "raw/current"
        raw.mkdir(parents=True)
        for scenario in ("real-snapshot-accessibility", "real-snapshot-mixed", "real-snapshot-text-bias", "real-snapshot-search-evidence"):
            attribution = {"long_callback_count": 2, "timing_event_count": 4, "total_callback_interval_ms": 70,
                           "attributed_union_ms": 30, "unattributed_ms": 40,
                           "top_metrics": [{"name": "row.display_model_ms", "count": 3, "callback_count": 2,
                                            "total_ms": 35, "overlap_ms": 30, "max_ms": 20}]}
            payload = {"profile_scenario": scenario,
                       "animation_callback_interval_ms": {"count": 300, "avg": 12, "p95": 18},
                       "active_animation_callback_interval_ms": {"count": 100, "avg": 16, "p95": 22},
                       "animation_callback_over_threshold_ratio": 0.15,
                       "active_animation_callback_over_threshold_ratio": 0.2,
                       "long_animation_callback_attribution": attribution,
                       "main_thread_long_animation_callback_attribution": attribution,
                       "timing_buckets_ms": {"row.display_model_ms": {"p95": 0.2}},
                       "fixed_workload": {"loaded_count": 50, "search_evidence_count": 50,
                                          "search_query": ".", "search_mode": "regex", "search_ready": True}}
            (raw / f"{scenario}.json").write_text(json.dumps(payload))


if __name__ == "__main__":
    unittest.main()
