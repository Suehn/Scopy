import importlib.util
import fcntl
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("scopy_e2e_run", Path(__file__).with_name("run.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class HarnessSafetyTests(unittest.TestCase):
    def test_seed_refuses_active_writer_and_copies_external_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            seed = root / "seed"
            seed.mkdir()
            lock_path = seed / ".scopy-writer.lock"
            lock_path.touch()
            for name in ("clipboard.db", "content/one.bin", "ingest/one.envelope.json", "thumbnails/one.png"):
                path = seed / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes(name.encode())
            with lock_path.open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    harness.clone_seed(seed, root / "blocked")
            self.assertFalse((root / "blocked").exists())
            manifest = harness.clone_seed(seed, root / "copy")
            self.assertIn("content/one.bin", manifest)
            self.assertIn("ingest/one.envelope.json", manifest)
            self.assertEqual((root / "copy/thumbnails/one.png").read_bytes(), b"thumbnails/one.png")

    def test_comparison_preserves_order_content_and_receipt_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            left, right = root / "baseline", root / "candidate"
            left.mkdir()
            right.mkdir()
            def snapshot(ids):
                return {"items": [
                    {"id": ids[0], "content_hash": "alpha", "created_at": 10, "last_used_at": 12, "use_count": 1},
                    {"id": ids[1], "content_hash": "beta", "created_at": 11, "last_used_at": 11, "use_count": 1}],
                    "receipts": [{"item_id": ids[0]}], "meta": [{"mutation_seq": 2}]}
            a, b = snapshot(["a1", "a2"]), snapshot(["b1", "b2"])
            harness.save(left / "db-final.json", a)
            harness.save(right / "db-final.json", b)
            self.assertTrue(harness.compare(left, right)["database_semantics_equal"])
            b["items"].reverse()
            harness.save(right / "db-final.json", b)
            with self.assertRaises(AssertionError):
                harness.compare(left, right)
            b = snapshot(["b1", "b2"])
            b["items"][0]["use_count"] = 2
            harness.save(right / "db-final.json", b)
            with self.assertRaises(AssertionError):
                harness.compare(left, right)
            b = snapshot(["b1", "b2"])
            b["receipts"][0]["item_id"] = "b2"
            harness.save(right / "db-final.json", b)
            with self.assertRaises(AssertionError):
                harness.compare(left, right)


if __name__ == "__main__":
    unittest.main()
