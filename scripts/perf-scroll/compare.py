#!/usr/bin/env python3
"""Plan and summarize the repository's A/A then ABBA performance protocol.

Each retained observation is one run, not one inner benchmark iteration. A driver
must report workload proof and all numeric metrics, including failed runs.
"""
import argparse
import json
import math
from pathlib import Path
import statistics


def schedule(aa_pairs=3, abba_groups=3):
    if aa_pairs < 3 or abba_groups < 3:
        raise ValueError("At least three A/A pairs and three ABBA groups are required")
    runs = [{"id": "warmup-A", "phase": "warmup", "variant": "A"},
            {"id": "warmup-B", "phase": "warmup", "variant": "B"}]
    for pair in range(1, aa_pairs + 1):
        for slot in (1, 2):
            runs.append({"id": f"aa-{pair}-{slot}", "phase": "aa", "group": pair,
                         "slot": slot, "variant": "A"})
    for group in range(1, abba_groups + 1):
        for slot, variant in enumerate("ABBA", 1):
            runs.append({"id": f"abba-{group}-{slot}", "phase": "abba", "group": group,
                         "slot": slot, "variant": variant})
    return runs


def distribution(values):
    return {"n": len(values), "mean": statistics.mean(values), "median": statistics.median(values),
            "sd": statistics.stdev(values), "min": min(values), "max": max(values)}


def summarize(records, plan, metrics):
    actual = [run for run in records if run.get("phase") != "warmup"]
    failures = [run.get("id", "unknown") for run in records if not run.get("valid", False)]
    if [run.get("id") for run in records] != [run["id"] for run in plan]:
        return {"status": "incomplete", "failures": failures,
                "reason": "Retained runs must match the frozen order exactly; missing runs cannot be dropped"}
    for observed, intended in zip(records, plan):
        if any(observed.get(key) != intended.get(key) for key in ("phase", "variant", "group", "slot")):
            return {"status": "invalid", "reason": "Run identity differs from the frozen schedule"}
        if not observed.get("proof"):
            failures.append(observed["id"])
    if failures:
        return {"status": "invalid", "failures": sorted(set(failures)),
                "reason": "Every run must pass its declared workload proof"}
    results = {}
    for name, specification in metrics.items():
        values = [run.get("metrics", {}).get(name) for run in actual]
        if not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                   and math.isfinite(value) and value >= 0 for value in values):
            return {"status": "invalid", "reason": f"Missing or invalid metric: {name}"}
        aa = [run["metrics"][name] for run in actual if run["phase"] == "aa"]
        a = [run["metrics"][name] for run in actual if run["phase"] == "abba" and run["variant"] == "A"]
        b = [run["metrics"][name] for run in actual if run["phase"] == "abba" and run["variant"] == "B"]
        noise = max(abs(aa[index] - aa[index + 1]) for index in range(0, len(aa), 2))
        pooled = math.sqrt((statistics.variance(a) + statistics.variance(b)) / 2)
        delta = statistics.mean(b) - statistics.mean(a)
        resolved = max(b) < min(a) or min(b) > max(a) or abs(delta) > max(noise, 2 * pooled)
        outcome = "within_noise"
        if resolved and delta != 0:
            improved = delta < 0 if specification.get("direction", "lower") == "lower" else delta > 0
            outcome = "improved" if improved else "regressed"
        headline = "median" if specification.get("run_statistic") == "maximum" else "mean"
        left, right = distribution(a), distribution(b)
        results[name] = {"unit": specification["unit"], "run_statistic": specification["run_statistic"],
                         "A": left, "B": right, "headline_statistic": headline,
                         "headline_delta_percent": 100 * (right[headline] / left[headline] - 1) if left[headline] else None,
                         "mean_delta": delta, "aa_resolution": noise, "aa_range": [min(aa), max(aa)],
                         "twice_pooled_sd": 2 * pooled, "ranges_overlap": not (max(b) < min(a) or min(b) > max(a)),
                         "outcome": outcome}
    return {"status": "complete", "metrics": results,
            "scope": "Per-workload observations only; no compositor frame or whole-application speed claim"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("runs", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    records = [json.loads(line) for line in args.runs.read_text().splitlines() if line.strip()]
    report = {"workloads": {}}
    for name, workload in plan["workloads"].items():
        report["workloads"][name] = summarize([run for run in records if run["workload"] == name],
                                               plan["schedule"], workload["metrics"])
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(args.output),
                      "status": {key: value["status"] for key, value in report["workloads"].items()}}))


if __name__ == "__main__":
    main()
