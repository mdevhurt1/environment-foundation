#!/usr/bin/env python3
"""Tally panel findings for concurrence (AI_ST-112).

Reads N findings files written in the rubric's OUTPUT FORMAT, voids any that are
empty, truncated, or malformed, groups findings that describe the same defect, and
reports which groups reach the quorum (3 of 4 seats).

Matching rule (mechanical, deliberately simple; see panel-protocol.md):
  two findings from DIFFERENT reviewers match when
    1. their paths are equal, or one is a '/'-boundary suffix of the other, and
    2. their line ranges are at most --line-window lines apart (a finding with no line
       number passes this test), and
    3. the Jaccard similarity of their normalized claim tokens >= --min-similarity.
  Matches are joined single-link (A~B and B~C put A, B, C in one group). A group's
  concurrence is the number of DISTINCT seats in it. A void seat never concurs.

It proposes groups. It does not rule on them. The operator reads every CONFIRMED and
NEAR group and records the adjudication in the release record.

Exit codes: 0 the panel is complete (every seat produced a valid review), whatever the
findings are; 2 the panel is incomplete (a seat is void or missing), so rerun or replace
that seat before you record the round; 1 usage or input error.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel_lib import (Finding, PanelError, Review, cluster,  # noqa: E402
                       parse_review, read_rubric)

SEVERITY_ORDER = {"blocking": 0, "non-blocking": 1}


def load_reviews(files: list[Path], expect_version: str | None,
                 seat_reviewers: list[str] | None) -> list[Review]:
    expected = set(seat_reviewers) if seat_reviewers else None
    reviews: list[Review] = []
    seen: dict[str, str] = {}
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except FileNotFoundError:
            r = Review(source=str(f))
            r.void.append("no output file")
            reviews.append(r)
            continue
        r = parse_review(text, str(f), expect_version, expected)
        if r.reviewer and r.reviewer in seen:
            r.void.append(f"reviewer {r.reviewer!r} already reported in {seen[r.reviewer]}")
        elif r.reviewer:
            seen[r.reviewer] = str(f)
        reviews.append(r)
    return reviews


def group_summary(g: list[Finding]) -> dict:
    seats = sorted({f.reviewer for f in g})
    sev = sorted({f.severity for f in g}, key=lambda s: SEVERITY_ORDER.get(s, 9))
    starts = [f.start for f in g if f.start is not None]
    ends = [f.end for f in g if f.end is not None]
    path = min((f.path for f in g), key=len)
    loc = path if not starts else f"{path}:{min(starts)}" + (f"-{max(ends)}" if max(ends) != min(starts) else "")
    return {
        "seats": seats,
        "concurrence": len(seats),
        "location": loc,
        "severities": {s: sum(1 for f in g if f.severity == s) for s in sev},
        "axes": sorted({f.axis for f in g}),
        "findings": [
            {"ref": f.ref, "location": f.location, "severity": f.severity,
             "confidence": f.confidence, "axis": f.axis, "claim": f.claim}
            for f in sorted(g, key=lambda f: (f.reviewer, f.index))
        ],
    }


def tally(reviews: list[Review], seats: int, quorum: int, line_window: int,
          min_similarity: float) -> dict:
    valid = [r for r in reviews if r.valid]
    void = [r for r in reviews if not r.valid]
    missing = max(0, seats - len(reviews))
    findings = [f for r in valid for f in r.findings]
    groups = [group_summary(g) for g in cluster(findings, line_window, min_similarity)]
    groups.sort(key=lambda g: (-g["concurrence"], min(SEVERITY_ORDER.get(s, 9) for s in g["severities"]),
                               g["location"]))
    complete = len(valid) == seats and not void and len(reviews) == seats
    return {
        "seats": seats,
        "quorum": quorum,
        "valid": len(valid),
        "void": [{"source": r.source, "reviewer": r.reviewer or None, "reasons": r.void} for r in void],
        "missing": missing,
        "extra": max(0, len(reviews) - seats),
        "complete": complete,
        "rubric_versions": sorted({r.rubric_version for r in valid}),
        "warnings": [{"source": r.source, "warnings": r.warnings} for r in reviews if r.warnings],
        "matching": {"line_window": line_window, "min_similarity": min_similarity},
        "confirmed": [g for g in groups if g["concurrence"] >= quorum],
        "near": [g for g in groups if 1 < g["concurrence"] < quorum],
        "single": [g for g in groups if g["concurrence"] == 1],
    }


def render(t: dict) -> str:
    out = []
    status = "COMPLETE" if t["complete"] else "INCOMPLETE (rerun or replace the void/missing seat before recording)"
    out.append(f"PANEL: {t['seats']} seats, {t['valid']} valid, {len(t['void'])} void, "
               f"{t['missing']} missing -> {status}")
    if t["extra"]:
        out.append(f"  ! {t['extra']} more findings files than seats")
    out.append(f"rubric version(s): {', '.join(t['rubric_versions']) or 'none'}; "
               f"match: line window {t['matching']['line_window']}, "
               f"claim similarity >= {t['matching']['min_similarity']}")
    for v in t["void"]:
        out.append(f"VOID {v['source']} ({v['reviewer'] or 'reviewer unknown'}): " + "; ".join(v["reasons"]))
    for w in t["warnings"]:
        out.append(f"WARN {w['source']}: " + "; ".join(w["warnings"]))

    def section(title: str, groups: list[dict], tag: str) -> None:
        out.append("")
        out.append(f"{title}: {len(groups)}")
        for i, g in enumerate(groups, 1):
            sev = ", ".join(f"{k} x{v}" for k, v in g["severities"].items())
            out.append(f"{tag}{i}  {g['concurrence']}/{t['seats']} seats  {g['location']}  [{sev}]  axis: {'/'.join(g['axes'])}")
            for f in g["findings"]:
                out.append(f"    {f['ref']} @ {f['location']} ({f['severity']}, {f['confidence']}): {f['claim']}")

    section(f"CONFIRMED (>= {t['quorum']} of {t['seats']} seats)", t["confirmed"], "C")
    section("NEAR (2+ seats, below quorum: operator adjudicates)", t["near"], "N")
    section("SINGLE (1 seat)", t["single"], "S")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", type=Path, help="findings files, one per seat")
    ap.add_argument("--manifest", type=Path,
                    help="panel.json from assemble_prompts.py: sets seats, reviewers, rubric version, "
                         "and (with no FILES) reads seat-N.md beside it")
    ap.add_argument("--rubric", type=Path, help="rubric file whose version every review must cite")
    ap.add_argument("--seats", type=int, default=4)
    ap.add_argument("--quorum", type=int, default=3)
    ap.add_argument("--line-window", type=int, default=5)
    ap.add_argument("--min-similarity", type=float, default=0.25)
    ap.add_argument("--json", action="store_true", help="print the tally as JSON")
    a = ap.parse_args(argv)

    try:
        expect_version = None
        seat_reviewers = None
        files = list(a.files)
        seats = a.seats
        if a.manifest:
            m = json.loads(a.manifest.read_text(encoding="utf-8"))
            expect_version = m["rubric"]["version"]
            seat_reviewers = [s["reviewer"] for s in m["seats"]]
            seats = m["panel_size"]
            if not files:
                files = [a.manifest.parent / s["findings_file"] for s in m["seats"]]
        if a.rubric:
            v = read_rubric(a.rubric).version
            if expect_version and v != expect_version:
                raise PanelError(f"--rubric is v{v} but the manifest says v{expect_version}")
            expect_version = v
        if not files:
            raise PanelError("no findings files given")
        if not 1 <= a.quorum <= seats:
            raise PanelError(f"quorum {a.quorum} must be between 1 and {seats}")
    except (PanelError, OSError, KeyError, ValueError) as e:
        print(f"tally_concurrence: {e}", file=sys.stderr)
        return 1

    reviews = load_reviews(files, expect_version, seat_reviewers)
    t = tally(reviews, seats, a.quorum, a.line_window, a.min_similarity)
    print(json.dumps(t, indent=2) if a.json else render(t), end="" if not a.json else "\n")
    return 0 if t["complete"] else 2


if __name__ == "__main__":
    sys.exit(main())
