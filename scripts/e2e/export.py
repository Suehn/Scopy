#!/usr/bin/env python3
"""Run the app's existing Markdown auto-export entry point against private pasteboards."""
import argparse
import json
from pathlib import Path
import uuid

from run import ROOT, Session, bridge, digest, run, save, wait_for


def export_side(app, output, domain, fixtures, resolutions):
    session = Session(app, output, domain, None)
    results = []
    try:
        for fixture in fixtures:
            for resolution in resolutions:
                name = f"{fixture.stem}-{resolution}"
                png = output / f"{name}.png"
                error = output / f"{name}.error.txt"
                pasteboard = session.pb + ".export"
                session.env.update(SCOPY_UITEST_AUTO_EXPORT_MARKDOWN="1",
                    SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH=str(fixture),
                    SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION=str(resolution),
                    SCOPY_UITEST_FORCE_PNGQUANT_MARKDOWN_EXPORT="0",
                    SCOPY_EXPORT_DUMP_PATH=str(png), SCOPY_EXPORT_ERROR_DUMP_PATH=str(error),
                    SCOPY_EXPORT_PASTEBOARD_NAME=pasteboard)
                session.start(arguments=("--uitesting",), focus_window=False)
                def finished():
                    assert session.process.poll() is None, "Export app exited before producing PNG"
                    assert not error.exists(), error.read_text() if error.exists() else ""
                    return png.is_file() and png.stat().st_size > 0
                wait_for(finished, f"PNG export {name}", timeout=150)
                summary = bridge("pasteboard", pasteboard, "summary")
                assert summary["representations"]["public.png"]["sha256"] == digest(png), "Dump and pasteboard PNG differ"
                size = run("/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", png)
                dimensions = {line.strip().split(": ")[0]: int(line.strip().split(": ")[1])
                    for line in size.splitlines() if "pixelWidth:" in line or "pixelHeight:" in line}
                assert dimensions["pixelWidth"] > 0 and dimensions["pixelHeight"] > 0
                results.append({"name": name, "fixture": str(fixture), "fixture_sha256": digest(fixture),
                    "png_sha256": digest(png), "png_bytes": png.stat().st_size,
                    "resolution_percent": resolution, "dimensions": dimensions,
                    "pasteboard": summary})
                save(output / f"{name}.json", results[-1])
                session.observe("export-" + name)
                session.quit()
        return results
    finally:
        session.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, action="append")
    parser.add_argument("--resolution", type=int, choices=[100, 150, 200], action="append")
    args = parser.parse_args()
    fixtures = [p.resolve() for p in (args.fixture or [ROOT / "ScopyUITests/Fixtures/user_markdown_stress.md",
                                                     ROOT / "ScopyUITests/Fixtures/chatgpt_rich_copy_sample.md"])]
    output = args.output.resolve()
    assert not output.exists(), "Use a fresh output directory"
    output.mkdir(parents=True)
    domain = "com.scopy.e2e." + uuid.uuid4().hex
    before = bridge("general-status")
    report = {"status": "running", "general_pasteboard_before": before, "sides": {}}
    try:
        for name, app in [("baseline", args.baseline), ("candidate", args.candidate)]:
            if app is not None:
                report["sides"][name] = export_side(app.resolve(), output / name, domain, fixtures, args.resolution or [100])
        if args.candidate:
            compared = []
            for baseline, candidate in zip(report["sides"]["baseline"], report["sides"]["candidate"], strict=True):
                assert baseline["name"] == candidate["name"] and baseline["fixture_sha256"] == candidate["fixture_sha256"]
                equal = baseline["png_sha256"] == candidate["png_sha256"]
                compared.append({"name": baseline["name"], "byte_equal": equal,
                    "dimensions_equal": baseline["dimensions"] == candidate["dimensions"]})
            report["comparison"] = compared
            assert all(item["byte_equal"] for item in compared), "PNG byte differences require a pixel diff and adjudication"
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", failure=str(error))
        raise
    finally:
        after = bridge("general-status")
        report["general_pasteboard_after"] = after
        report["general_pasteboard_unchanged"] = after == before
        if after != before:
            report["status"] = "invalid-general-pasteboard-changed"
        save(output / "result.json", report)
        print(json.dumps({"status": report["status"], "output": str(output)}))
    assert before == after, "General pasteboard changed; run is invalid"


if __name__ == "__main__":
    main()
