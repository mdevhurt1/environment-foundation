#!/usr/bin/env bash
# Description: cc-scrub F1 arm — scans a diff (or a tree) for disclosure/topology tells before they reach a public remote: RFC1918 host literals, absolute home paths, session identifiers, and internal hostnames. Calibrates itself on planted controls first and refuses to report CLEAN unless it just proved every enabled rule fires.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, grep with -P (PCRE), file, coreutils
#
# WHY THIS EXISTS (Plane RESEARCH-1; spec sections 3.7, 2.1, 7)
#
#   On 2026-09-03 a commit bound for a PUBLIC GitHub remote carried the live
#   LAN address of the company's Plane server. An Opus session found it by
#   reading 1,283 added lines across 15 files. One range-checked regex would
#   have found it and NOTHING ELSE in the entire repository -- precision 1.00
#   and recall 1.00 on the only incident of this class the company has. That
#   rule did not exist. This is that rule, plus the three others measured
#   beside it.
#
#   The tool is deliberately NOT a register or provenance scrubber:
#
#     * F2 (provenance / AI-thread vocabulary) is excluded permanently. Its
#       pattern set IS the disclosure it hunts, so publishing it here would
#       inject that vocabulary into a public repo. It stays in the private
#       sweep. Excluding F2 is the reason this script can live in a public
#       repo at all.
#     * F3 (register / typography / trailers) is not implemented yet: it is
#       gated on two undecided policy questions (the Co-Authored-By trailer
#       conflict with the harness, and whether the em-dash is an AI marker or
#       house style). Shipping it early would block 81% of this repo's text
#       files on a taste call.
#
# WHY IT CALIBRATES BEFORE IT SWEEPS (spec sections 1 and 7.3)
#
#   Two instruments printed a clean bill of health over real disclosures in a
#   single evening: an OCR arm that had never been calibrated, and a corpus
#   classifier that matched 1 file of 185 because `file` right-pads its output
#   and the idiomatic `-F': '` split silently returned almost nothing. An
#   uncalibrated scrubber is WORSE than no scrubber, because it converts
#   "unmeasured" into "verified clean". So every run plants one positive
#   control per enabled rule, sweeps them through the same code path the real
#   corpus takes, and refuses to report CLEAN unless all of them were caught
#   and a negative control of documented false-positive baits stayed silent.
#   Every failure mode exits differently on purpose.
#
# WHY IT DIFFS INSTEAD OF SCANNING (spec section 2.1)
#
#   Run absolutely, a scrubber reports the same already-published values on
#   every invocation and is muted within a week. Every finding is therefore
#   classified NEW or BASELINE against a declared baseline ref, and only a NEW
#   hit in a BLOCK-tier rule blocks. That is the distinction seven push-review
#   verdicts actually turned on. Classification reads the baseline's own tree
#   and message history -- it is never inferred from an ahead-count, which
#   describes a branch tip's distance and says nothing about when a blob
#   entered history.

set -uo pipefail   # Reporter, NOT -e: every rule must run and report. An
                   # early abort would hide the second finding, which is the
                   # opposite of this script's job.

CC_SCRUB_VERSION="1.0"

# =========================================================================
# RULES
#
# Each pattern is a PCRE on a single line so it can be mutated by the test
# suite: breaking one detector must make calibration fail loudly, and that is
# only provable if a test can reach in and break exactly one.
#
# The RFC1918 pattern is FULLY RANGE-CHECKED on all four octets and that is
# not fastidiousness. The naive form -- \b(10|192\.168|172\.(1[6-9]|2[0-9]|
# 3[01]))\.[0-9.]+\b -- returns 11 distinct "literals" on the company's
# hardware repo: 10.0, 10.5, 10.6, 10.16, 10.033, 10.287. Every one is a
# decimal measurement. That is a documented bait, not a hypothetical, and it
# sits in the negative control below.
# =========================================================================

RE_RFC1918='(?<![0-9.])(?:10(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}|172\.(?:1[6-9]|2[0-9]|3[01])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){2}|192\.168(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){2})(?![0-9.])'
RE_HOMEPATH='(?<![A-Za-z0-9_])/home/[a-z_][a-z0-9_.-]*'
RE_SESSION='(?<!claude\.ai/code/)session_[0-9A-Za-z]{10,}'
RE_HOMELAB='(?<![A-Za-z0-9.-])[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.homelab(?![A-Za-z0-9-])'

RULES=(rfc1918-host home-path session-id homelab-host)

declare -A RULE_RE=(
    [rfc1918-host]="$RE_RFC1918"
    [home-path]="$RE_HOMEPATH"
    [session-id]="$RE_SESSION"
    [homelab-host]="$RE_HOMELAB"
)

# Tier binds to the rule's MEASURED precision, not to the integration point.
# BLOCK is deliberately tiny: a blocking rule in an autonomous session with
# nobody watching the pane must be one where the correct response is "stop and
# escalate", never "try something else".
declare -A RULE_TIER=(
    [rfc1918-host]=BLOCK
    [home-path]=BLOCK
    [session-id]=BLOCK
    [homelab-host]=ADVISORY
)

declare -A RULE_FIX=(
    [rfc1918-host]='replace the literal with the service hostname -- an address in a public artifact publishes internal topology (service -> address -> port). Never auto-fixed: the substitution is a semantic change a human must make.'
    [home-path]='use $HOME or ~ instead of an absolute path naming the operator account.'
    [session-id]='remove the session identifier or replace it with a placeholder.'
    [homelab-host]='advisory only -- an internal hostname. Already-public instances are informational; a genuinely new one is worth a look.'
)

# rule_accepts <rule> <match> -- the post-match range checks a regex cannot
# express. Network and broadcast addresses are ranges and masks, not hosts:
# the public baseline's only dotted quad is a no_proxy CIDR ending .0.0, and
# it must never become a finding.
rule_accepts() {
    local rule="$1" m="$2"
    case "$rule" in
        rfc1918-host)
            case "$m" in
                *.0|*.255) return 1 ;;
            esac
            ;;
    esac
    return 0
}

# =========================================================================
# CALIBRATION CONTROLS
#
# ASSEMBLED FROM FRAGMENTS, NEVER WRITTEN OUT. This file is tracked in a
# PUBLIC repository and is itself part of the corpus `--audit` sweeps. A
# literal dotted quad, a literal absolute home path, or a bare session token
# written here would (a) be reported by every audit of this repo forever and
# (b) make the scrubber a specimen of the disclosure class it exists to
# catch -- the same reasoning that keeps the F2 pattern set out of this repo.
# None of the fragments below matches any rule on its own.
# =========================================================================

PLANTS=()          # "<rule>\t<literal the rule must match>"
BAITS=()           # lines that must produce NO finding at all

init_controls() {
    local q192='192.168' q10='10' q172='172.16' seg='home' hl='homelab'
    local tok='Ab3Cd5Ef7Gh9Jk' tok2='Zy9Xw7Vu5Ts3Rq'

    PLANTS=(
        "rfc1918-host"$'\t'"${q192}.44.44"
        "rfc1918-host"$'\t'"${q10}.99.99.99"
        "rfc1918-host"$'\t'"${q172}.30.40"
        "home-path"$'\t'"/${seg}/plantuser"
        "session-id"$'\t'"session_${tok}"
        "homelab-host"$'\t'"fixture.${hl}"
    )

    # Every bait below is drawn from a real corpus or a real review verdict.
    BAITS=(
        "tolerance 10.033 mm and span 10.287"
        "ratio 10.0, 10.5, 10.6 and step 10.16"
        "no_proxy includes ${q192}.0.0/16 so the sandbox can reach it"
        "${q10}.0.0.0/8 is a range, not a host"
        "listen 127.0.0.1 and bind 0.0.0.0"
        "netmask 255.255.255.0"
        "172.15.0.1 and 172.32.0.1 sit outside the ${q172}/12 block"
        "resolver 8.8.8.8 and peer 1.2.3.4 are public"
        "version 10.1.2 and build 1.10.0.0.4"
        'config lives in $HOME/vault and ~/.claude'
        "installed under /${seg}brew/bin"
        "/${seg} is a mountpoint"
        "read the session_id field from the mode file"
        "upstream sha 6efe32c9e2dd002d0c394e861e0529675d1ab32e"
        "Claude-Session: https://claude.ai/code/session_${tok2}"
        "the ${hl} runs on a single node"
        'std::reference_wrapper<T> is not a role word'
        "comprehensive test coverage and robust handling"
        "Review it and let me know if you want changes"
    )
}

# =========================================================================
# SCAN PRIMITIVE
#
# ONE code path. Calibration and the real sweep both go through
# scan_text_file, which is the only way a positive control can prove anything
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
        rule_accepts "$rule" "$m" || continue
        printf '%s\t%s:%s:%s\t%s\n' "$rule" "$disp" "$lineno" "$((off + 1))" "$m"
    done < <(printf '%s' "$line" | grep -boP "${RULE_RE[$rule]}" 2>/dev/null)
}

# scan_text_file <file> <display-name> <linemap|"">
# <linemap>, when given, holds the REAL line number for each line of <file>;
# diff modes scan only added lines but must report their position in the file
# as it will be published.
scan_text_file() {
    local f="$1" disp="$2" map="$3" rule n line lineno
    for rule in "${RULES[@]}"; do
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            line=$(sed -n "${n}p" "$f")
            if [ -n "$map" ]; then lineno=$(sed -n "${n}p" "$map"); else lineno="$n"; fi
            scan_one_line "$rule" "$line" "$disp" "$lineno"
        done < <(grep -nP "${RULE_RE[$rule]}" "$f" 2>/dev/null | cut -d: -f1)
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

    out=$(scan_text_file "$d/plants.txt" "calibration-plants" "")
    for rec in "${PLANTS[@]}"; do
        rule="${rec%%$'\t'*}"; lit="${rec#*$'\t'}"
        total=$((total + 1))
        if printf '%s\n' "$out" | grep -qF -- "$(printf '%s\t' "$rule")" \
           && printf '%s\n' "$out" | awk -F'\t' -v r="$rule" -v l="$lit" \
                '$1 == r && $3 == l { found = 1 } END { exit found ? 0 : 1 }'; then
            caught=$((caught + 1))
        else
            missed+=("$rule ($lit)")
        fi
    done

    out=$(scan_text_file "$d/baits.txt" "calibration-baits" "")
    if [ -n "$out" ]; then
        while IFS=$'\t' read -r rule _ lit; do
            [ -n "$rule" ] || continue
            nfp=$((nfp + 1))
            fp+=("$rule matched '$lit'")
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
# BASELINE CLASSIFICATION (spec section 2.1)
# =========================================================================

BASELINE_REF=""
BASELINE_MSGS=""
declare -A CLASS_FILE_CACHE=()
declare -A CLASS_MSG_CACHE=()

CLASS_RESULT=""
CLASS_NOTE=""

in_baseline_files() {
    local lit="$1"
    if [ -z "${CLASS_FILE_CACHE[$lit]+set}" ]; then
        if git grep -F -q -e "$lit" "$BASELINE_REF" -- ':/' 2>/dev/null; then
            CLASS_FILE_CACHE[$lit]=yes
        else
            CLASS_FILE_CACHE[$lit]=no
        fi
    fi
    [ "${CLASS_FILE_CACHE[$lit]}" = yes ]
}

in_baseline_messages() {
    local lit="$1"
    [ -n "$BASELINE_MSGS" ] || return 1
    if [ -z "${CLASS_MSG_CACHE[$lit]+set}" ]; then
        if grep -F -q -e "$lit" "$BASELINE_MSGS" 2>/dev/null; then
            CLASS_MSG_CACHE[$lit]=yes
        else
            CLASS_MSG_CACHE[$lit]=no
        fi
    fi
    [ "${CLASS_MSG_CACHE[$lit]}" = yes ]
}

# classify_literal <literal> <channel:file|message> -- sets CLASS_RESULT and
# CLASS_NOTE.
#
# CLASSIFICATION IS CHANNEL-CONSISTENT, AND THAT IS LOAD-BEARING.
#
# "Already public" has to mean "already public in the channel this finding
# occupies". Measured on this repo: the live Plane address was removed from
# tracked files by an earlier scrub whose own commit message then quoted it
# four times, including once in the subject line. Classifying a FILE finding
# against message history would therefore have downgraded the exact literal
# that produced the company only BLOCK verdict -- a value can leak through
# one channel and still be a genuine new disclosure in another. A file is
# what readers browse, search engines index, and other repos copy.
#
# The reverse direction is not symmetric: a value already in the published
# tree is genuinely published, so a commit message repeating it adds nothing.
# A file-channel hit that is new to files but present in baseline messages is
# still reported as unpublished, with a note -- because the history is
# published too, and a reviewer should be told rather than have the collision
# swallowed.
classify_literal() {
    local lit="$1" channel="$2"
    CLASS_NOTE=""
    if [ -z "$BASELINE_REF" ]; then CLASS_RESULT="UNKNOWN"; return; fi
    if in_baseline_files "$lit"; then CLASS_RESULT="BASELINE"; return; fi
    if [ "$channel" = "message" ] && in_baseline_messages "$lit"; then
        CLASS_RESULT="BASELINE"; return
    fi
    CLASS_RESULT="NEW"
    if [ "$channel" = "file" ] && in_baseline_messages "$lit"; then
        CLASS_NOTE="absent from the baseline tree but present in its commit messages -- published history carries it too"
    fi
}

# =========================================================================
# USAGE
# =========================================================================

usage() {
    cat <<USAGE
cc-scrub $CC_SCRUB_VERSION -- F1 disclosure/topology arm

usage: cc-scrub.sh [mode] [options]

modes (at most one; the default is a diff against the baseline):
  (none)              diff <baseline>..HEAD, including commit messages
  --staged            staged changes only (pre-commit)
  --range A..B        an explicit range, including its commit messages
  --audit             ABSOLUTE scan of the whole tracked tree; not the default
  --path <dir>        scan a directory (pre-submission, operator-invoked)
  --calibrate-only    prove the instrument, sweep nothing

options:
  --baseline <ref>    baseline for NEW-vs-BASELINE classification
                      (default: origin/main, then main)
  --report <file>     write a tab-separated report for a reviewing session
  -h, --help          this text

exit codes:
  0  calibration passed, no blocking findings
  1  blocking findings (a NEW hit in a BLOCK-tier rule)
  2  INCOMPLETE -- calibration failed, or the corpus could not be fully
     swept. An instrument that cannot prove it works must not say CLEAN.
  3  usage error

rules:
  rfc1918-host   BLOCK      RFC1918 host literal, all four octets range-checked
  home-path      BLOCK      absolute path naming an operator account
  session-id     BLOCK      session identifier token
  homelab-host   ADVISORY   internal hostname

BLOCK-tier findings are never auto-fixed; there is no --fix in the F1 arm.
USAGE
}

die_usage() {
    printf 'cc-scrub: %s\n\n' "$1" >&2
    usage >&2
    exit 3
}

# =========================================================================
# ARGUMENTS
# =========================================================================

MODE=""
RANGE=""
SCAN_PATH=""
BASELINE_ARG=""
REPORT=""

set_mode() {
    [ -z "$MODE" ] || die_usage "modes are mutually exclusive: already in --$MODE, got --$1"
    MODE="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --staged)         set_mode staged ;;
        --audit)          set_mode audit ;;
        --calibrate-only) set_mode calibrate-only ;;
        --range)          set_mode range; shift; [ $# -gt 0 ] || die_usage "--range needs A..B"; RANGE="$1" ;;
        --path)           set_mode path;  shift; [ $# -gt 0 ] || die_usage "--path needs a directory"; SCAN_PATH="$1" ;;
        --baseline)       shift; [ $# -gt 0 ] || die_usage "--baseline needs a ref"; BASELINE_ARG="$1" ;;
        --report)         shift; [ $# -gt 0 ] || die_usage "--report needs a file"; REPORT="$1" ;;
        # The BLOCK tier is never auto-fixed: substituting a hostname for an
        # address is a semantic change a human must make, and a tool that
        # rewrote it would be guessing at meaning.
        --fix|--rule)     die_usage "--fix is not available in the F1 arm: BLOCK-tier findings are never auto-fixed" ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die_usage "unknown option: $1" ;;
        *)                die_usage "unexpected argument: $1" ;;
    esac
    shift
done
[ -n "$MODE" ] || MODE="diff"

# =========================================================================
# THE INSTRUMENT MUST BE ABLE TO RUN AT ALL
#
# Without PCRE every lookaround-bearing pattern fails and grep matches
# nothing -- which is indistinguishable from a clean corpus unless it is
# checked here. This is the same false-zero shape as the uncalibrated OCR arm.
# =========================================================================

if ! printf 'x' | grep -qP 'x' 2>/dev/null; then
    printf 'cc-scrub %s -- F1 disclosure/topology arm\n' "$CC_SCRUB_VERSION"
    printf 'VERDICT: INCOMPLETE -- grep has no -P (PCRE) support, so every rule would silently match nothing.\n'
    printf 'Install GNU grep with PCRE, or run cc-scrub where one is on PATH.\n'
    exit 2
fi

WORKDIR=$(mktemp -d) || exit 2
trap 'rm -rf "$WORKDIR"' EXIT

# =========================================================================
# CALIBRATE FIRST, ALWAYS
# =========================================================================

printf 'cc-scrub %s -- F1 disclosure/topology arm\n' "$CC_SCRUB_VERSION"

if ! run_calibration; then
    printf '%s\n' "$CAL_LINE"
    printf '%s\n' "${CAL_DETAIL[@]+"${CAL_DETAIL[@]}"}"
    printf 'VERDICT: INCOMPLETE -- calibration failed; refusing to sweep or to report a verdict.\n'
    exit 2
fi

if [ "$MODE" = "calibrate-only" ]; then
    printf '%s\n' "$CAL_LINE"
    printf 'VERDICT: CALIBRATED -- instrument proven; no corpus swept.\n'
    exit 0
fi

# =========================================================================
# BASELINE RESOLUTION
# =========================================================================

# EVERY GIT OPERATION RUNS FROM THE REPOSITORY ROOT.
#
# `git ls-files` and `git diff` are both cwd-relative. Invoked from a
# subdirectory -- which is exactly where a hook or a working session tends to
# be -- an unanchored --audit sweeps that subtree and then prints a
# whole-tree verdict over it. Measured on this repo: run from
# software/development/claude-code, the audit corpus fell from 187 files to
# 104 and said CLEAN. An unmeasured subset reported as a clean whole is the
# false-zero shape this tool exists to refuse, so the scope is anchored here
# and the root is printed. --path is how you deliberately scan one directory.
IN_REPO=0
REPO_TOP=""
if [ "$MODE" = "path" ]; then
    [ -d "$SCAN_PATH" ] || die_usage "not a directory: $SCAN_PATH"
    SCAN_PATH=$(cd "$SCAN_PATH" && pwd) || die_usage "cannot enter directory: $SCAN_PATH"
    REPO_TOP=$(cd "$SCAN_PATH" && git rev-parse --show-toplevel 2>/dev/null)
else
    REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null)
fi
if [ -n "$REPO_TOP" ] && cd "$REPO_TOP" 2>/dev/null; then
    IN_REPO=1
fi

resolve_ref() { git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1; }

if [ "$IN_REPO" -eq 1 ]; then
    if [ "$MODE" = "range" ]; then
        BASELINE_REF="${RANGE%%.*}"
        resolve_ref "$BASELINE_REF" || BASELINE_REF=""
    elif [ -n "$BASELINE_ARG" ]; then
        resolve_ref "$BASELINE_ARG" && BASELINE_REF="$BASELINE_ARG"
    else
        for cand in origin/main main; do
            if resolve_ref "$cand"; then BASELINE_REF="$cand"; break; fi
        done
    fi
fi

if [ -n "$BASELINE_REF" ]; then
    BASELINE_MSGS="$WORKDIR/baseline-messages.txt"
    git log --format=%B "$BASELINE_REF" > "$BASELINE_MSGS" 2>/dev/null || BASELINE_MSGS=""
fi

# =========================================================================
# CORPUS ASSEMBLY
#
# `file --mime-encoding` and NOT --mime-type: --mime-type calls a markdown
# file in this very repo application/javascript, and a text filter built on
# it would silently skip it. Encoding is read with `file -b` so the output
# never has to be split away from a filename -- `file` right-pads that column
# and the idiomatic `-F': '` split is what classified 1 file of 185 while the
# spec was being written, reporting zero of everything over an unmeasured tree.
# =========================================================================

SWEPT=0; BINARY=0; UNSWEPT=0
UNSWEPT_LIST=()
SCAN_JOBS=()          # "<file-to-scan>\t<display>\t<linemap|>"
MSG_COUNT=0
ADDED_LINES=0

classify_and_queue() {   # <real-path> <display>
    local f="$1" disp="$2" enc
    enc=$(file -b --mime-encoding -- "$f" 2>/dev/null)
    case "$enc" in
        binary)                 BINARY=$((BINARY + 1)) ;;
        ''|*[!A-Za-z0-9._-]*)   UNSWEPT=$((UNSWEPT + 1)); UNSWEPT_LIST+=("$disp (file could not classify it: ${enc:-no answer})") ;;
        *)                      SWEPT=$((SWEPT + 1)); SCAN_JOBS+=("$f"$'\t'"$disp"$'\t'"") ;;
    esac
}

# split_added_lines <git-diff-args...> -- materialise each changed file's
# ADDED lines plus a map back to their line numbers in the published file.
split_added_lines() {
    local n=0 cur="" f m
    while IFS=$'\t' read -r p ln txt; do
        [ -n "$p" ] || continue
        if [ "$p" != "$cur" ]; then
            n=$((n + 1)); cur="$p"
            printf '%s\n' "$p" > "$WORKDIR/d$n.name"
            : > "$WORKDIR/d$n.txt"; : > "$WORKDIR/d$n.map"
        fi
        printf '%s\n' "$txt" >> "$WORKDIR/d$n.txt"
        printf '%s\n' "$ln"  >> "$WORKDIR/d$n.map"
        ADDED_LINES=$((ADDED_LINES + 1))
    done < <(git diff -U0 "$@" -- ':/' 2>/dev/null | awk '
        /^\+\+\+ /   { p = substr($0, 7); if (p == "/dev/null") p = ""; next }
        /^@@ /       { if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
        /^\+/        { if (p != "") { printf "%s\t%d\t%s\n", p, n, substr($0, 2); n++ } }
    ')
    BINARY=$(git diff -U0 "$@" -- ':/' 2>/dev/null | grep -c '^Binary files ')
    local i
    for ((i = 1; i <= n; i++)); do
        f=$(cat "$WORKDIR/d$i.name")
        m="$WORKDIR/d$i.map"
        SWEPT=$((SWEPT + 1))
        SCAN_JOBS+=("$WORKDIR/d$i.txt"$'\t'"$f"$'\t'"$m")
    done
}

# queue_commit_messages <range> -- a range publishes its messages too; the
# 0904b review read all four of them by hand.
queue_commit_messages() {
    local sha i=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        i=$((i + 1))
        git log -1 --format=%B "$sha" > "$WORKDIR/m$i.txt" 2>/dev/null
        MSG_COUNT=$((MSG_COUNT + 1))
        SCAN_JOBS+=("$WORKDIR/m$i.txt"$'\t'"commit-message:${sha:0:7}"$'\t'"")
    done < <(git log --format=%H "$1" 2>/dev/null)
}

case "$MODE" in
    audit)
        [ "$IN_REPO" -eq 1 ] || die_usage "--audit needs a git repository"
        while IFS= read -r -d '' p; do
            classify_and_queue "$p" "$p"
        done < <(git ls-files -z)
        ;;
    path)
        while IFS= read -r -d '' p; do
            classify_and_queue "$p" "${p#"$SCAN_PATH"/}"
        done < <(find "$SCAN_PATH" -type f -print0 2>/dev/null | sort -z)
        ;;
    staged)
        [ "$IN_REPO" -eq 1 ] || die_usage "--staged needs a git repository"
        split_added_lines --cached
        ;;
    range)
        [ "$IN_REPO" -eq 1 ] || die_usage "--range needs a git repository"
        split_added_lines "$RANGE"
        queue_commit_messages "$RANGE"
        ;;
    diff)
        [ "$IN_REPO" -eq 1 ] || die_usage "the default diff mode needs a git repository"
        [ -n "$BASELINE_REF" ] || die_usage "no baseline ref resolved; pass --baseline <ref> or use --audit"
        split_added_lines "$BASELINE_REF..HEAD"
        queue_commit_messages "$BASELINE_REF..HEAD"
        ;;
esac

# =========================================================================
# SWEEP
# =========================================================================

FINDINGS=()
BLOCKING=0
ADVISORY=0

for job in ${SCAN_JOBS[@]+"${SCAN_JOBS[@]}"}; do
    IFS=$'\t' read -r jf jd jm <<< "$job"
    channel="file"
    case "$jd" in commit-message:*) channel="message" ;; esac
    while IFS=$'\t' read -r rule loc m; do
        [ -n "$rule" ] || continue
        classify_literal "$m" "$channel"
        tier="${RULE_TIER[$rule]}"
        if [ "$tier" = "BLOCK" ] && [ "$CLASS_RESULT" != "BASELINE" ]; then
            BLOCKING=$((BLOCKING + 1))
        else
            ADVISORY=$((ADVISORY + 1))
            [ "$tier" = "BLOCK" ] && tier="ADVISORY"
        fi
        FINDINGS+=("$tier"$'\t'"$rule"$'\t'"$loc"$'\t'"$CLASS_RESULT"$'\t'"$m"$'\t'"$CLASS_NOTE")
    done < <(scan_text_file "$jf" "$jd" "$jm")
done

# =========================================================================
# REPORT
# =========================================================================

printf '%s\n' "$CAL_LINE"
case "$MODE" in
    audit)  printf 'mode: audit (ABSOLUTE tree scan)\n' ;;
    path)   printf 'mode: path %s\n' "$SCAN_PATH" ;;
    staged) printf 'mode: staged\n' ;;
    range)  printf 'mode: range %s\n' "$RANGE" ;;
    diff)   printf 'mode: diff %s..HEAD\n' "$BASELINE_REF" ;;
esac
[ "$IN_REPO" -eq 1 ] && printf 'repo: %s\n' "$REPO_TOP"
if [ -n "$BASELINE_REF" ]; then
    printf 'baseline: %s\n' "$BASELINE_REF"
else
    printf 'baseline: (none resolved) -- every BLOCK-tier hit is treated as unpublished, the fail-safe direction\n'
fi
printf 'corpus: %d swept, %d binary-skipped, %d unswept' "$SWEPT" "$BINARY" "$UNSWEPT"
case "$MODE" in
    staged|range|diff) printf '; %d added lines, %d commit messages' "$ADDED_LINES" "$MSG_COUNT" ;;
esac
printf '\n'
for u in ${UNSWEPT_LIST[@]+"${UNSWEPT_LIST[@]}"}; do
    printf '  UNSWEPT: %s\n' "$u"
done

for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
    IFS=$'\t' read -r tier rule loc cls m note <<< "$f"
    printf '%-8s %-13s %s  %s  %s\n' "$tier" "$rule" "$loc" "$cls" "$m"
    [ -n "$note" ] && printf '         note: %s\n' "$note"
    printf '         fix: %s\n' "${RULE_FIX[$rule]}"
done

printf 'findings: %d blocking, %d advisory\n' "$BLOCKING" "$ADVISORY"

if [ -n "$REPORT" ]; then
    {
        printf '# cc-scrub %s report -- F1 disclosure/topology arm\n' "$CC_SCRUB_VERSION"
        printf '# mode\t%s\n# baseline\t%s\n' "$MODE" "${BASELINE_REF:-(none)}"
        printf '# corpus\t%d swept\t%d binary-skipped\t%d unswept\n' "$SWEPT" "$BINARY" "$UNSWEPT"
        printf 'tier\trule\tlocation\tclassification\tmatch\tnote\tfix\n'
        for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do
            IFS=$'\t' read -r tier rule loc cls m note <<< "$f"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tier" "$rule" "$loc" "$cls" "$m" "$note" "${RULE_FIX[$rule]}"
        done
    } > "$REPORT"
fi

# =========================================================================
# VERDICT
#
# Precedence: an untrustworthy instrument outranks a finding. A CLEAN or
# BLOCK verdict over a corpus that was not fully swept is not a verdict, so
# INCOMPLETE wins and the caller still gets a non-zero exit either way.
# =========================================================================

# A sweep that swept nothing proves nothing. --audit and --path assert "I
# read this artifact"; an empty corpus there means the instrument found
# nothing to measure, which is exactly how the mis-classified corpus reported
# zero of everything. A diff of nothing is a true statement about a range, so
# the diff modes are allowed to be empty and say so.
if [ "$MODE" = "audit" ] || [ "$MODE" = "path" ]; then
    if [ "$SWEPT" -eq 0 ]; then
        printf 'VERDICT: INCOMPLETE -- the corpus is empty; a sweep that swept nothing cannot report CLEAN.\n'
        exit 2
    fi
fi

if [ "$UNSWEPT" -gt 0 ]; then
    printf 'VERDICT: INCOMPLETE -- %d file(s) could not be swept; "unmeasured" is not "clean".\n' "$UNSWEPT"
    exit 2
fi

cat <<'LIMITS'
LIMITS: cc-scrub is a lower bound over mechanical tells. It reports what a
  regex can see and nothing else. NOT covered: F2 provenance and AI-thread
  vocabulary (excluded on purpose -- that pattern set is itself a disclosure
  and stays in the private sweep); F3 register constructions and typography;
  figure, diagram and image content; prose quoted from private artifacts.
  Those classes have no fix in code and need a reviewing session.
LIMITS

if [ "$BLOCKING" -gt 0 ]; then
    printf 'VERDICT: BLOCK -- %d unpublished disclosure(s) in a BLOCK-tier rule.\n' "$BLOCKING"
    exit 1
fi
printf 'VERDICT: CLEAN -- no F1 disclosure pattern matched over the swept corpus.\n'
exit 0
