#!/usr/bin/env python3
"""Reject UI test environment hooks in an actual archived Apple app."""

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    app = parser.parse_args().app
    if not app.is_dir() or not (app / "Info.plist").is_file():
        parser.error("expected an archived .app with Info.plist")
    magic = {
        bytes.fromhex(value)
        for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                      "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
    }
    count = 0
    failures = []
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as source:
            if source.read(4) not in magic:
                continue
            count += 1
            source.seek(0)
            if b"TOS_UI_TEST_" in source.read():
                failures.append(str(path.relative_to(app)))
    if not count:
        raise SystemExit("FAIL: no Mach-O binaries inspected")
    if failures:
        raise SystemExit("FAIL: UI test hooks in Release: " + ", ".join(failures))
    print(f"PASS: {count} Mach-O binaries contain no UI test environment hooks")


if __name__ == "__main__":
    main()
