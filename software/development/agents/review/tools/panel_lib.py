"""Shared parsing for the review-panel tools (AI_ST-111, AI_ST-112).

Runtime-agnostic: these functions read and write files. They never call a model.
"""
from __future__ import annotations

import fnmatch
import hashlib
import re
from dataclasses import dataclass, field
from pathlib import Path

REVIEW_DIR = Path(__file__).resolve().parent.parent
DEFAULT_RUBRIC = REVIEW_DIR / "review-rubric.md"
DEFAULT_TIERS = REVIEW_DIR / "model-tiers.md"

RUBRIC_BEGIN = "<!-- BEGIN RUBRIC -->"
RUBRIC_END = "<!-- END RUBRIC -->"
TIERS_BEGIN = "<!-- BEGIN TIERS -->"
TIERS_END = "<!-- END TIERS -->"

AXES = ("correctness", "safety", "ordering", "verifiability", "completeness")
SEVERITIES = ("blocking", "non-blocking")
CONFIDENCES = ("high", "medium", "low")
FINDING_FIELDS = ("axis", "severity", "confidence", "location", "claim", "scenario", "fix")


class PanelError(Exception):
    """A usage or input error the operator must fix (exit 1)."""


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- rubric

@dataclass
class Rubric:
    version: str
    text: str  # exactly what reviewers receive
    path: Path

    @property
    def sha256(self) -> str:
        return sha256_text(self.text)


def read_rubric(path: Path = DEFAULT_RUBRIC) -> Rubric:
    raw = Path(path).read_text(encoding="utf-8")
    fm = re.match(r"\A---\n(.*?)\n---\n", raw, re.S)
    if not fm:
        raise PanelError(f"{path}: no frontmatter block")
    m = re.search(r"^version:\s*(\S+)\s*$", fm.group(1), re.M)
    if not m:
        raise PanelError(f"{path}: frontmatter has no version")
    version = m.group(1)
    if raw.count(RUBRIC_BEGIN) != 1 or raw.count(RUBRIC_END) != 1:
        raise PanelError(f"{path}: needs exactly one {RUBRIC_BEGIN} and one {RUBRIC_END}")
    i, j = raw.index(RUBRIC_BEGIN), raw.index(RUBRIC_END)
    if j < i:
        raise PanelError(f"{path}: END RUBRIC precedes BEGIN RUBRIC")
    # Only the newlines that touch the markers are trimmed; the body is otherwise verbatim.
    text = raw[i + len(RUBRIC_BEGIN):j].strip("\n") + "\n"
    b = re.match(r"REVIEW RUBRIC v(\S+)\n", text)
    if not b:
        raise PanelError(f"{path}: rubric body must start with 'REVIEW RUBRIC v<version>'")
    if b.group(1) != version:
        raise PanelError(
            f"{path}: frontmatter version {version} != body version {b.group(1)} "
            "(a bump must change both)")
    if not re.search(rf"^RUBRIC: {re.escape(version)}$", text, re.M):
        raise PanelError(f"{path}: output-format example must read 'RUBRIC: {version}'")
    return Rubric(version=version, text=text, path=Path(path))


# --------------------------------------------------------------------------- tiers

def strip_model_suffix(model: str) -> str:
    return re.sub(r"\[[^\]]*\]$", "", model.strip())


def read_tiers(path: Path = DEFAULT_TIERS) -> list[tuple[str, int]]:
    raw = Path(path).read_text(encoding="utf-8")
    if TIERS_BEGIN not in raw or TIERS_END not in raw:
        raise PanelError(f"{path}: tier table markers missing")
    block = raw[raw.index(TIERS_BEGIN) + len(TIERS_BEGIN):raw.index(TIERS_END)]
    rows: list[tuple[str, int]] = []
    for line in block.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        pat = cells[0].strip("`").strip()
        if not pat or pat == "model pattern" or set(pat) <= {"-", ":"}:
            continue
        if not cells[1].isdigit():
            raise PanelError(f"{path}: tier for {pat!r} is not an integer: {cells[1]!r}")
        rows.append((pat.lower(), int(cells[1])))
    if not rows:
        raise PanelError(f"{path}: tier table is empty")
    return rows


def tier_of(model: str, rows: list[tuple[str, int]]) -> tuple[int, str] | None:
    name = strip_model_suffix(model).lower()
    for pat, tier in rows:
        if fnmatch.fnmatchcase(name, pat):
            return tier, pat
    return None


# --------------------------------------------------------------------------- reviews

@dataclass
class Finding:
    reviewer: str
    index: int
    axis: str = ""
    severity: str = ""
    confidence: str = ""
    location: str = ""
    claim: str = ""
    scenario: str = ""
    fix: str = ""
    path: str = ""
    start: int | None = None
    end: int | None = None

    @property
    def ref(self) -> str:
        return f"{self.reviewer}#{self.index}"


@dataclass
class Review:
    source: str
    reviewer: str = ""
    rubric_version: str = ""
    verdict: str = ""
    declared: int | None = None
    findings: list[Finding] = field(default_factory=list)
    void: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def valid(self) -> bool:
        return not self.void


_DECOR = re.compile(r"^[\s#*_>]+|[\s*_]+$")
_KEYVAL = re.compile(r"^([A-Za-z][A-Za-z -]*?)\s*:\s*(.*)$")
_LOC = re.compile(r"^(?P<path>.+?)(?::(?P<start>\d+)(?:\s*[-–]\s*(?P<end>\d+))?)?$")


def normalize_path(path: str) -> str:
    p = path.strip().strip("`'\"").strip()
    p = re.sub(r"^(?:\./)+", "", p)
    return re.sub(r"/{2,}", "/", p)


def parse_location(loc: str) -> tuple[str, int | None, int | None] | None:
    loc = loc.strip().strip("`").strip()
    m = _LOC.match(loc)
    if not m or not m.group("path").strip():
        return None
    path = normalize_path(m.group("path"))
    if " " in path:
        return None
    start = int(m.group("start")) if m.group("start") else None
    end = int(m.group("end")) if m.group("end") else start
    if start is not None and end is not None and end < start:
        start, end = end, start
    return path, start, end


def parse_review(text: str, source: str, expect_version: str | None = None,
                 expect_reviewers: set[str] | None = None) -> Review:
    """Parse one reviewer reply in the rubric's OUTPUT FORMAT.

    Anything that would make the review incomparable marks it void. A void review is
    never the same as a review with no findings.
    """
    rv = Review(source=source)
    if not text.strip():
        rv.void.append(f"empty output ({len(text.encode('utf-8'))} bytes)")
        return rv

    state = "header"
    cur: Finding | None = None
    last_key: str | None = None
    seen_end = False
    header: dict[str, str] = {}

    def close() -> None:
        nonlocal cur
        if cur is not None:
            rv.findings.append(cur)
        cur = None

    for raw in text.splitlines():
        if raw.strip().startswith("```"):
            continue  # tolerate a code fence the reviewer was told not to add
        line = _DECOR.sub("", raw)
        if not line:
            continue
        upper = line.upper()
        if upper == "END REVIEW":
            close()
            seen_end = True
            break
        m_f = re.match(r"^FINDING\s+(\d+)$", line, re.I)
        if m_f and state != "checked":
            close()
            state = "finding"
            cur = Finding(reviewer="", index=int(m_f.group(1)))
            last_key = None
            continue
        if re.match(r"^CHECKED\s*:", line, re.I):
            close()
            state = "checked"
            continue
        if state == "checked":
            continue
        kv = _KEYVAL.match(line)
        if state == "header":
            if kv and kv.group(1).upper() in ("RUBRIC", "REVIEWER", "VERDICT", "FINDINGS"):
                header[kv.group(1).upper()] = kv.group(2).strip()
            continue
        # state == "finding"
        assert cur is not None
        key = kv.group(1).strip().lower() if kv else None
        if key in FINDING_FIELDS:
            if getattr(cur, key):
                rv.void.append(f"finding {cur.index}: field '{key}' given twice")
            setattr(cur, key, kv.group(2).strip())
            last_key = key
        elif last_key is not None:
            # A wrapped line: the rubric asks for one line per field, but a wrap is not
            # worth voiding a review over. It is appended to the previous field.
            setattr(cur, last_key, getattr(cur, last_key) + " " + line.strip())
            rv.warnings.append(f"finding {cur.index}: field '{last_key}' wrapped onto several lines")
        else:
            rv.void.append(f"finding {cur.index}: unexpected line before any field: {line[:60]!r}")

    if not seen_end:
        close()
        rv.void.append("truncated: no END REVIEW line")

    rv.reviewer = header.get("REVIEWER", "")
    rv.rubric_version = header.get("RUBRIC", "").lstrip("v")
    rv.verdict = header.get("VERDICT", "").upper()
    for k in ("RUBRIC", "REVIEWER", "VERDICT", "FINDINGS"):
        if not header.get(k):
            rv.void.append(f"header line {k}: missing")
    if header.get("FINDINGS"):
        if header["FINDINGS"].isdigit():
            rv.declared = int(header["FINDINGS"])
        else:
            rv.void.append(f"header FINDINGS: not a number: {header['FINDINGS']!r}")
    if rv.verdict and rv.verdict not in ("PASS", "FAIL"):
        rv.void.append(f"VERDICT must be PASS or FAIL, got {rv.verdict!r}")
    if expect_version and rv.rubric_version and rv.rubric_version != expect_version:
        rv.void.append(f"rubric version {rv.rubric_version} != expected {expect_version}")
    if expect_reviewers is not None and rv.reviewer and rv.reviewer not in expect_reviewers:
        rv.void.append(f"reviewer {rv.reviewer!r} is not a seat on this panel")
    if rv.declared is not None and rv.declared != len(rv.findings):
        rv.void.append(f"FINDINGS: {rv.declared} declared, {len(rv.findings)} FINDING blocks present")
    indices = [f.index for f in rv.findings]
    if indices != list(range(1, len(indices) + 1)):
        rv.void.append(f"findings not numbered 1..n: {indices}")

    for f in rv.findings:
        f.reviewer = rv.reviewer
        for k in FINDING_FIELDS:
            if not getattr(f, k):
                rv.void.append(f"finding {f.index}: field '{k}' missing")
        f.axis, f.severity, f.confidence = f.axis.lower(), f.severity.lower(), f.confidence.lower()
        if f.axis and f.axis not in AXES:
            rv.void.append(f"finding {f.index}: axis {f.axis!r} not one of {', '.join(AXES)}")
        if f.severity and f.severity not in SEVERITIES:
            rv.void.append(f"finding {f.index}: severity {f.severity!r} not one of {', '.join(SEVERITIES)}")
        if f.confidence and f.confidence not in CONFIDENCES:
            rv.void.append(f"finding {f.index}: confidence {f.confidence!r} not one of {', '.join(CONFIDENCES)}")
        if f.location:
            loc = parse_location(f.location)
            if loc is None:
                rv.void.append(f"finding {f.index}: location {f.location!r} is not path[:line[-line]]")
            else:
                f.path, f.start, f.end = loc

    blocking = any(f.severity == "blocking" for f in rv.findings)
    if rv.verdict in ("PASS", "FAIL") and (rv.verdict == "FAIL") != blocking:
        rv.warnings.append(
            f"VERDICT {rv.verdict} disagrees with findings ({'a' if blocking else 'no'} blocking finding)")
    return rv


# --------------------------------------------------------------------------- matching

STOPWORDS = frozenset("""
a an and are as at be been being but by can cannot could did do does doing for from had has
have if in into is it its it's may might must no not of on once only or so such than that
the their them then there these this those to too under up was were when where which while
who will with would yet you your step line file here also any all each every one
""".split())


def claim_tokens(claim: str) -> frozenset[str]:
    """Normalize a claim into a set of content tokens.

    Lower-cased; split on anything other than letters, digits, and the characters _ . / $ -
    that occur inside paths, flags, and variables. Edge punctuation and stopwords are
    dropped, and a crude suffix strip folds plurals and tenses ("fails"/"failed" ->
    "fail"). No synonyms and no embeddings: two claims match only if they share words.
    """
    out = set()
    for tok in re.findall(r"[a-z0-9_./$-]+", claim.lower()):
        tok = tok.strip(".-/")
        if len(tok) < 2 or tok in STOPWORDS:
            continue
        if re.fullmatch(r"[a-z]+", tok) and len(tok) > 4:
            for suf in ("ing", "ed", "es", "s"):
                if tok.endswith(suf) and len(tok) - len(suf) >= 3:
                    tok = tok[: -len(suf)]
                    break
        out.add(tok)
    return frozenset(out)


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def paths_match(a: str, b: str) -> bool:
    """Equal, or one is a suffix of the other on a '/' boundary (x.sh vs dir/x.sh)."""
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    return long_.endswith("/" + short)


def line_gap(a: Finding, b: Finding) -> int | None:
    """Lines between the two ranges (0 if they overlap); None if either has no line."""
    if a.start is None or b.start is None:
        return None
    a_end = a.end if a.end is not None else a.start
    b_end = b.end if b.end is not None else b.start
    if a_end < b.start:
        return b.start - a_end
    if b_end < a.start:
        return a.start - b_end
    return 0


def findings_match(a: Finding, b: Finding, line_window: int, min_similarity: float) -> bool:
    if a.reviewer == b.reviewer:
        return False
    if not paths_match(a.path, b.path):
        return False
    gap = line_gap(a, b)
    if gap is not None and gap > line_window:
        return False
    return jaccard(claim_tokens(a.claim), claim_tokens(b.claim)) >= min_similarity


def cluster(findings: list[Finding], line_window: int, min_similarity: float) -> list[list[Finding]]:
    """Single-link clustering: any matching pair joins their clusters (union-find)."""
    parent = list(range(len(findings)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(findings)):
        for j in range(i + 1, len(findings)):
            if findings_match(findings[i], findings[j], line_window, min_similarity):
                parent[find(i)] = find(j)
    groups: dict[int, list[Finding]] = {}
    for i, f in enumerate(findings):
        groups.setdefault(find(i), []).append(f)
    return list(groups.values())
