#!/usr/bin/env bash
# Description: cc-scrub outbound-text arm - sweeps a staged PR/issue/comment package for BOTH publication risks before it is posted: AI register and typography tells (this file's rules), and F1 disclosure/topology tells (delegated to cc-scrub.sh so those four range-checked rules keep living in one place). Calibrates itself, and its delegate, before it sweeps.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, grep with -P (PCRE), file, coreutils, canonical/scripts/cc-scrub.sh
#
# WHY THIS EXISTS (Plane INFRA-62; CEO ruling 2026-09-04)
#
#   Scrub surfaces are three, not one. Tracked file content was always
#   covered. Commit messages were added under RESEARCH-1, after a scrub
#   commit was found quoting the LAN address it was removing, four times,
#   in a public repo's history. The third surface is outbound text -- the
#   PR bodies, issue text and comments posted upstream under the operator's
#   own account -- and it leaks both classes independently:
#
#     * F1 disclosure. The staged LiteLLM PR was swept for this by hand.
#     * AI register.   It was NOT, and the upstream issue that preceded it
#                      went out carrying em-dashes.
#
#   Retro-editing a posted text does not remove the fingerprint. The edit
#   history stays visible and edit-churn is itself a signal, so the sweep
#   has to happen BEFORE the first post. This is a pre-flight gate, not a
#   report.
#
# WHY A SIBLING TOOL AND NOT A FLAG ON cc-scrub
#
#   cc-scrub parks the register class (F3) on an undecided policy question
#   and warns that shipping it early "would block 81% of this repo's text
#   files on a taste call". Measured while writing this: 86 files in this
#   module alone carry an em-dash, this header's own module README among
#   them. The CEO ruling resolves that taste call for OUTBOUND DRAFTS
#   ONLY; it says nothing about repo prose, and nothing here should be
#   read as saying an em-dash in a README is a defect.
#
#   A separate tool whose corpus is an outbound package cannot be pointed
#   at the tracked tree by accident. A mode flag on cc-scrub could be, and
#   `cc-scrub --audit` would begin failing on this repo's own
#   documentation the day these rules landed inside it. The scope
#   restriction is structural here, which is the only kind that survives.
#
# WHAT IT DOES NOT COVER
#
#   Lexical AI-isms -- vocabulary and sentence-shape tells -- are NOT
#   implemented, and their absence is stated on every run rather than left
#   for a reader to assume. Two reasons, both binding:
#
#     * The F2 provenance vocabulary is excluded from this public repo
#       permanently, on cc-scrub's reasoning: that pattern set IS the
#       disclosure it hunts. It stays in the private sweep.
#     * The generic register vocabulary has no measured precision here,
#       and cc-scrub's own negative control already records two review
#       verdicts against the obvious candidates -- "comprehensive test
#       coverage and robust handling" and a plain "let me know if you want
#       changes" are both baits that must NOT fire. Shipping a word list
#       now would be this tool guessing at the operator's taste, which is
#       the exact call cc-scrub declined to make.
#
#   Every rule below is instead mechanically decidable: a codepoint is
#   present or it is not.

set -uo pipefail   # Reporter, NOT -e: every rule must run and report. An
                   # early abort would hide the second finding.

CC_SCRUB_OUTBOUND_VERSION="1.0"

# =========================================================================
# RULES
#
# PATTERNS ARE UTF-8 BYTE SEQUENCES, MATCHED UNDER LC_ALL=C, and that is
# not incidental. `grep -P '\x{2014}'` means the CHARACTER U+2014 only
# while PCRE is in UTF mode, which GNU grep enables from the locale. Under
# LC_ALL=C the same pattern means byte 0x14 and matches nothing -- a
# silent false zero of exactly the shape this family of tools exists to
# refuse, and one that would appear only on the machine whose locale
# differed. Byte sequences plus a pinned LC_ALL are true in every locale.
#
# Each pattern is a PCRE on a single line so the test suite can mutate one
# detector and prove calibration fails loudly.
# =========================================================================

RE_EMDASH='\xE2\x80\x94'
RE_CURLYQ='\xE2\x80[\x98\x99\x9C\x9D]'
RE_NBSP='(?:\xC2\xA0|\xE2\x80\xAF)'
RE_ELLIPSIS='\xE2\x80\xA6'
# An en dash between digits is a numeric range and ordinary typography in
# a version table. Flanked by spaces it is doing an em dash's job, which is
# the tell -- so the rule is the spacing, not the character.
RE_ENDASH='(?<=[ \t])\xE2\x80\x93(?=[ \t])'
# The ids this company mints are BARE: __cc_mint_session_id returns 22
# lowercase hex characters with no prefix (asserted in test_launch_flags),
# and that value names every tree slot and stamps every event. cc-scrub's
# session-id rule looks for a `session_` prefix and structurally cannot
# see one of these, so a draft quoting a session id sweeps clean through
# the F1 arm today. The exact length plus alnum boundaries is what keeps
# git shas out: a 40-hex sha contains no alnum-delimited 22-char run, and
# neither does a dashless uuid at 32.
RE_SESSIONBARE='(?<![0-9A-Za-z])[0-9a-f]{22}(?![0-9A-Za-z])'
# The harness co-author trailer and the session URL it appends to every
# commit message. Both belong in local history; in a PR body on somebody
# else's repository they are an unambiguous disclosure. The assistant name
# is written as a one-character class on purpose: written plainly, this
# line would match itself, and the tool would report its own source
# forever -- the same reasoning that keeps the F2 pattern set out of this
# repo. Both literals need the treatment, and the URL one is the
# subtle half: under (?i) the bare word in `claude.ai` satisfied the
# co-author alternative's own name check, so this line matched itself
# through the OTHER branch of its own alternation.
RE_AITRAILER='(?i)(?:Co-Authored-By:[^\n]*\b[C]laude\b|\b[C]laude-Session[ \t]*:|[c]laude\.ai/code/[0-9A-Za-z_]{6,})'

RULES=(em-dash curly-quote session-id-bare ai-trailer nbsp ellipsis en-dash)

declare -A RULE_RE=(
    [em-dash]="$RE_EMDASH"
    [curly-quote]="$RE_CURLYQ"
    [session-id-bare]="$RE_SESSIONBARE"
    [ai-trailer]="$RE_AITRAILER"
    [nbsp]="$RE_NBSP"
    [ellipsis]="$RE_ELLIPSIS"
    [en-dash]="$RE_ENDASH"
)

# Tier binds to consequence, and BLOCK stays small. The four blocking
# rules are the ones whose correct response is "stop and rewrite before
# posting", because posting is the irreversible step: an edit afterwards
# leaves visible edit history and does not remove the fingerprint. The
# advisory three are invisible in a diff and worth telling a reviewer
# about, but none alone is worth halting a post a human is standing over.
declare -A RULE_TIER=(
    [em-dash]=BLOCK
    [curly-quote]=BLOCK
    [session-id-bare]=BLOCK
    [ai-trailer]=BLOCK
    [nbsp]=ADVISORY
    [ellipsis]=ADVISORY
    [en-dash]=ADVISORY
)

declare -A RULE_FIX=(
    [em-dash]='rewrite the clause. Never auto-fixed: choosing between a comma, a colon, a parenthesis and a reworded sentence is the taste call this rule exists to route to a human, and a mechanical substitution reads as machine-edited prose.'
    [curly-quote]='replace with the ASCII quote or apostrophe. Usually arrives by paste from a rendered document rather than by typing.'
    [session-id-bare]='remove the session identifier or replace it with a placeholder -- it names a live session in the operator tree.'
    [ai-trailer]='remove the trailer or URL. It belongs in local commit history, not in text posted to another project.'
    [nbsp]='replace with an ordinary space. Invisible in review and in a diff; survives copy-paste into the target.'
    [ellipsis]='replace with three ASCII periods.'
    [en-dash]='advisory only -- an en dash flanked by spaces is standing in for an em dash. Between digits it is a numeric range and is not reported.'
)

# render_match <rule> <match> -- what to print in the match column.
# The typographic rules match characters that are invisible or
# indistinguishable from their ASCII cousins in a terminal, so printing
# the raw byte tells an operator nothing about what to look for.
render_match() {
    case "$2" in
        $'\xE2\x80\x94') printf 'U+2014 EM DASH' ;;
        $'\xE2\x80\x93') printf 'U+2013 EN DASH (space-flanked)' ;;
        $'\xE2\x80\x98') printf 'U+2018 LEFT SINGLE QUOTE' ;;
        $'\xE2\x80\x99') printf 'U+2019 RIGHT SINGLE QUOTE / APOSTROPHE' ;;
        $'\xE2\x80\x9C') printf 'U+201C LEFT DOUBLE QUOTE' ;;
        $'\xE2\x80\x9D') printf 'U+201D RIGHT DOUBLE QUOTE' ;;
        $'\xC2\xA0')     printf 'U+00A0 NO-BREAK SPACE' ;;
        $'\xE2\x80\xAF') printf 'U+202F NARROW NO-BREAK SPACE' ;;
        $'\xE2\x80\xA6') printf 'U+2026 HORIZONTAL ELLIPSIS' ;;
        *)               printf '%s' "$2" ;;
    esac
}

# =========================================================================
# CALIBRATION CONTROLS
#
# ASSEMBLED FROM FRAGMENTS, NEVER WRITTEN OUT. This file is tracked in a
# PUBLIC repository, and its own test suite points the tool at a copy of
# it. A literal session id or a literal assistant trailer here would make
# the scrubber a specimen of the class it hunts and would report itself on
# every run. The typographic plants are the one exception that cannot be
# fragmented -- they ARE single characters -- so they are written as \x
# escapes, which keeps the source bytes ASCII.
# =========================================================================

PLANTS=()          # "<rule>\t<literal the rule must match>"
BAITS=()           # lines that must produce NO finding at all

init_controls() {
    local co='Co-Authored-By' asst='C''laude'
    local hexa='a1b2c3d4e5f6' hexb='0718293a4b'

    PLANTS=(
        "em-dash"$'\t'"the fix is simple "$'\xE2\x80\x94'" it warns once"
        "curly-quote"$'\t'"it returns "$'\xE2\x80\x9C'"content"$'\xE2\x80\x9D'" unchanged"
        "session-id-bare"$'\t'"dispatched by session ${hexa}${hexb} today"
        "ai-trailer"$'\t'"${co}: ${asst} <noreply@example.invalid>"
        "nbsp"$'\t'"the proxy logs"$'\xC2\xA0'"now say what happened"
        "ellipsis"$'\t'"it warns once"$'\xE2\x80\xA6'"and then stays quiet"
        "en-dash"$'\t'"the fix is simple "$'\xE2\x80\x93'" it warns once"
    )

    # Every bait is an ASCII construction a legitimate draft is SUPPOSED to
    # use, or a hex run a real PR body is full of. The last two are drawn
    # from the staged LiteLLM package itself: its subject matter is chat
    # role markers, so a tool that fired on those would be unusable on the
    # very corpus it was built for.
    BAITS=(
        "the fix is simple - it warns once, and costs nothing"
        "a range of 10--20 and a flag --staged and a bullet -- like this"
        'it returns "content" unchanged and the model'"'"'s template stays'
        "it warns once... and then stays quiet"
        "supported on versions 10"$'\xE2\x80\x93'"20 of the proxy"
        "upstream sha 6efe32c9e2dd002d0c394e861e0529675d1ab32e is the merge base"
        "before (6efe32c) and after (d10c2333be)"
        "the request id was 550e8400e29b41d4a716446655440000"
        "${co}: Marcus <someone@example.invalid>"
        "the proxy logs now say what happened and what to change"
        'role markers like ### System: and ### User: are echoed back'
        "read the session_id field from the mode file"
    )
}

# =========================================================================
# SCAN PRIMITIVE
#
# ONE code path. Calibration and the real sweep both go through
# scan_text_file, which is the only way a positive control proves anything
# about the sweep: a harness that never really runs its subject reports
# fiction.
#
# Emits, per finding: <rule>\t<display>:<line>:<col>\t<match>
# `col` is a byte offset within the line, 1-based.
# =========================================================================

scan_one_line() {
    local rule="$1" line="$2" disp="$3" lineno="$4" off m
    while IFS=: read -r off m; do
        [ -n "$off" ] || continue
        printf '%s\t%s:%s:%s\t%s\n' "$rule" "$disp" "$lineno" "$((off + 1))" "$m"
    done < <(printf '%s' "$line" | LC_ALL=C grep -boP "${RULE_RE[$rule]}" 2>/dev/null)
}

scan_text_file() {
    local f="$1" disp="$2" rule n line
    for rule in "${RULES[@]}"; do
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            line=$(sed -n "${n}p" "$f")
            scan_one_line "$rule" "$line" "$disp" "$n"
        done < <(LC_ALL=C grep -nP "${RULE_RE[$rule]}" "$f" 2>/dev/null | cut -d: -f1)
    done
}

# =========================================================================
# CALIBRATION
# =========================================================================

CAL_LINE=""
CAL_DETAIL=()

run_calibration() {
    local d out rec rule lit caught=0 total=0 missed=() nfp=0 fp=()
    init_controls
    d=$(mktemp -d) || return 2

    : > "$d/plants.txt"
    for rec in "${PLANTS[@]}"; do
        printf '%s\n' "${rec#*$'\t'}" >> "$d/plants.txt"
    done
    printf '%s\n' "${BAITS[@]}" > "$d/baits.txt"

    out=$(scan_text_file "$d/plants.txt" "calibration-plants")
    for rec in "${PLANTS[@]}"; do
        rule="${rec%%$'\t'*}"; lit="${rec#*$'\t'}"
        total=$((total + 1))
        if printf '%s\n' "$out" | awk -F'\t' -v r="$rule" \
                '$1 == r { found = 1 } END { exit found ? 0 : 1 }'; then
            caught=$((caught + 1))
        else
            missed+=("$rule ($lit)")
        fi
    done

    out=$(scan_text_file "$d/baits.txt" "calibration-baits")
    if [ -n "$out" ]; then
        while IFS=$'\t' read -r rule _ lit; do
            [ -n "$rule" ] || continue
            nfp=$((nfp + 1))
            fp+=("$rule matched '$(render_match "$rule" "$lit")'")
        done <<< "$out"
    fi

    rm -rf "$d"

    CAL_DETAIL=()
    if [ "$caught" -eq "$total" ] && [ "$nfp" -eq 0 ]; then
        CAL_LINE="calibration: $caught/$total plants caught across ${#RULES[@]} rules; negative control $nfp hits over ${#BAITS[@]} baits -- PASS"
        return 0
    fi
    CAL_LINE="calibration: $caught/$total plants caught across ${#RULES[@]} rules; negative control $nfp hits over ${#BAITS[@]} baits -- FAIL"
    for rec in "${missed[@]+"${missed[@]}"}"; do CAL_DETAIL+=("  missed plant: $rec"); done
    for rec in "${fp[@]+"${fp[@]}"}";     do CAL_DETAIL+=("  negative control false positive: $rec"); done
    return 1
}

# =========================================================================
# USAGE
# =========================================================================

usage() {
    cat <<USAGE
cc-scrub-outbound $CC_SCRUB_OUTBOUND_VERSION -- outbound-text arm (register + delegated F1)

usage: cc-scrub-outbound.sh [options] <path>...

  <path>   an outbound package directory, or individual outbound text
           files. A directory is swept whole and its packages are checked
           for completeness; explicit files are swept exactly as handed
           over.

options:
  --calibrate-only    prove the instrument, sweep nothing
  --report <file>     write a tab-separated report for a reviewing session
  -h, --help          this text

exit codes:
  0  calibration passed, no blocking findings
  1  blocking findings -- do not post
  2  INCOMPLETE -- calibration failed here or in the F1 arm, the corpus
     could not be fully swept, or a package has no body to sweep. An
     instrument that cannot prove it works must not say CLEAN.
  3  usage error

rules (this arm):
  em-dash          BLOCK      U+2014
  curly-quote      BLOCK      U+2018 U+2019 U+201C U+201D
  session-id-bare  BLOCK      a bare 22-hex session identifier
  ai-trailer       BLOCK      an assistant co-author trailer or session URL
  nbsp             ADVISORY   U+00A0 U+202F
  ellipsis         ADVISORY   U+2026
  en-dash          ADVISORY   U+2013 flanked by spaces, standing in for an em dash

The F1 disclosure rules (rfc1918-host, home-path, session-id,
homelab-host) are not restated here: they are delegated to cc-scrub.sh so
that those four range-checked patterns keep living in exactly one file.

Findings are never auto-fixed; there is no --fix.
USAGE
}

die_usage() {
    printf 'cc-scrub-outbound: %s\n\n' "$1" >&2
    usage >&2
    exit 3
}

# =========================================================================
# ARGUMENTS
# =========================================================================

CALIBRATE_ONLY=0
REPORT=""
INPUTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --calibrate-only) CALIBRATE_ONLY=1 ;;
        --report)         shift; [ $# -gt 0 ] || die_usage "--report needs a file"; REPORT="$1" ;;
        # Choosing between a comma, a colon, a parenthesis and a rewrite is
        # the taste call the em-dash rule exists to route to a human.
        --fix|--rule)     die_usage "--fix is not available: findings here are never auto-fixed" ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die_usage "unknown option: $1" ;;
        *)                INPUTS+=("$1") ;;
    esac
    shift
done

# =========================================================================
# THE INSTRUMENT MUST BE ABLE TO RUN AT ALL
# =========================================================================

if ! printf 'x' | grep -qP 'x' 2>/dev/null; then
    printf 'cc-scrub-outbound %s -- outbound-text arm\n' "$CC_SCRUB_OUTBOUND_VERSION"
    printf 'VERDICT: INCOMPLETE -- grep has no -P (PCRE) support, so every rule would silently match nothing.\n'
    exit 2
fi

WORKDIR=$(mktemp -d) || exit 2
trap 'rm -rf "$WORKDIR"' EXIT

printf 'cc-scrub-outbound %s -- outbound-text arm (register + delegated F1)\n' \
    "$CC_SCRUB_OUTBOUND_VERSION"

# =========================================================================
# CALIBRATE FIRST, ALWAYS
# =========================================================================

if ! run_calibration; then
    printf '%s\n' "$CAL_LINE"
    printf '%s\n' "${CAL_DETAIL[@]+"${CAL_DETAIL[@]}"}"
    printf 'VERDICT: INCOMPLETE -- calibration failed; refusing to sweep or to report a verdict.\n'
    exit 2
fi

if [ "$CALIBRATE_ONLY" -eq 1 ]; then
    printf '%s\n' "$CAL_LINE"
    printf 'VERDICT: CALIBRATED -- instrument proven; no corpus swept.\n'
    exit 0
fi

[ "${#INPUTS[@]}" -gt 0 ] || die_usage "no paths given; name an outbound package directory or its files"

# =========================================================================
# THE F1 ARM
#
# Located beside this script, or beside its symlink target. A missing or
# uncalibrated delegate is NOT a clean F1 sweep -- that is the false zero
# one process removed, where an empty finding list from a tool that never
# ran reads as "no disclosures found".
# =========================================================================

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F1_SCRUB=""
for cand in \
    "$SELF_DIR/cc-scrub.sh" \
    "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null)/cc-scrub.sh"
do
    if [ -f "$cand" ]; then F1_SCRUB="$cand"; break; fi
done

if [ -z "$F1_SCRUB" ]; then
    printf '%s\n' "$CAL_LINE"
    printf 'VERDICT: INCOMPLETE -- the F1 arm (cc-scrub.sh) was not found beside this script; the disclosure class was not swept at all.\n'
    exit 2
fi

# =========================================================================
# CORPUS ASSEMBLY
#
# `file --mime-encoding` and NOT --mime-type: --mime-type calls a markdown
# file in this very repo application/javascript, and a text filter built
# on it would silently skip a PR body.
#
# Files are staged into a flat numbered tree so the delegate can be handed
# one directory regardless of how the inputs were named, and so its
# findings map back to the paths the operator recognises.
# =========================================================================

SWEPT=0; BINARY=0; UNSWEPT=0
UNSWEPT_LIST=()
DISPLAY=()          # index -> display name shown to the operator
SOURCE=()           # index -> real path
declare -A PKG_BODY=() PKG_PART=()
GROUPED=0           # 1 once any directory input contributed a file

STAGE="$WORKDIR/stage"
mkdir -p "$STAGE"

# note_package <display> -- record the outbound package this file belongs
# to. Stems come from the three staged suffixes; anything else in the
# directory is still swept, it just does not form a package.
note_package() {
    local d="$1" stem=""
    case "$d" in
        *.body.md) stem="${d%.body.md}"; PKG_BODY[$stem]=1 ;;
        *.title)   stem="${d%.title}" ;;
        *.target)  stem="${d%.target}" ;;
        *)         return 0 ;;
    esac
    PKG_PART[$stem]=1
}

collect_file() {   # <real-path> <display> <grouped:0|1>
    local f="$1" disp="$2" grouped="$3" enc idx
    if [ ! -r "$f" ]; then
        UNSWEPT=$((UNSWEPT + 1)); UNSWEPT_LIST+=("$disp (not readable)")
        return 0
    fi
    enc=$(file -b --mime-encoding -- "$f" 2>/dev/null)
    case "$enc" in
        binary)
            BINARY=$((BINARY + 1))
            return 0 ;;
        ''|*[!A-Za-z0-9._-]*)
            UNSWEPT=$((UNSWEPT + 1))
            UNSWEPT_LIST+=("$disp (file could not classify it: ${enc:-no answer})")
            return 0 ;;
    esac
    idx="${#DISPLAY[@]}"
    mkdir -p "$STAGE/$idx"
    if ! cp -- "$f" "$STAGE/$idx/$(basename -- "$f")" 2>/dev/null; then
        UNSWEPT=$((UNSWEPT + 1)); UNSWEPT_LIST+=("$disp (could not be staged for the F1 arm)")
        return 0
    fi
    DISPLAY+=("$disp")
    SOURCE+=("$f")
    SWEPT=$((SWEPT + 1))
    [ "$grouped" -eq 1 ] && { GROUPED=1; note_package "$disp"; }
    return 0
}

for p in "${INPUTS[@]}"; do
    if [ -d "$p" ]; then
        base=$(cd "$p" && pwd) || die_usage "cannot enter directory: $p"
        while IFS= read -r -d '' f; do
            collect_file "$f" "${f#"$base"/}" 1
        done < <(find "$base" -type f -print0 2>/dev/null | sort -z)
    elif [ -f "$p" ]; then
        collect_file "$p" "$p" 0
    else
        die_usage "not a file or directory: $p"
    fi
done

# =========================================================================
# PACKAGE COMPLETENESS
#
# The false zero specific to THIS surface: the operator sweeps the
# outbound folder, it reports CLEAN, and the body that actually gets
# posted was never in the folder. A stem carrying a .title or a .target
# but no .body.md is exactly that state. A body with no target is not --
# that is a comment draft, and a target is not posted text.
#
# The gate applies to directory inputs only. An explicit file list is the
# operator naming what they want swept, and completeness is their call.
# =========================================================================

MISSING_BODY=()
if [ "$GROUPED" -eq 1 ]; then
    for stem in "${!PKG_PART[@]}"; do
        [ -n "${PKG_BODY[$stem]+set}" ] || MISSING_BODY+=("$stem")
    done
fi

# =========================================================================
# SWEEP -- this arm's rules, then the delegated F1 class
# =========================================================================

FINDINGS=()
BLOCKING=0
ADVISORY=0

record() {   # <tier> <rule> <location> <match> <fix>
    if [ "$1" = "BLOCK" ]; then BLOCKING=$((BLOCKING + 1)); else ADVISORY=$((ADVISORY + 1)); fi
    FINDINGS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"UNPUBLISHED"$'\t'"$4"$'\t'"$5")
}

i=0
while [ "$i" -lt "${#DISPLAY[@]}" ]; do
    while IFS=$'\t' read -r rule loc m; do
        [ -n "$rule" ] || continue
        record "${RULE_TIER[$rule]}" "$rule" "$loc" "$(render_match "$rule" "$m")" "${RULE_FIX[$rule]}"
    done < <(scan_text_file "${SOURCE[$i]}" "${DISPLAY[$i]}")
    i=$((i + 1))
done

F1_CAL=""
F1_INCOMPLETE=""
if [ "$SWEPT" -gt 0 ]; then
    F1_TSV="$WORKDIR/f1.tsv"
    F1_OUT=$(bash "$F1_SCRUB" --path "$STAGE" --report "$F1_TSV" 2>&1)
    F1_RC=$?
    F1_CAL=$(printf '%s\n' "$F1_OUT" | grep -m1 '^calibration:')
    if [ "$F1_RC" -eq 2 ]; then
        F1_INCOMPLETE=$(printf '%s\n' "$F1_OUT" | grep -m1 '^VERDICT: INCOMPLETE')
        [ -n "$F1_INCOMPLETE" ] || F1_INCOMPLETE="VERDICT: INCOMPLETE -- the F1 arm exited 2 without a verdict line."
    elif [ -s "$F1_TSV" ]; then
        # The delegate's columns are: tier rule location classification
        # match note fix. THE NOTE IS USUALLY EMPTY, and that is a trap:
        # `read` with IFS=$'\t' collapses a RUN of tabs into a single
        # delimiter, because tab is IFS whitespace. An empty note therefore
        # shifts every later column one to the left and the fix arrives
        # blank -- the operator is told to stop without being told what to
        # do. awk does not collapse, so the fields are selected there and
        # only non-empty values are handed to `read`.
        #
        # The location's leading path segment is the stage index, which is
        # how a delegate finding is mapped back to the operator's own path.
        while IFS=$'\t' read -r f1tier f1rule f1loc f1match f1fix; do
            case "$f1tier" in ''|'#'*|tier) continue ;; esac
            idx="${f1loc%%/*}"
            rest="${f1loc#*/}"
            case "$idx" in
                ''|*[!0-9]*) : ;;
                *) [ -n "${DISPLAY[$idx]+set}" ] && f1loc="${DISPLAY[$idx]}:${rest#*:}" ;;
            esac
            record "$f1tier" "$f1rule" "$f1loc" "$f1match" "$f1fix"
        done < <(awk -F'\t' '
            /^#/     { next }
            $1 == "tier" { next }
            NF >= 7  { printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $5, ($7 == "" ? "(no fix text from the F1 arm)" : $7) }
        ' "$F1_TSV")
    fi
fi

# =========================================================================
# REPORT
# =========================================================================

printf '%s\n' "$CAL_LINE"
[ -n "$F1_CAL" ] && printf 'f1 %s\n' "$F1_CAL"
printf 'mode: outbound text\n'
# Abbreviated against $HOME, not printed raw. This report is itself
# pasted into review threads and task write-ups, which makes it an
# outbound surface; a scrubber that published the operator's home
# directory while reporting CLEAN would be a specimen of its own
# home-path rule.
printf 'f1 arm: %s\n' "${F1_SCRUB/#$HOME/\~}"
printf 'baseline: (none) -- outbound text has not been published, so every finding is unpublished by construction\n'
if [ "$GROUPED" -eq 1 ]; then
    printf 'packages: %d (%s)\n' "${#PKG_PART[@]}" "$(printf '%s ' "${!PKG_PART[@]}" | sed 's/ $//')"
else
    printf 'packages: not grouped (explicit file list)\n'
fi
printf 'corpus: %d swept, %d binary-skipped, %d unswept\n' "$SWEPT" "$BINARY" "$UNSWEPT"
for u in ${UNSWEPT_LIST[@]+"${UNSWEPT_LIST[@]}"}; do
    printf '  UNSWEPT: %s\n' "$u"
done
for s in ${MISSING_BODY[@]+"${MISSING_BODY[@]}"}; do
    printf '  NO BODY: package %s has a title or a target but no .body.md to sweep\n' "$s"
done

for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    IFS=$'\t' read -r tier rule loc cls m fix <<< "$f"
    printf '%-8s %-16s %s  %s  %s\n' "$tier" "$rule" "$loc" "$cls" "$m"
    printf '         fix: %s\n' "$fix"
done

printf 'findings: %d blocking, %d advisory\n' "$BLOCKING" "$ADVISORY"

if [ -n "$REPORT" ]; then
    {
        printf '# cc-scrub-outbound %s report -- outbound-text arm\n' "$CC_SCRUB_OUTBOUND_VERSION"
        printf '# corpus\t%d swept\t%d binary-skipped\t%d unswept\n' "$SWEPT" "$BINARY" "$UNSWEPT"
        printf 'tier\trule\tlocation\tclassification\tmatch\tfix\n'
        for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
            printf '%s\n' "$f"
        done
    } > "$REPORT"
fi

# =========================================================================
# VERDICT
#
# Precedence: an untrustworthy instrument outranks a finding. A CLEAN or
# BLOCK verdict over a corpus that was not fully swept is not a verdict.
# =========================================================================

if [ -n "$F1_INCOMPLETE" ]; then
    printf '%s\n' "$F1_INCOMPLETE"
    printf 'VERDICT: INCOMPLETE -- the F1 arm did not complete, so the disclosure class is unmeasured here.\n'
    exit 2
fi

if [ "$SWEPT" -eq 0 ]; then
    printf 'VERDICT: INCOMPLETE -- the corpus is empty; a sweep that swept nothing cannot report CLEAN.\n'
    exit 2
fi

if [ "$UNSWEPT" -gt 0 ]; then
    printf 'VERDICT: INCOMPLETE -- %d file(s) could not be swept; "unmeasured" is not "clean".\n' "$UNSWEPT"
    exit 2
fi

if [ "${#MISSING_BODY[@]}" -gt 0 ]; then
    printf 'VERDICT: INCOMPLETE -- %d package(s) have no .body.md; the text that gets posted was not swept.\n' \
        "${#MISSING_BODY[@]}"
    exit 2
fi

cat <<'LIMITS'
LIMITS: this is a lower bound over mechanical tells -- a codepoint is
  present or it is not. NOT covered: lexical AI-isms, meaning register
  vocabulary and sentence-shape tells, which have no measured precision
  here and would be a taste call in code; F2 provenance and AI-thread
  vocabulary, excluded permanently because that pattern set is itself a
  disclosure and stays in the private sweep; prose quoted from private
  artifacts; and anything in an attached image. Those need a reviewing
  session, not a regex.
LIMITS

if [ "$BLOCKING" -gt 0 ]; then
    printf 'VERDICT: BLOCK -- %d blocking finding(s). Do not post; an edit after posting leaves visible history.\n' "$BLOCKING"
    exit 1
fi
printf 'VERDICT: CLEAN -- no register or disclosure pattern matched over the swept corpus.\n'
exit 0
