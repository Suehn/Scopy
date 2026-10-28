#!/usr/bin/env python3
"""Resolve the app built for this checkout and configuration through Xcode."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", choices=("Debug", "Release"))
    args = parser.parse_args()
    result = subprocess.run(
        [
            "xcodebuild", "-project", "Scopy.xcodeproj", "-scheme", "Scopy",
            "-configuration", args.configuration, "-showBuildSettings", "-json",
        ],
        check=True, stdout=subprocess.PIPE, text=True,
    )
    targets = [entry for entry in json.loads(result.stdout) if entry["target"] == "Scopy"]
    if len(targets) != 1:
        raise SystemExit("Expected exactly one Scopy target in Xcode build settings.")
    settings = targets[0]["buildSettings"]
    app = Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]
    if not app.is_dir():
        raise SystemExit(f"Build the {args.configuration} app first: {app}")
    print(app)


if __name__ == "__main__":
    main()
