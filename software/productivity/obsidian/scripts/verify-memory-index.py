#!/usr/bin/env python3
# Description: Structural check that the vault's MEMORY.md is a 1:1 index of the
#              memory files beside it. Invoked by verify.sh. Exit 0 = clean.
# Profiles:    workstation
# Platforms:   any (python3 only)
# Dependencies: python3
# Idempotent. Read-only.
#
# Not a bash script, so the shell conventions in docs/module-contract.md do not
# apply; the four header fields above are carried anyway. The repo linter globs
# scripts/*.sh and does not scan this file.
#
# Origin: written 2026-08-20 for the obsidian-conflicts task and vendored here
# verbatim except for the vault-path argument added below.
#
# LIMIT — read this before trusting a green result. This validates STRUCTURE.
# On 2026-08-20 a LiveSync auto-merge spliced one entry's text into the middle
# of another entry's words, and this verifier reported CLEAN: 380 pointers, 380
# files, 1:1, zero dangling, zero orphans, line count unchanged. A structure
# check cannot see corrupted prose. It is a floor, not a guarantee.
#
# Parsing note: the FIRST markdown link on a pointer line is the entry's target.
# Do not use a greedy pattern -- entry descriptions legitimately contain further
# links -- and do not use [^]]* for the link title, because titles contain
# nested brackets (e.g. "Deleting prose above an [H] table blanks a page").
# Both mistakes produce convincing false defects.
"""Verify that MEMORY.md is a 1:1 index of the memory files beside it.

Usage: verify-memory-index.py [MEMORY_DIR]

MEMORY_DIR defaults to $MEMORY_DIR, then to ~/vault/20-surface/claude-memory.
Exit 0 = clean. Exit 1 = defects found. Exit 2 = could not run the check.
"""
import os
import re
import sys

DEFAULT_MEM = os.path.expanduser("~/vault/20-surface/claude-memory")


def main() -> int:
    if len(sys.argv) > 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mem = sys.argv[1] if len(sys.argv) == 2 else os.environ.get("MEMORY_DIR") or DEFAULT_MEM

    index_path = os.path.join(mem, "MEMORY.md")
    try:
        lines = open(index_path, encoding="utf-8").read().split("\n")
        disk = {f for f in os.listdir(mem) if f.endswith(".md") and f != "MEMORY.md"}
    except OSError as exc:
        # Absence is not cleanliness. Report it as an inability to check.
        print("cannot read the memory index: %s" % exc, file=sys.stderr)
        return 2

    pointers = [l for l in lines if re.match(r"^\s*-\s*\[", l)]

    targets, unparseable = [], []
    for line in pointers:
        m = re.search(r"\]\((?P<t>[^)]+?\.md)\)", line)
        targets.append(m.group("t")) if m else unparseable.append(line)

    seen = set(targets)
    dupes = sorted({t for t in seen if targets.count(t) > 1})
    dangling = sorted(seen - disk)
    orphans = sorted(disk - seen)

    print(f"pointer lines     : {len(pointers)}")
    print(f"files on disk     : {len(disk)}")
    for label, items in (
        ("unparseable lines", unparseable),
        ("duplicate targets", dupes),
        ("dangling pointers", dangling),
        ("orphan files", orphans),
    ):
        print(f"{label:18}: {len(items)}")
        for i in items:
            print(f"    {i}")

    fails = len(unparseable) + len(dupes) + len(dangling) + len(orphans)
    print("\nRESULT:", "CLEAN" if fails == 0 else f"{fails} DEFECT(S)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
