"""Exercise the actual shell/Make entrypoints without requiring Xcode or a GUI."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scopy-tooling-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("Scopy", "ScopyTests", "ScopyUITests", "ScopyTestHost", "bin"):
            (self.root / directory).mkdir()
        for name in ("project.yml", "Package.swift", "Scopy/main.swift"):
            (self.root / name).write_text("initial\n")
        shutil.copy(REPO / "scripts/xcodegen-generate-if-needed.sh", self.root / "generate.sh")
        fake = self.root / "bin/xcodegen"
        fake.write_text('''#!/bin/sh
set -eu
if [ "$1" = "--version" ]; then
    echo "${GENERATOR_VERSION:-1}"
    exit 0
fi
echo generated >> calls
if [ "${FAIL_GENERATION:-0}" = "1" ]; then exit 1; fi
mkdir -p Scopy.xcodeproj
touch Scopy.xcodeproj/project.pbxproj
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])
        self.env.pop("FORCE_XCODEGEN", None)

    def generate(self, **env):
        return subprocess.run(
            ["bash", "generate.sh"], cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True,
        )

    def assert_generations(self, count, **env):
        result = self.generate(**env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), count)

    def test_unchanged_and_content_only_edits_remain_incremental(self):
        self.assert_generations(1)
        self.assert_generations(1)
        (self.root / "Scopy/main.swift").write_text("changed implementation\n")
        self.assert_generations(1)

    def test_resource_addition_and_removal_regenerate(self):
        self.assert_generations(1)
        fixture = self.root / "ScopyTests/image fixture.png"
        fixture.write_bytes(b"fixture")
        self.assert_generations(2)
        fixture.unlink()
        self.assert_generations(3)

    def test_swift_rename_regenerates(self):
        self.assert_generations(1)
        (self.root / "Scopy/main.swift").rename(self.root / "Scopy/renamed.swift")
        self.assert_generations(2)

    def test_project_package_and_generator_changes_regenerate(self):
        self.assert_generations(1)
        (self.root / "project.yml").write_text("changed config\n")
        self.assert_generations(2)
        (self.root / "Package.swift").write_text("changed package\n")
        self.assert_generations(3)
        self.assert_generations(4, GENERATOR_VERSION="2")

    def test_missing_project_and_forced_generation(self):
        self.assert_generations(1)
        (self.root / "Scopy.xcodeproj/project.pbxproj").unlink()
        self.assert_generations(2)
        self.assert_generations(3, FORCE_XCODEGEN="1")

    def test_failed_generation_does_not_cache_success(self):
        self.assert_generations(1)
        stamp = (self.root / ".xcodegen.signature").read_text()
        (self.root / "Scopy/new.swift").touch()
        result = self.generate(FAIL_GENERATION="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / ".xcodegen.signature").read_text(), stamp)
        self.assert_generations(3)


class WorktreeIsolationTests(unittest.TestCase):
    def test_test_variants_are_scoped_to_the_checkout(self):
        with tempfile.TemporaryDirectory(prefix="scopy-worktrees-") as temporary:
            roots = [Path(temporary) / name for name in ("first", "second")]
            outputs = []
            for root in roots:
                root.mkdir()
                shutil.copy(REPO / "Makefile", root / "Makefile")
                # Inspect the real recipes; do not run setup or Xcode.
                result = subprocess.run(
                    ["make", "-n", "test-strict", "test-perf", "test-real-db", "VERSION_ARGS="],
                    cwd=root, capture_output=True, text=True, check=True,
                )
                import re
                paths = re.findall(r"-derivedDataPath ([^\s]+)", result.stdout)
                self.assertEqual(len(paths), 3)
                self.assertEqual(len(set(paths)), 3)
                outputs.append(paths)
            self.assertTrue(set(outputs[0]).isdisjoint(outputs[1]))


if __name__ == "__main__":
    unittest.main()
