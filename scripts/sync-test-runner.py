#!/usr/bin/env python3
"""Check or refresh vendored test runners without touching plugin cases or code."""

import argparse
import json
import shutil
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
FILES = ("run.py", "runner_checks.py", "docs_checks.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=SOURCE.parent)
    args = parser.parse_args()
    changed = []
    targets = []
    for repo in sorted(args.root.glob("*.nvim")):
        manifest = repo / "tests/cases.json"
        if repo.resolve() == SOURCE or not manifest.is_file():
            continue
        if json.loads(manifest.read_text())["version"] != 1:
            parser.error("Unsupported runner manifest version: " + str(repo))
        targets.append(repo)
    for repo in targets:
        for filename in FILES:
            manifest = json.loads((repo / "tests/cases.json").read_text())
            if filename == "docs_checks.py" and not any(
                "tests/docs_checks.py" in case["files"] for case in manifest["cases"]
            ):
                continue
            source = SOURCE / "tests" / filename
            destination = repo / "tests" / filename
            if (
                not destination.is_file()
                or destination.read_bytes() != source.read_bytes()
            ):
                changed.append(str(destination))
                if args.write:
                    shutil.copyfile(source, destination)
    for path in changed:
        print(("Updated: " if args.write else "Different: ") + path)
    print("Checked " + str(len(targets)) + " sibling runner copies")
    return int(bool(changed) and args.check)


if __name__ == "__main__":
    raise SystemExit(main())
