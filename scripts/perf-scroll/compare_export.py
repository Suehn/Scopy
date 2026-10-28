#!/usr/bin/env python3
"""Measure real-app PNG export with the isolated E2E launch boundary and A/A + ABBA.

This measures launch-to-PNG wall time, app-process kernel counters, and the AX
round trips observed after a window becomes queryable. It does not measure
compositor presentation, total WebKit-process CPU, or an allocation count.
"""
import argparse
import importlib.util
import inspect
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import threading
import time
import uuid

from compare import schedule, summarize
from compare_search import quiet, save, sha


ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent / "build"
METRICS = {
    "launch_observed_to_png_ms": {"unit": "ms", "run_statistic": "elapsed"},
    "process_user_cpu_ms": {"unit": "ms", "run_statistic": "total"},
    "process_system_cpu_ms": {"unit": "ms", "run_statistic": "total"},
    "process_peak_footprint_bytes": {"unit": "bytes", "run_statistic": "maximum"},
    "ax_roundtrip_p95_ms": {"unit": "ms", "run_statistic": "p95"},
    "ax_roundtrip_max_ms": {"unit": "ms", "run_statistic": "maximum"},
}


def load_harness(directory):
    spec = importlib.util.spec_from_file_location("scopy_e2e_export_measurement", directory / "run.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if "on_launch" not in inspect.signature(module.Session.start).parameters:
        raise RuntimeError("Use the E2E Session.start(on_launch=...) hook so launch work is observed")
    return module


def observe_export(harness, app, fixture, output, idle_seconds):
    class PrivateSession(harness.Session):
        def observe(self, name):
            # Export proof comes from the PNG/private board. Never dump a clipboard AX tree.
            return {"name": name, "scope": "export_artifacts_only"}

    domain = "com.scopy.e2e.perf." + uuid.uuid4().hex
    session = PrivateSession(app, output, domain, None)
    png, error = output / "export.png", output / "export.error.txt"
    stop = output / "stop-observers"
    watchers, streams = [], []
    launched_ns = None
    completed_ns = None
    completion = threading.Event()
    shutdown = threading.Event()
    file_watcher = None

    def watch_completion(process):
        nonlocal completed_ns
        deadline = time.monotonic() + 150
        while not shutdown.is_set() and time.monotonic() < deadline and process.poll() is None:
            if png.is_file() and png.stat().st_size > 0:
                completed_ns = time.monotonic_ns()
                stop.touch()
                completion.set()
                return
            if error.exists():
                completion.set()
                return
            time.sleep(0.01)
        completion.set()

    def on_launch(process):
        nonlocal launched_ns, file_watcher
        launched_ns = time.monotonic_ns()
        file_watcher = threading.Thread(target=watch_completion, args=(process,), daemon=True)
        file_watcher.start()
        for name, arguments in (
            ("ax-roundtrips.json", [str(TOOLS / "axprobe"), "watch", str(process.pid), "180", "10", str(stop)]),
            ("process-resources.jsonl", [str(TOOLS / "procstats"), str(process.pid), "100", str(stop)]),
        ):
            stdout = (output / name).open("w")
            stderr = (output / (name + ".stderr")).open("w")
            streams.extend((stdout, stderr))
            watchers.append(subprocess.Popen(arguments, stdout=stdout, stderr=stderr))

    try:
        session.env.update(SCOPY_SCROLL_PROFILE="0", SCOPY_PROFILE_ACCESSIBILITY="0",
            SCOPY_UITEST_AUTO_EXPORT_MARKDOWN="1", SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH=str(fixture),
            SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION="100", SCOPY_UITEST_FORCE_PNGQUANT_MARKDOWN_EXPORT="0",
            SCOPY_EXPORT_DUMP_PATH=str(png), SCOPY_EXPORT_ERROR_DUMP_PATH=str(error),
            SCOPY_EXPORT_PASTEBOARD_NAME=session.pb + ".export")
        session.start(arguments=("--uitesting",), on_launch=on_launch, focus_window=False)
        completion.wait(timeout=150)
        if error.exists():
            raise RuntimeError("Export failed; the synthetic-fixture error is retained")
        if completed_ns is None:
            raise RuntimeError("Export exited or timed out before a complete PNG")
        stop.touch()
        for watcher in watchers:
            watcher.wait(timeout=5)
            if watcher.returncode:
                raise RuntimeError("An observer failed; retain the run as invalid")
        for stream in streams:
            stream.close()
        streams.clear()
        readings = [json.loads(line) for line in (output / "process-resources.jsonl").read_text().splitlines()]
        ax = json.loads((output / "ax-roundtrips.json").read_text())
        if len(readings) < 2 or not ax.get("valid"):
            raise RuntimeError("Insufficient process/AX observations")
        first, last = readings[0], readings[-1]
        summary = harness.bridge("pasteboard", session.pb + ".export", "summary")
        if summary["representations"]["public.png"]["sha256"] != sha(png):
            raise RuntimeError("Private pasteboard PNG differs from the completed file")
        with png.open("rb") as stream:
            header = stream.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("Invalid PNG signature")
        width, height = struct.unpack(">II", header[16:24])
        if idle_seconds:
            time.sleep(idle_seconds)
        idle = json.loads(subprocess.check_output([str(TOOLS / "procstats"), str(session.process.pid)], text=True))
        save(output / "idle-process.json", idle)
        metrics = {"launch_observed_to_png_ms": (completed_ns - launched_ns) / 1e6,
                   "process_user_cpu_ms": (last["user_cpu_ns"] - first["user_cpu_ns"]) / 1e6,
                   "process_system_cpu_ms": (last["system_cpu_ns"] - first["system_cpu_ns"]) / 1e6,
                   "process_peak_footprint_bytes": max(reading["lifetime_peak_physical_footprint_bytes"] for reading in readings),
                   "ax_roundtrip_p95_ms": ax["p95_ms"], "ax_roundtrip_max_ms": ax["max_ms"]}
        proof = {"fixture_sha256": sha(fixture), "png_sha256": sha(png), "png_bytes": png.stat().st_size,
                 "dimensions": {"width": width, "height": height}, "private_pasteboard_matches": True,
                 "ax_probe_start_after_launch_ms": (ax["probe_started_ns"] - launched_ns) / 1e6,
                 "ax_probe_count": len(ax["samples"]), "resource_sample_count": len(readings),
                 "resource_start_after_launch_ms": (first["observed_ns"] - launched_ns) / 1e6,
                 "resource_end_after_png_ms": (last["observed_ns"] - completed_ns) / 1e6,
                 "process_io_delta": {key: last[key] - first[key] for key in ("disk_read_bytes", "disk_write_bytes", "pageins")},
                 "idle_seconds": idle_seconds, "idle_physical_footprint_bytes": idle["physical_footprint_bytes"]}
        session.quit()
        return metrics, proof
    finally:
        shutdown.set()
        if file_watcher is not None:
            file_watcher.join(timeout=2)
        stop.touch()
        for watcher in watchers:
            if watcher.poll() is None:
                try:
                    watcher.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    watcher.terminate()
                    watcher.wait(timeout=5)
        for stream in streams:
            stream.close()
        session.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, action="append")
    parser.add_argument("--e2e-root", type=Path, default=ROOT / "scripts/e2e")
    parser.add_argument("--abba-groups", type=int, default=3)
    parser.add_argument("--idle-seconds", type=float, default=2)
    parser.add_argument("--smoke", action="store_true", help="Two discarded warmups only; cannot establish a performance result")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or not output.is_relative_to(Path("/tmp").resolve()):
        raise RuntimeError("Use a fresh directory under /tmp")
    for helper in ("axprobe", "procstats"):
        if not (TOOLS / helper).is_file():
            raise RuntimeError("Build the performance helpers before the quiet slot")
    harness = load_harness(args.e2e_root.resolve())
    variants = {"A": args.baseline.resolve(), "B": args.candidate.resolve()}
    versions = {name: plistlib.loads((app / "Contents/Info.plist").read_bytes()) for name, app in variants.items()}
    if versions["A"].get("CFBundleShortVersionString") != "0.85.0":
        raise RuntimeError("Baseline bundle must be v0.85.0")
    quiet()
    output.mkdir(parents=True, mode=0o700)
    fixtures = [path.resolve() for path in args.fixture or [ROOT / "ScopyUITests/Fixtures/user_markdown_stress.md"]]
    plan = {"reference": "v0.85.0", "candidate_commit": args.candidate_commit, "schedule": schedule(3, args.abba_groups),
            "workloads": {fixture.stem: {"metrics": METRICS, "fixture": str(fixture), "sha256": sha(fixture)} for fixture in fixtures},
            "variants": {name: {"app": str(app), "binary_sha256": sha(app / "Contents/MacOS/Scopy"),
                                 "version": versions[name].get("CFBundleShortVersionString"),
                                 "build": versions[name].get("CFBundleVersion")} for name, app in variants.items()},
            "observation_scope": "Launch-to-PNG; app-process resource counters; post-window AX round trips. No compositor or WebKit-process CPU claim."}
    save(output / "plan.json", plan)
    before = harness.bridge("general-status")
    records = []
    try:
        with (output / "runs.jsonl").open("w") as stream:
            for fixture in fixtures:
                expected_png = None
                for intended in plan["schedule"][:2] if args.smoke else plan["schedule"]:
                    quiet()
                    side = intended["variant"]
                    if sha(variants[side] / "Contents/MacOS/Scopy") != plan["variants"][side]["binary_sha256"]:
                        raise RuntimeError("App binary changed after the comparison plan was frozen")
                    if sha(fixture) != plan["workloads"][fixture.stem]["sha256"]:
                        raise RuntimeError("Fixture changed after the comparison plan was frozen")
                    record = {**intended, "workload": fixture.stem, "valid": False}
                    try:
                        metrics, proof = observe_export(harness, variants[intended["variant"]], fixture,
                                                        output / f"{fixture.stem}-{intended['id']}", args.idle_seconds)
                        if expected_png is None:
                            expected_png = proof["png_sha256"]
                        if proof["png_sha256"] != expected_png:
                            raise RuntimeError("PNG changed; adjudicate byte/pixel semantics before admitting this performance run")
                        record.update(valid=True, metrics=metrics, proof=proof)
                    except Exception as error:
                        record["failure"] = str(error)
                        raise
                    finally:
                        records.append(record)
                        stream.write(json.dumps(record) + "\n")
                        stream.flush()
                        save(output / "summary.json", {name: summarize([run for run in records if run["workload"] == name], plan["schedule"], METRICS)
                                                       for name in plan["workloads"]})
                    print(json.dumps({"workload": fixture.stem, "run": intended["id"], "valid": record["valid"]}), flush=True)
    finally:
        after = harness.bridge("general-status")
        save(output / "pasteboard-isolation.json", {"before": before, "after": after, "unchanged": before == after})
        if before != after:
            save(output / "summary.json", {"status": "invalid", "reason": "General pasteboard changed",
                                           "observations_retained_in": "runs.jsonl"})
            raise RuntimeError("General pasteboard changed; invalidate the session")


if __name__ == "__main__":
    main()
