#!/usr/bin/env python3
"""Compare frozen Release ScopyBench executables on one offline, content-private DB.

No builds or application launches occur here. This is an engine benchmark; copied
database payload references are never handed to ClipboardService or the app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

from compare import schedule, summarize


def sha(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def quiet():
    forbidden = {"swift-frontend", "swiftc", "swift-build", "xcodebuild", "clang", "clang++", "ld", "Scopy", "ScopyBench"}
    active = [Path(item.strip()).name for item in command("ps", "-axo", "comm=").splitlines()
              if Path(item.strip()).name in forbidden]
    if active:
        raise RuntimeError("Quiet slot has competing processes: " + ", ".join(sorted(set(active))))


def database_stats(path):
    with sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
        rows, plain_bytes, largest = connection.execute(
            "SELECT COUNT(*), SUM(length(CAST(plain_text AS BLOB))), MAX(length(CAST(plain_text AS BLOB))) FROM clipboard_items"
        ).fetchone()
        external = connection.execute("SELECT COUNT(*) FROM clipboard_items WHERE storage_ref IS NOT NULL AND storage_ref <> ''").fetchone()[0]
        return {"rows": rows, "plain_utf8_bytes": plain_bytes, "largest_plain_utf8_bytes": largest,
                "external_payload_references": external, "schema_version": connection.execute("PRAGMA user_version").fetchone()[0]}


def clone_database(source, destination):
    wal = Path(str(source) + "-wal")
    if wal.exists() and wal.stat().st_size:
        raise RuntimeError("Source snapshot has a nonempty WAL; make an online backup before measurement")
    before = sha(source)
    destination.parent.mkdir(parents=True)
    shutil.copy2(source, destination)
    destination.chmod(0o600)
    if sha(destination) != before or sha(source) != before:
        raise RuntimeError("Source changed while it was copied")
    # System SQLite read-only WAL connections need writable, isolated sidecars.
    with sqlite3.connect(destination.as_uri() + "?mode=ro", uri=True) as connection:
        connection.execute("PRAGMA schema_version").fetchone()
    if sha(destination) != before:
        raise RuntimeError("Preparing empty sidecars changed the database image")
    return before


def run_bench(binary, database, arguments, output):
    started = time.monotonic_ns()
    with (output / "bench.json").open("w") as stdout, (output / "stderr.txt").open("w") as stderr:
        process = subprocess.Popen([str(binary), "--db", str(database), "--json", *arguments],
                                   env=dict(os.environ, SCOPY_PERF_METRICS="1"), stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + 180
        timed_out = False
        try:
            while True:
                finished, status, usage = os.wait4(process.pid, os.WNOHANG)
                if finished:
                    break
                if time.monotonic() > deadline:
                    timed_out = True
                    process.kill()
                    _, status, usage = os.wait4(process.pid, 0)
                    break
                time.sleep(0.01)
        except BaseException:
            process.kill()
            os.wait4(process.pid, 0)
            raise
        process.returncode = os.waitstatus_to_exitcode(status)
    resources = {"process_wall_ms": (time.monotonic_ns() - started) / 1e6,
                 "process_user_cpu_ms": usage.ru_utime * 1000, "process_system_cpu_ms": usage.ru_stime * 1000,
                 "process_peak_rss_bytes": usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024,
                 "minor_faults": usage.ru_minflt, "major_faults": usage.ru_majflt,
                 "block_input_operations": usage.ru_inblock, "block_output_operations": usage.ru_oublock,
                 "voluntary_context_switches": usage.ru_nvcsw, "involuntary_context_switches": usage.ru_nivcsw}
    save(output / "resources.json", resources)
    if timed_out:
        raise RuntimeError("ScopyBench exceeded the 180 second bound; its child was stopped")
    if process.returncode:
        raise RuntimeError(f"ScopyBench exited {process.returncode}; retained stderr is at {output / 'stderr.txt'}")
    return json.loads((output / "bench.json").read_text()), resources


COMMON = ["--layer", "engine", "--sort", "relevance", "--force-full-fuzzy", "--prepare-short-index"]
WORKLOADS = {
    "cold": {"arguments": COMMON + ["--mode", "fuzzy", "--query", "cmd", "--iters", "1", "--warmup", "0"],
             "proof": "full_index_source_database", "phase": "full_index_build_from_db",
             "description": "Full index absent; OS file cache is not flushed. Startup and phase costs are separate."},
    "warm_query": {"arguments": COMMON + ["--mode", "fuzzyPlus", "--query", "这个问题", "--reset-query", "q", "--iters", "15", "--warmup", "3"],
                   "proof": "full_index_source_memory",
                   "description": "Typical CJK query with a different untimed query before each sample; ranking cache misses."},
    "warm_load": {"arguments": COMMON + ["--mode", "fuzzy", "--query", "cmd", "--iters", "1", "--warmup", "0"],
                  "proof": "full_index_source_disk_cache", "phase": "full_index_disk_cache_load",
                  "description": "Fresh process reading an already persisted full index; not real-app footprint."},
}


def workload_metrics(name):
    result = {"query_median_ms": {"unit": "ms", "run_statistic": "median"},
              "query_p95_ms": {"unit": "ms", "run_statistic": "p95"},
              "process_wall_ms": {"unit": "ms", "run_statistic": "elapsed"},
              "process_user_cpu_ms": {"unit": "ms", "run_statistic": "total"},
              "process_system_cpu_ms": {"unit": "ms", "run_statistic": "total"},
              "process_peak_rss_bytes": {"unit": "bytes", "run_statistic": "maximum"}}
    if WORKLOADS[name].get("phase"):
        result["phase_ms"] = {"unit": "ms", "run_statistic": "elapsed"}
    return result


def prepare(args):
    output = args.output.resolve()
    if output.exists() or not output.is_relative_to(Path("/tmp").resolve()):
        raise RuntimeError("Use a fresh output directory below /tmp; archive completed evidence afterward")
    source = args.snapshot.resolve()
    stats = database_stats(source)
    if stats["rows"] != args.expected_rows:
        raise RuntimeError("Snapshot row count differs from the declared workload")
    output.mkdir(parents=True, mode=0o700)
    copied = output / "source" / "clipboard.db"
    snapshot_sha = clone_database(source, copied)
    variants = {}
    for name in ("A", "B"):
        checkout = getattr(args, "baseline_checkout" if name == "A" else "candidate_checkout").resolve()
        binary = getattr(args, "baseline" if name == "A" else "candidate").resolve()
        inputs = ["Scopy", "ScopyUISupport", "Tools/ScopyBench", "Package.swift", "project.yml"]
        if command("git", "status", "--porcelain", "--untracked-files=all", "--", *inputs, cwd=checkout):
            raise RuntimeError("Commit production inputs before measuring")
        if name == "A" and command("git", "diff", "--name-only", "v0.85.0", "HEAD", "--", *inputs, cwd=checkout):
            raise RuntimeError("Baseline production inputs differ from v0.85.0")
        pinned = output / "bin" / name / "ScopyBench"
        pinned.parent.mkdir(parents=True)
        shutil.copy2(binary, pinned)
        variants[name] = {"checkout": str(checkout), "commit": command("git", "rev-parse", "HEAD", cwd=checkout),
                          "binary": str(pinned), "binary_sha256": sha(pinned), "original_binary": str(binary),
                          "build_evidence": str(getattr(args, "baseline_build_log" if name == "A" else "candidate_build_log").resolve())}
        build_log = Path(variants[name]["build_evidence"])
        if not build_log.is_file():
            raise RuntimeError("Provide each Release build log; a binary path alone cannot establish its build mode")
        shutil.copy2(build_log, output / "bin" / name / "build.log")
    plan = {"schema_version": 1, "reference": "v0.85.0", "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "snapshot": str(copied), "snapshot_sha256": snapshot_sha, "snapshot_stats": stats,
            "variants": variants, "schedule": schedule(args.aa_pairs, args.abba_groups),
            "workloads": {name: {**WORKLOADS[name], "metrics": workload_metrics(name)} for name in args.workload},
            "host": {"os": command("sw_vers"), "hardware": command("sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"),
                     "xcode": command("xcodebuild", "-version"), "power": command("pmset", "-g", "batt")},
            "metric_limits": ["CPU is process-wide and includes open/prepare/reset/close; it is not timed-query CPU.",
                              "Wall minus CPU is not wait time: concurrent CPU may exceed wall duration.",
                              "Block IO counters are operations, not byte counts. RSS is not app physical footprint."]}
    save(output / "plan.json", plan)
    return plan


def sample(plan, output):
    if (output / "runs.jsonl").exists() or (output / "cache-seeds").exists():
        raise RuntimeError("A started measurement cannot be overwritten; keep it and create a fresh plan")
    source = Path(plan["snapshot"])
    if sha(source) != plan["snapshot_sha256"]:
        raise RuntimeError("Frozen source changed")
    quiet()
    seeds = {}
    for side, info in plan["variants"].items():
        binary = Path(info["binary"])
        if sha(binary) != info["binary_sha256"]:
            raise RuntimeError("Frozen binary changed")
        seed = output / "cache-seeds" / side / "clipboard.db"
        clone_database(source, seed)
        prime = output / "prime" / side
        prime.mkdir(parents=True)
        payload, _ = run_bench(binary, seed, WORKLOADS["cold"]["arguments"], prime)
        if not list(seed.parent.glob("clipboard.db.fullindex.*.bin")):
            raise RuntimeError("Prime failed to persist the full index")
        seeds[side] = seed.parent
    records = []
    with (output / "runs.jsonl").open("w") as stream:
        for workload, specification in plan["workloads"].items():
            for intended in plan["schedule"]:
                quiet()
                side = intended["variant"]
                directory = output / "runs" / workload / intended["id"]
                directory.mkdir(parents=True)
                runtime = directory / "runtime"
                shutil.copytree(seeds[side], runtime)
                database = runtime / "clipboard.db"
                if workload == "cold":
                    for cache in runtime.glob("clipboard.db.fullindex.*"):
                        cache.unlink()
                record = {**intended, "workload": workload, "valid": False,
                          "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                try:
                    payload, resources = run_bench(Path(plan["variants"][side]["binary"]), database,
                                                   specification["arguments"], directory)
                    counters = {value["name"]: value["value"] for value in payload.get("perf", {}).get("counters", [])}
                    phases = {value["name"]: value["ms"] for value in payload.get("perf", {}).get("phases", [])}
                    if payload.get("db_item_count") != plan["snapshot_stats"]["rows"] or counters.get(specification["proof"]) != 1:
                        raise RuntimeError("Workload did not reach the declared index path")
                    metrics = {"query_median_ms": payload["median_ms"], "query_p95_ms": payload["p95_ms"],
                               **{key: resources[key] for key in specification["metrics"] if key in resources}}
                    if specification.get("phase"):
                        metrics["phase_ms"] = phases[specification["phase"]]
                    record.update(valid=True, proof={"index_source": specification["proof"], "rows": payload["db_item_count"]}, metrics=metrics)
                except Exception as error:
                    record["failure"] = str(error)
                    raise
                finally:
                    records.append(record)
                    stream.write(json.dumps(record) + "\n")
                    stream.flush()
                    save(output / "summary.json", {name: summarize([run for run in records if run["workload"] == name], plan["schedule"], value["metrics"])
                                                   for name, value in plan["workloads"].items()})
                    shutil.rmtree(runtime)
                print(json.dumps({"workload": workload, "run": intended["id"], "valid": record["valid"]}), flush=True)
    if sha(source) != plan["snapshot_sha256"]:
        raise RuntimeError("Frozen source changed during measurement")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "candidate", "baseline-checkout", "candidate-checkout", "baseline-build-log", "candidate-build-log", "snapshot", "output"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--run-plan", type=Path, help="Run a previously frozen plan; no input paths are replaced")
    parser.add_argument("--expected-rows", type=int, default=10000)
    parser.add_argument("--aa-pairs", type=int, default=3)
    parser.add_argument("--abba-groups", type=int, default=3)
    parser.add_argument("--workload", action="append", choices=WORKLOADS)
    parser.add_argument("--prepare-only", action="store_true", help="Freeze offline inputs without starting a benchmark")
    args = parser.parse_args()
    if args.run_plan:
        plan_path = args.run_plan.resolve()
        sample(json.loads(plan_path.read_text()), plan_path.parent)
        return
    required = ("baseline", "candidate", "baseline_checkout", "candidate_checkout", "baseline_build_log", "candidate_build_log", "snapshot", "output")
    if any(getattr(args, name) is None for name in required):
        parser.error("Provide all binary, checkout, build-log, snapshot and output paths, or --run-plan")
    args.workload = args.workload or list(WORKLOADS)
    plan = prepare(args)
    print(json.dumps({"plan": str(args.output.resolve() / "plan.json"), "rows": plan["snapshot_stats"]["rows"]}), flush=True)
    if not args.prepare_only:
        sample(plan, args.output.resolve())


if __name__ == "__main__":
    main()
