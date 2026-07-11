from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import textwrap
import unittest


RELEASE_SCRIPTS = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(RELEASE_SCRIPTS))

import validate_workflow_tag_policy as policy  # noqa: E402


class WorkflowTagPolicyTests(unittest.TestCase):
    def validate_fixture(self, source: str, name: str = "renamed-workflow.yml") -> list[policy.Violation]:
        with tempfile.TemporaryDirectory(prefix="scopy-release-policy-") as temporary_directory:
            workflow_dir = Path(temporary_directory)
            (workflow_dir / name).write_text(textwrap.dedent(source), encoding="utf-8")
            files, violations = policy.validate_workflow_dir(workflow_dir)
            self.assertEqual([path.name for path in files], [name])
            return violations

    def assert_rejected(self, run_script: str, expected_reason: str) -> None:
        violations = self.validate_fixture(
            f"""
            name: Unsafe release automation
            on:
              push:
                branches: [main]
            jobs:
              mutate:
                runs-on: ubuntu-latest
                steps:
                  - name: Mutate
                    run: |
                      {run_script}
            """
        )
        self.assertTrue(
            any(expected_reason in violation.reason for violation in violations),
            f"Expected reason containing {expected_reason!r}, got {violations!r}",
        )

    def test_real_workflows_do_not_create_or_push_tags(self) -> None:
        files, violations = policy.validate_workflow_dir(REPO_ROOT / ".github" / "workflows")
        self.assertGreaterEqual(len(files), 1)
        self.assertEqual(violations, [])

    def test_release_workflow_remains_tag_triggered_or_explicitly_dispatched(self) -> None:
        source = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        trigger_header = source.split("\njobs:\n", maxsplit=1)[0]
        self.assertIn('    tags:\n      - "v*"', trigger_header)
        self.assertIn("  workflow_dispatch:", trigger_header)
        self.assertNotIn("branches:", trigger_header)

    def test_safe_tag_trigger_and_branch_only_cask_push_are_allowed(self) -> None:
        violations = self.validate_fixture(
            """
            name: Build release
            on:
              push:
                tags:
                  - "v*"
              workflow_dispatch:
            jobs:
              release:
                runs-on: ubuntu-latest
                steps:
                  - run: echo "build existing tag"
                  - run: git push origin HEAD:main
            """,
            name="release.yml",
        )
        self.assertEqual(violations, [])

    def test_descriptions_and_shell_comments_are_not_commands(self) -> None:
        violations = self.validate_fixture(
            """
            name: Safe policy documentation
            on: workflow_dispatch
            jobs:
              explain:
                runs-on: ubuntu-latest
                steps:
                  - name: The words git tag are documentation only
                    run: |
                      # git push origin "$TAG"
                      echo "safe"
            """
        )
        self.assertEqual(violations, [])

    def test_tag_helper_is_rejected_after_workflow_rename(self) -> None:
        self.assert_rejected(
            "bash scripts/release/tag-from-doc.sh --ensure",
            "tag creation helper",
        )

    def test_git_tag_is_rejected(self) -> None:
        self.assert_rejected('git tag -a v1.2.3 -m "release"', "executes git tag")

    def test_all_non_allowlisted_git_push_forms_are_rejected(self) -> None:
        commands = (
            "git push origin --tags",
            "git push --follow-tags origin main",
            'TAG=v1.2.3; git push origin "$TAG"',
            "git push origin main",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assert_rejected(command, "not the allowlisted branch-only")

    def test_direct_tag_ref_api_creation_is_rejected(self) -> None:
        self.assert_rejected(
            "gh api --method POST repos/example/repo/git/refs -f ref=refs/tags/v1.2.3",
            "references a tag ref",
        )

    def test_release_creation_cli_is_rejected(self) -> None:
        self.assert_rejected("gh release create v1.2.3", "can create a release tag")

    def test_known_tag_creation_action_is_rejected(self) -> None:
        violations = self.validate_fixture(
            """
            name: Unsafe tag action
            on: workflow_dispatch
            jobs:
              tag:
                runs-on: ubuntu-latest
                steps:
                  - uses: vendor/github-tag-action@v1
            """
        )
        self.assertTrue(any("tag-creation action" in violation.reason for violation in violations))

    def test_non_release_workflow_cannot_gain_contents_write(self) -> None:
        permission_shapes = (
            "permissions:\n                  contents: write",
            "permissions: {contents: write}",
            'permissions: "write-all"',
        )
        for permissions in permission_shapes:
            with self.subTest(permissions=permissions):
                violations = self.validate_fixture(
                    f"""
                    name: Privileged branch workflow
                    on:
                      push:
                        branches: [main]
                    jobs:
                      mutate:
                        runs-on: ubuntu-latest
                        {permissions}
                        steps:
                          - run: echo "custom action could mutate refs"
                    """
                )
                self.assertTrue(any("write" in violation.reason for violation in violations))

    def test_release_workflow_rejects_branch_or_path_triggers(self) -> None:
        violations = self.validate_fixture(
            """
            name: Build release
            on:
              push:
                tags: ["v*"]
                branches: [main]
              workflow_dispatch:
            jobs:
              release:
                runs-on: ubuntu-latest
                permissions:
                  contents: write
                steps:
                  - run: echo "unsafe entrypoint"
            """,
            name="release.yml",
        )
        self.assertTrue(any("forbidden trigger branches:" in violation.reason for violation in violations))

    def test_folded_run_scalar_cannot_hide_git_tag(self) -> None:
        violations = self.validate_fixture(
            """
            name: Folded tag command
            on: workflow_dispatch
            jobs:
              tag:
                runs-on: ubuntu-latest
                steps:
                  - run: >
                      git
                      tag -a v1.2.3 -m release
            """
        )
        self.assertTrue(any("executes git tag" in violation.reason for violation in violations))


if __name__ == "__main__":
    unittest.main()
