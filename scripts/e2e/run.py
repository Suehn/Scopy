#!/usr/bin/env python3
"""Drive sequential production Scopy bundles with private state and asserted observations."""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "scripts/e2e/build"


def run(*args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


def bridge(*args, **kwargs):
    return json.loads(run(TOOLS / "bridge", *args, **kwargs))


def save(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_files(root: Path):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            try:
                result[str(path.relative_to(root))] = {"size": path.stat().st_size, "sha256": digest(path)}
            except FileNotFoundError:
                result[str(path.relative_to(root))] = {"vanished_during_observation": True}
    return result


def wait_for(probe, description, timeout=20):
    deadline = time.monotonic() + timeout
    error = None
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (sqlite3.Error, subprocess.CalledProcessError, FileNotFoundError) as caught:
            error = str(caught)
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}; last error: {error}")


def walk(node):
    yield node
    for child in node.get("children", []):
        yield from walk(child)


def find(observation, identifier):
    return next((node for node in walk(observation["tree"]) if node.get("id") == identifier), None)


def item_ids(observation):
    result = []
    for node in walk(observation["tree"]):
        identifier = node.get("id", "")
        if identifier.startswith("History.Item."):
            value = identifier.removeprefix("History.Item.")
            if value not in result:
                result.append(value)
    return result


def rows(database):
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        return [dict(row) for row in connection.execute(
            "SELECT * FROM clipboard_items ORDER BY is_pinned DESC,last_used_at DESC,id ASC")]


def db_snapshot(database):
    data = rows(database)
    for row in data:
        raw = row.pop("raw_data", None)
        row["raw_data_bytes"] = len(raw) if raw is not None else None
        row["raw_data_sha256"] = hashlib.sha256(raw).hexdigest() if raw is not None else None
        text = row.pop("plain_text", None)
        row["plain_text_bytes"] = len(text.encode()) if text is not None else None
        row["plain_text_sha256"] = hashlib.sha256(text.encode()).hexdigest() if text is not None else None
        row["plain_text_prefix"] = text[:160] if text is not None else None
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        receipts = [dict(row) for row in connection.execute("SELECT * FROM ingest_receipts ORDER BY committed_at,ingest_id")]
        meta = [dict(row) for row in connection.execute("SELECT * FROM scopy_meta")]
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        assert [tuple(row) for row in integrity] == [("ok",)], integrity
    return {"items": data, "receipts": receipts, "meta": meta}


def clone_seed(source: Path, destination: Path):
    """Copy the whole offline root under Scopy's own exclusive writer lock."""
    assert source.is_dir() and (source / ".scopy-writer.lock").is_file(), "Seed must be a stopped Scopy storage root"
    assert not any(p.is_symlink() for p in source.rglob("*")), "Seed may not link to user payloads"
    with (source / ".scopy-writer.lock").open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        shutil.copytree(source, destination)
    # The complete root includes payloads, pending ingest, thumbnails and search caches.
    return tree_files(destination)


class Session:
    def __init__(self, app: Path, output: Path, domain: str, seed: Path | None):
        self.output, self.domain = output, domain
        output.mkdir()
        self.storage = output / "storage"
        if seed:
            save(output / "seed.json", clone_seed(seed, self.storage))
        else:
            self.storage.mkdir()
            save(output / "seed.json", {})
        self.home = output / "home"
        self.home.mkdir()
        self.app = output / "Scopy.app"
        shutil.copytree(app, self.app, symlinks=True)
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        original_id = info["CFBundleIdentifier"]
        original_hash = digest(app / "Contents/MacOS/Scopy")
        info.update(CFBundleIdentifier=domain, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
        info_path.write_bytes(plistlib.dumps(info))
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", self.app, stderr=subprocess.DEVNULL)
        self.pb = "ScopyE2E." + domain.removeprefix("com.scopy.e2e.")
        actual = bridge("environment")
        protected = [Path.home() / "Library/Application Support/Scopy",
                     Path.home() / "Library/Caches/Scopy", Path("/Applications/Scopy.app"),
                     Path(actual["temporary"]) / "Scopy",
                     Path.home() / f"Library/Preferences/{original_id}.plist"]
        profile = "(version 1)\n(allow default)\n" + "".join(
            f"(deny file-write* (subpath {json.dumps(str(path))}))\n" for path in protected)
        self.profile = output / "protect-user.sb"
        self.profile.write_text(profile)
        self.env = dict(os.environ, CFFIXED_USER_HOME=str(self.home), USE_MOCK_SERVICE="0",
                        SCOPY_SERVICE_DB_PATH=str(self.storage / "clipboard.db"),
                        SCOPY_SERVICE_MONITOR_PASTEBOARD=self.pb, SCOPY_SERVICE_MONITOR_INTERVAL_MS="100",
                        SCOPY_PROFILE_OPEN_PANEL="1", SCOPY_SCROLL_PROFILE="1", SCOPY_PROFILE_ACCESSIBILITY="1",
                        SCOPY_PROFILE_DURATION_SEC="900", SCOPY_PROFILE_OUTPUT=str(output / "profile.json"))
        isolated = bridge("environment", env=self.env)
        for key in ("support", "cache"):
            assert all(Path(path).is_relative_to(self.home) for path in isolated[key]), isolated
        assert isolated["accessibility_trusted"], "Accessibility access is required"
        prefs = {"AppleLanguages": ["en"], "AppleLocale": "en_US", "SUEnableAutomaticChecks": False,
                 "SUAutomaticallyUpdate": False, "ScopySettings": {
                     "clipboardPollingIntervalMs": 100, "hotkeyKeyCode": 111, "hotkeyModifiers": 6912,
                     "linkEnrichmentEnabled": False, "siteIconsEnabled": False,
                     "pngquantCopyImageEnabled": False, "pngquantMarkdownExportEnabled": False}}
        save(output / "defaults-input.json", prefs)
        assert not bridge("defaults", domain, "read"), "Refuse to replace an existing test defaults domain"
        bridge("defaults", domain, "write", output / "defaults-input.json")
        save(output / "manifest.json", {"source_app": str(app), "source_binary_sha256": original_hash,
             "staged_binary_sha256": digest(self.app / "Contents/MacOS/Scopy"), "bundle_id": domain,
             "source_bundle_id": original_id, "isolation": isolated, "protected_paths": list(map(str, protected)),
             "source_version": info.get("CFBundleShortVersionString"), "source_build": info.get("CFBundleVersion"),
             "staging_changes": ["test bundle identity", "automatic updater disabled", "ad-hoc code signature"]})
        self.process = None
        self.log = None
        self.observations = []
        self.launches = 0

    @property
    def database(self):
        return self.storage / "clipboard.db"

    def start(self):
        self.launches += 1
        run(TOOLS / "warp", 1400, 40)
        self.log = (self.output / f"app-{self.launches}.log").open("w")
        self.process = subprocess.Popen(["/usr/bin/sandbox-exec", "-f", str(self.profile),
            str(self.app / "Contents/MacOS/Scopy"), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        wait_for(lambda: bridge("activate", self.process.pid)["pid"] == self.process.pid,
                 "test app activation before the automatic panel opens")
        def panel():
            assert self.process.poll() is None, f"App exited: {self.process.returncode}"
            return run(TOOLS / "winpos", self.process.pid)
        position = [float(value) for value in wait_for(panel, "real history panel").split()]
        run(TOOLS / "click", position[0] + 100, position[1] + 30)
        self.observe(f"launch-{self.launches}")

    def observe(self, name):
        result = bridge("ax", self.process.pid)
        save(self.output / f"ax-{name}.json", result)
        self.observations.append({"name": name, "item_ids": item_ids(result), "windows": result["windows"]})
        return result

    def capture(self, name, text, wait=True):
        fixture = self.output / f"fixture-{name}.json"
        save(fixture, {"public.utf8-plain-text": base64.b64encode(text.encode()).decode()})
        before = len(rows(self.database))
        assert bridge("foreground")["pid"] == self.process.pid, "Capture source app changed"
        started = time.time()
        bridge("pasteboard", self.pb, "write", fixture)
        if wait:
            wait_for(lambda: len(rows(self.database)) == before + 1, f"capture {name}", timeout=45)
            current = rows(self.database)
            match = [row for row in current if row["plain_text"] == text]
            assert len(match) == 1, f"Capture text changed or duplicated: {name}"
            assert match[0]["app_bundle_id"] == self.domain, "Capture source differs from the isolated app"
            assert started - 1 <= match[0]["created_at"] <= time.time() + 1
            wait_for(lambda: match[0]["id"] in item_ids(bridge("ax", self.process.pid)), f"UI published {name}")
            self.observe("capture-" + name)
        return started

    def quit(self):
        bridge("quit", self.process.pid)
        self.process.wait(timeout=40)
        assert self.process.returncode == 0, f"Quit returned {self.process.returncode}"
        self.log.close()
        self.process = None

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.log is not None:
            self.log.close()
        save(self.output / "defaults-final.json", bridge("defaults", self.domain, "read"))
        bridge("defaults", self.domain, "remove")


def lifecycle(session: Session):
    session.start()
    initial = rows(session.database)
    for name, text in [("alpha", "Scopy E2E needlealpha\nExact Unicode: 中文 café Ω 😀"),
                       ("beta", "Scopy E2E needlebeta\nSecond deterministic capture."),
                       ("markdown", "# Scopy E2E Markdown\n\n**Bold**, `code`, and $x^2$.")]:
        session.capture(name, text)
    save(session.output / "db-before-quit.json", db_snapshot(session.database))
    # Observe durable acceptance before asking AppKit to quit. A committed row also proves
    # acceptance, but does not prove an in-flight drain; record that distinction explicitly.
    large = ("Scopy E2E largedrain\n" + "Deterministic payload line 0123456789 abcdefghijklmnopqrstuvwxyz.\n" * 131072).rstrip("\n")
    started = session.capture("large", large, wait=False)
    def accepted():
        pending = sorted((session.storage / "ingest").glob("*.json"))
        if pending:
            return {"kind": "pending-envelope", "files": [p.name for p in pending], "time": time.time()}
        matched = [row for row in rows(session.database) if row["plain_text"] == large]
        if matched:
            return {"kind": "already-committed", "id": matched[0]["id"], "time": time.time()}
        return None
    acceptance = wait_for(accepted, "durable capture acceptance", timeout=45)
    acceptance["capture_started"] = started
    save(session.output / "quit-acceptance.json", acceptance)
    save(session.output / "spool-at-quit.json", tree_files(session.storage / "ingest"))
    session.quit()
    after = db_snapshot(session.database)
    save(session.output / "db-after-quit.json", after)
    save(session.output / "spool-after-quit.json", tree_files(session.storage / "ingest"))
    session.start()
    wait_for(lambda: len(rows(session.database)) == len(initial) + 4, "all accepted captures after restart", timeout=45)
    current = rows(session.database)
    match = [row for row in current if row["plain_text"] == large]
    assert len(match) == 1 and match[0]["use_count"] == 1, "Restart duplicated or lost large capture"
    assert match[0]["app_bundle_id"] == session.domain, "Large capture source app changed"
    assert started - 1 <= match[0]["created_at"] <= time.time() + 1, "Large capture creation time is outside its operation window"
    wait_for(lambda: match[0]["id"] in item_ids(bridge("ax", session.process.pid)), "restarted UI shows large capture")
    session.observe("restarted")
    session.quit()
    final = db_snapshot(session.database)
    save(session.output / "db-final.json", final)
    save(session.output / "storage-final.json", tree_files(session.storage))
    assert not list((session.storage / "ingest").glob("*.json")), "Pending envelopes remain after restart"
    for row in final["items"]:
        if row["storage_ref"]:
            assert (session.storage / "content" / row["storage_ref"]).is_file(), "Missing external payload"
    return {"status": "passed", "scenario": "capture-quit-restart", "items": len(final["items"]),
            "quit_acceptance": acceptance["kind"], "large_payload_bytes": len(large.encode()),
            "items_committed_at_exit": len(after["items"]),
            "pending_envelopes_at_exit": sum(name.endswith(".envelope.json") for name in
                json.loads((session.output / "spool-after-quit.json").read_text())),
            "observations": session.observations}


def compare(left: Path, right: Path):
    def normalized(path):
        snapshot = json.loads((path / "db-final.json").read_text())
        items = snapshot["items"]
        assert len({row["id"] for row in items}) == len(items)
        assert len({row["content_hash"] for row in items}) == len(items), "Duplicate content identities"
        id_map = {row["id"]: row["content_hash"] for row in items}
        result = []
        for row in items:
            row = dict(row)
            row["id"] = id_map[row["id"]]
            # Raw observations retain both timestamps. Ordering is retained by this list;
            # each capture separately asserts its creation window before normalization.
            row.pop("created_at")
            row.pop("last_used_at")
            result.append(row)
        receipts = [id_map[row["item_id"]] for row in snapshot["receipts"]]
        return {"items": result, "receipt_items": receipts, "meta": snapshot["meta"]}
    a, b = normalized(left), normalized(right)
    save(left.parent / "normalized-baseline.json", a)
    save(left.parent / "normalized-candidate.json", b)
    assert a == b, "Database semantics differ; inspect normalized files and raw per-side observations"
    return {"database_semantics_equal": True, "item_count": len(a["items"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    assert not output.exists(), "Use a fresh output directory; previous evidence is never overwritten"
    output.mkdir(parents=True)
    before = bridge("general-status")
    domain = "com.scopy.e2e." + uuid.uuid4().hex
    report = {"status": "running", "general_pasteboard_before": before, "sides": {}}
    try:
        for name, app in [("baseline", args.baseline), ("candidate", args.candidate)]:
            if app is None:
                continue
            session = Session(app.resolve(), output / name, domain, args.seed)
            try:
                report["sides"][name] = lifecycle(session)
            finally:
                session.close()
        if args.candidate:
            report["comparison"] = compare(output / "baseline", output / "candidate")
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["failure"] = str(error)
        raise
    finally:
        report["general_pasteboard_after"] = bridge("general-status")
        report["general_pasteboard_unchanged"] = report["general_pasteboard_after"] == before
        if not report["general_pasteboard_unchanged"]:
            report["status"] = "invalid-general-pasteboard-changed"
        save(output / "result.json", report)
        print(json.dumps({"status": report["status"], "output": str(output)}, ensure_ascii=False))
    assert report["general_pasteboard_unchanged"], "User pasteboard changed; the run is invalid"


if __name__ == "__main__":
    main()
