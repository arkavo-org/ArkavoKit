#!/usr/bin/env python3
"""Fail when a build log has a compiler warning in ArkavoKit's own sources.

Usage: scripts/check-warnings.py BUILD_LOG [ALLOWLIST]

Every package target treats warnings as errors, but the compiler keeps some diagnostics as
warnings even then, and a few deprecated calls are pinned on purpose. This reads the build log
of a clean `swift build --build-tests` and fails on any warning in Sources/ or Tests/ that the
allowlist (scripts/warning-allowlist.txt) does not name, and on any allowlist entry that no
longer occurs, so the list only ever shrinks. Warnings in dependencies are ignored.

An allowlist line is `path: message` (no line number, so edits elsewhere in the file don't
break it). The same line repeated allows that many occurrences in the file.
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]")
WARNING = re.compile(r"^(?P<path>/\S+?\.swift):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.*?)(?: \[#\w*\])?\s*$")


def warnings_in(log: str) -> collections.Counter:
    seen = set()
    for raw in log.splitlines():
        match = WARNING.match(ESCAPES.sub("", raw))
        if not match:
            continue
        path = pathlib.Path(match["path"])
        try:
            relative = path.resolve().relative_to(ROOT).as_posix()
        except ValueError:
            # A CI checkout sits elsewhere; keep the part from Sources/ or Tests/ on.
            parts = path.parts
            starts = [i for i, part in enumerate(parts) if part in ("Sources", "Tests")]
            if not starts:
                continue
            relative = "/".join(parts[starts[-1]:])
        if not relative.startswith(("Sources/", "Tests/")):
            continue
        seen.add((relative, match["line"], match["col"], match["msg"]))
    return collections.Counter(f"{path}: {msg}" for path, _, _, msg in seen)


def allowed(path: pathlib.Path) -> collections.Counter:
    if not path.exists():
        return collections.Counter()
    lines = (line.strip() for line in path.read_text().splitlines())
    return collections.Counter(line for line in lines if line and not line.startswith("#"))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    found = warnings_in(pathlib.Path(sys.argv[1]).read_text(errors="replace"))
    allowlist = allowed(pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "scripts" / "warning-allowlist.txt")
    unexpected = found - allowlist
    stale = allowlist - found
    for entry in sorted(unexpected.elements()):
        print(f"error: compiler warning: {entry}")
    for entry in sorted(stale.elements()):
        print(f"error: allowlisted warning no longer occurs; remove it from scripts/warning-allowlist.txt: {entry}")
    if unexpected or stale:
        print(f"{sum(unexpected.values())} unexpected warning(s), {sum(stale.values())} stale allowlist entr(ies)")
        return 1
    print(f"check-warnings: no unexpected warnings ({sum(found.values())} pinned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
