#!/usr/bin/env bash
# Description: Behavioral tests for cc-scrub.sh's F1 (disclosure/topology) arm — calibration with teeth, the four measured rules and their documented false-positive baits, NEW-vs-ALREADY-PUBLIC classification against a baseline ref, corpus honesty, and the 0904b regression replay.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, grep with -P (PCRE), file, coreutils

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/harness.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"
require_not_root

SCRUB="$MODULE_DIR/canonical/scripts/cc-scrub.sh"

t_begin "cc-scrub F1 arm: disclosure/topology rules, calibration, baseline classification"

# =========================================================================
# WHY THIS FILE EXISTS (RESEARCH-1 / cc-scrub spec section 3.7)
#
# On 2026-09-03 an Opus session read 1,283 added lines across 15 files to
# find one live LAN address in a commit bound for a PUBLIC remote. One
# range-checked regex would have found it and nothing else in the repo
# (precision 1.00, recall 1.00). That rule did not exist.
#
# The second, quieter defect this file guards is the FALSE ZERO. Two
# instruments printed a clean bill of health over real disclosures in a
# single evening: an OCR arm that had never been calibrated, and a corpus
# classifier that matched 1 file of 185 because `file --mime-type`
# right-pads its output. An uncalibrated scrubber is worse than no
# scrubber, because it converts "unmeasured" into "verified clean".
#
# So the assertions below are in two halves of equal weight:
#   * the rules catch what they must catch, and stay silent on the
#     documented baits (a naive RFC1918 pattern returns 11 "literals" on
#     the sentinel corpus, every one a decimal measurement);
#   * the INSTRUMENT fails loudly. Break a detector and calibration must
#     exit 2 naming the missed plant; leave a file unclassifiable and the
#     run must refuse to say CLEAN.
# =========================================================================

# --- plant and bait literals ---------------------------------------------
#
# ASSEMBLED, NEVER WRITTEN OUT. This file is tracked in a PUBLIC repository
# and is itself part of the corpus that `cc-scrub --audit` sweeps. A literal
# RFC1918 dotted quad, a literal /home/<user> path or a bare session token
# written here would make the test suite a specimen of the very disclosure
# class it exists to prove the tool catches -- and would be reported as a
# NEW finding by every audit of this repo, forever. The fragments below
# match no rule on their own.
Q192="192.168"; Q10="10"; Q172="172.16"; SEG_HOME="home"; TOK="AbCd1234567890XyZ"; HL="homelab"
PLANT_IP192="${Q192}.44.44"          # 192.168/16   host
PLANT_IP10="${Q10}.99.99.99"         # 10/8         host
PLANT_IP172="${Q172}.30.40"          # 172.16/12    host
PLANT_HOME="/${SEG_HOME}/plantuser/vault"
PLANT_SESSION="session_${TOK}"
PLANT_HOMELAB="fixture.${HL}"
BAIT_CIDR="${Q192}.0.0/16"           # network address in CIDR form -- the live negative control
BAIT_TRAILER="https://claude.ai/code/${PLANT_SESSION}"

REAL_GREP="$(command -v grep)"

# --- helpers --------------------------------------------------------------

# scrub_in <dir> <args...> -- run cc-scrub with <dir> as cwd.
scrub_in() { local d="$1"; shift; ( cd "$d" && bash "$SCRUB" "$@" ); }

# fixture_dir <line>... -- a scratch dir holding one file of the given lines.
fixture_dir() {
    local d
    d=$(t_tmpdir) || return 1
    printf '%s\n' "$@" > "$d/sample.md"
    printf '%s\n' "$d"
}

# scan_path <line>... -- run --path over a fixture holding those lines.
# Sets T_OUT/T_ERR/T_RC. No baseline is resolvable in a scratch dir, so
# every BLOCK-tier hit classifies UNKNOWN and blocks: that is the fail-safe
# direction, and it makes these rule tests read as pure detection tests.
scan_path() {
    local d
    d=$(fixture_dir "$@") || return 1
    t_run bash "$SCRUB" --path "$d"
}

# =========================================================================
# 1. CALIBRATION -- the instrument proves itself before it sweeps anything
# =========================================================================

t_diag "--- calibration ---"

t_run bash "$SCRUB" --calibrate-only
assert_eq "--calibrate-only exits 0 on a working instrument" 0 "$T_RC"
assert_contains "calibration reports plants caught" "plants caught" "$T_OUT"
assert_contains "calibration passes" "PASS" "$T_OUT"
assert_contains "calibration reports the negative-control sample size" "negative control" "$T_OUT"
assert_not_contains "a passing calibration names no missed plant" "missed plant" "$T_OUT"

# A control over an empty set proves nothing, so the counts must be real.
CAL_LINE=$(printf '%s\n' "$T_OUT" | grep -m1 'plants caught')
CAL_N=$(printf '%s' "$CAL_LINE" | grep -oP '(?<=^calibration: )[0-9]+(?=/)')
assert_eq "every plant was caught (N/N)" "$CAL_N/$CAL_N" "$(printf '%s' "$CAL_LINE" | grep -oP '[0-9]+/[0-9]+' | head -1)"
if [ -n "${CAL_N:-}" ] && [ "$CAL_N" -ge 4 ]; then
    t_pass "at least one plant per enabled rule (>=4 plants), not a vacuous control"
else
    t_fail "at least one plant per enabled rule (>=4 plants), not a vacuous control" "calibration line: $CAL_LINE"
fi
BAIT_N=$(printf '%s' "$CAL_LINE" | grep -oP '(?<=over )[0-9]+(?= baits)')
if [ -n "${BAIT_N:-}" ] && [ "$BAIT_N" -ge 10 ]; then
    t_pass "negative control carries the documented baits (>=10)"
else
    t_fail "negative control carries the documented baits (>=10)" "calibration line: $CAL_LINE"
fi

# --- calibration has teeth (spec acceptance criterion 4) ------------------
#
# The overnight mutate.sh lesson in one assertion: a harness that never
# really runs its subject reports fiction. Break one rule's detector and the
# tool must refuse to report CLEAN, and must name WHICH plant it missed.

D_MUT=$(t_tmpdir) || exit 1
sed "s|^RE_HOMEPATH=.*|RE_HOMEPATH='ZZNEVERMATCHESZZ'|" "$SCRUB" > "$D_MUT/broken-detector.sh"
assert_ne "mutant differs from the original (the sed anchor still exists)" \
    "$(md5sum < "$SCRUB")" "$(md5sum < "$D_MUT/broken-detector.sh")"
t_run bash "$D_MUT/broken-detector.sh" --calibrate-only
assert_eq "a broken detector fails calibration with exit 2" 2 "$T_RC"
assert_contains "the broken run names the missed plant" "missed plant" "$T_OUT"
assert_contains "the broken run names the rule that missed it" "home-path" "$T_OUT"
assert_not_contains "a broken instrument never prints PASS" "-- PASS" "$T_OUT"

# The negative control must be live too, not decorative. Swap the
# range-checked pattern for the naive one the spec documents as bait
# (it returns 11 "literals" on the sentinel corpus, all decimals).
sed "s|^RE_RFC1918=.*|RE_RFC1918='\\\\b(10\|192\\\\.168\|172\\\\.(1[6-9]\|2[0-9]\|3[01]))\\\\.[0-9.]+\\\\b'|" \
    "$SCRUB" > "$D_MUT/naive-detector.sh"
t_run bash "$D_MUT/naive-detector.sh" --calibrate-only
assert_eq "an over-broad detector fails the negative control with exit 2" 2 "$T_RC"
assert_contains "the over-broad run names the false positive" "negative control" "$T_OUT"

# =========================================================================
# 2. RULE: rfc1918-host -- the rule the 0904b BLOCK needed
# =========================================================================

t_diag "--- rule: rfc1918-host ---"

scan_path "a port to accept: nc -z $PLANT_IP192 80"
assert_eq "192.168/16 host literal is a finding (exit 1)" 1 "$T_RC"
assert_contains "...reported under rule rfc1918-host" "rfc1918-host" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"
assert_contains "...quoting the offending text" "$PLANT_IP192" "$T_OUT"
assert_contains "...with file:line:col" "sample.md:1:" "$T_OUT"

scan_path "gateway $PLANT_IP10"
assert_eq "10/8 host literal is a finding" 1 "$T_RC"
scan_path "gateway $PLANT_IP172"
assert_eq "172.16/12 host literal is a finding" 1 "$T_RC"

# --- documented false-positive baits: the rule must stay silent ----------
#
# Every literal below is drawn from the spec's calibration warning or from
# the public baseline. A naive pattern flags the first six as RFC1918
# "literals"; they are decimal measurements in a hardware repo.

scan_path "tolerance 10.033 mm, span 10.287, ratio 10.0, 10.5, 10.6, 10.16"
assert_eq "sentinel decimal measurements are not IP literals" 0 "$T_RC"
assert_not_contains "...and are not reported at all" "rfc1918-host" "$T_OUT"

scan_path "no_proxy includes $BAIT_CIDR and the sandbox firewall blocks direct"
assert_eq "a network address in CIDR form is not a host literal" 0 "$T_RC"

scan_path "listen 127.0.0.1 and bind 0.0.0.0 with mask 255.255.255.0"
assert_eq "loopback, wildcard and netmask are not RFC1918 hosts" 0 "$T_RC"

scan_path "resolver 8.8.8.8 and peer 1.2.3.4"
assert_eq "public addresses are not RFC1918 hosts" 0 "$T_RC"

scan_path "edge 172.15.0.1 and edge 172.32.0.1"
assert_eq "addresses outside the 172.16/12 block are not RFC1918" 0 "$T_RC"

scan_path "version 10.1.2 and build 1.10.0.0.4"
assert_eq "three-component versions and longer dotted runs do not match" 0 "$T_RC"

# =========================================================================
# 3. RULE: home-path
# =========================================================================

t_diag "--- rule: home-path ---"

scan_path "the vault lives at $PLANT_HOME"
assert_eq "an absolute /home/<user> path is a finding" 1 "$T_RC"
assert_contains "...reported under rule home-path" "home-path" "$T_OUT"

scan_path 'the vault lives at $HOME/vault and config at ~/.claude'
assert_eq "\$HOME and ~ are not absolute home paths" 0 "$T_RC"

scan_path "installed under /homebrew/bin and /home is a mountpoint"
assert_eq "/homebrew and a bare /home are not /home/<user>" 0 "$T_RC"

# =========================================================================
# 4. RULE: session-id
# =========================================================================

t_diag "--- rule: session-id ---"

scan_path "resumed from $PLANT_SESSION in the tree"
assert_eq "a bare session token is a finding" 1 "$T_RC"
assert_contains "...reported under rule session-id" "session-id" "$T_OUT"

# The harness appends `Claude-Session: https://claude.ai/code/session_...`
# to EVERY commit message; the public baseline carries 63 of them. That
# class is spec section 5.1 ADVISORY, parked on CEO question Q1, and was
# approved by seven push-reviews. A BLOCK rule that fired on it would halt
# every push forever and would fail the 7a07def..bf0b721 replay below.
scan_path "Claude-Session: $BAIT_TRAILER"
assert_eq "the harness Claude-Session trailer URL does not block (Q1 class)" 0 "$T_RC"

scan_path "read the session_id field and sha 6efe32c9e2dd002d0c394e861e0529675d1ab32e"
assert_eq "a short session_ field name and a git sha are not session tokens" 0 "$T_RC"

# =========================================================================
# 5. RULE: homelab-host -- ADVISORY, never blocking
# =========================================================================

t_diag "--- rule: homelab-host ---"

scan_path "wait_for 60 plane nc -z $PLANT_HOMELAB 80"
assert_eq "a .homelab hostname does not block" 0 "$T_RC"
assert_contains "...but it is reported" "homelab-host" "$T_OUT"
assert_contains "...at ADVISORY tier" "ADVISORY" "$T_OUT"

scan_path "the homelab runs on a single node"
assert_eq "the bare word homelab is not a hostname" 0 "$T_RC"
assert_not_contains "...and is not reported" "homelab-host" "$T_OUT"

# =========================================================================
# 6. NEW vs ALREADY-PUBLIC (spec section 2.1)
#
# The distinction every one of the seven APPROVE verdicts turned on, and
# the one an absolute scanner cannot express. Classification is done on the
# MATCHED LITERAL against the baseline ref's tree and message history --
# never inferred from an ahead-count, which describes a branch tip's
# distance and says nothing about when a blob entered history.
# =========================================================================

t_diag "--- NEW vs ALREADY-PUBLIC ---"

mk_repo() {   # a scratch git repo whose baseline is tag 'base'
    R=$(t_tmpdir) || return 1
    git -C "$R" init -q
    git -C "$R" config user.email t@example.invalid
    git -C "$R" config user.name  Tester
    printf 'the vault lives at %s\n' "$PLANT_HOME" > "$R/baseline.md"
    git -C "$R" add -A
    git -C "$R" -c commit.gpgsign=false commit -qm 'baseline'
    git -C "$R" tag base
}

mk_repo || exit 1
printf 'a second file also naming %s\n' "$PLANT_HOME" > "$R/added.md"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -qm 'add a value already present at baseline'
t_run scrub_in "$R" --range base..HEAD
assert_eq "a value present at baseline is advisory, not blocking" 0 "$T_RC"
assert_contains "...and is labelled BASELINE" "BASELINE" "$T_OUT"
assert_not_contains "...and is not labelled NEW" "NEW" "$T_OUT"

mk_repo || exit 1
printf 'a NEW disclosure: %s\n' "$PLANT_IP192" > "$R/added.md"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -qm 'add a value absent at baseline'
t_run scrub_in "$R" --range base..HEAD
assert_eq "a value absent at baseline blocks" 1 "$T_RC"
assert_contains "...and is labelled NEW" "NEW" "$T_OUT"
assert_contains "...naming the file it entered on" "added.md:1:" "$T_OUT"

# A range scans commit MESSAGES too -- the 0904b review read all four.
mk_repo || exit 1
printf 'unremarkable\n' > "$R/added.md"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -qm "probe against $PLANT_IP10 during setup"
t_run scrub_in "$R" --range base..HEAD
assert_eq "a disclosure in a commit message blocks" 1 "$T_RC"
assert_contains "...attributed to the commit message" "commit-message" "$T_OUT"

# =========================================================================
# 7. THE 0904b REGRESSION, REPLAYED (spec acceptance criterion 1)
# =========================================================================

t_diag "--- 0904b regression replay ---"

if git -C "$REPO_ROOT" rev-parse -q --verify 7a07def^{commit} >/dev/null 2>&1 \
   && git -C "$REPO_ROOT" rev-parse -q --verify fe46d7f^{commit} >/dev/null 2>&1 \
   && git -C "$REPO_ROOT" rev-parse -q --verify bf0b721^{commit} >/dev/null 2>&1; then

    t_run scrub_in "$REPO_ROOT" --range 7a07def..fe46d7f
    assert_eq "the blocked range exits 1" 1 "$T_RC"
    assert_contains "...naming condition-based-waiting.md:66" \
        "systematic-debugging/condition-based-waiting.md:66:" "$T_OUT"
    assert_contains "...under rule rfc1918-host" "rfc1918-host" "$T_OUT"
    assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"
    assert_contains "...classified NEW" "NEW" "$T_OUT"
    BLOCKING=$(printf '%s\n' "$T_OUT" | grep -c '^BLOCK')
    assert_eq "the IP is the ONLY blocking finding in 1,283 added lines" 1 "$BLOCKING"

    t_run scrub_in "$REPO_ROOT" --range 7a07def..bf0b721
    assert_eq "the post-scrub range exits 0" 0 "$T_RC"
    assert_not_contains "...with no BLOCK-tier line" "
BLOCK" "
$T_OUT"
    assert_contains "...and reports CLEAN" "VERDICT: CLEAN" "$T_OUT"
else
    t_diag "regression refs not present in this clone - replay skipped"
    t_pass "0904b replay skipped (refs 7a07def/fe46d7f/bf0b721 absent)"
fi

# =========================================================================
# 7b. SCOPE -- a repo mode covers the repo, not the caller's subdirectory
#
# `git ls-files` and `git diff` are both cwd-relative. A hook or a session
# that happened to be sitting in a subdirectory would sweep that subtree and
# print a whole-tree verdict over it: an unmeasured subset reported as a
# clean whole, which is the exact false-zero shape this tool exists to
# refuse. --path is how you deliberately scan one directory.
# =========================================================================

t_diag "--- scope: repo modes cover the whole tree ---"

mk_repo || exit 1
mkdir -p "$R/sub"
printf 'nothing here\n' > "$R/sub/keep.md"
printf 'a NEW disclosure: %s\n' "$PLANT_IP192" > "$R/root-file.md"
git -C "$R" add -A
git -C "$R" -c commit.gpgsign=false commit -qm 'add a root file beside a subdirectory'

t_run scrub_in "$R/sub" --audit --baseline base
assert_eq "--audit from a subdirectory still sweeps the whole tree" 1 "$T_RC"
assert_contains "...reaching a disclosure in a root file" "root-file.md" "$T_OUT"

t_run scrub_in "$R/sub" --range base..HEAD
assert_eq "--range from a subdirectory still covers the whole range" 1 "$T_RC"
assert_contains "...reaching a disclosure in a root file" "root-file.md" "$T_OUT"

# =========================================================================
# 8. CORPUS HONESTY (spec acceptance criterion 5)
#
# "Unmeasured" must never render as "clean". The direct descendant of the
# uncalibrated OCR arm and of the `file --mime-type` right-padding bug that
# classified 1 file of 185 and reported zero of everything.
# =========================================================================

t_diag "--- corpus honesty ---"

D_OK=$(fixture_dir "nothing to see here") || exit 1
t_run bash "$SCRUB" --path "$D_OK"
assert_eq "a clean path exits 0" 0 "$T_RC"
assert_contains "...printing the corpus size beside the verdict" "corpus:" "$T_OUT"
assert_contains "...counting swept files" "1 swept" "$T_OUT"

D_EMPTY=$(t_tmpdir) || exit 1
t_run bash "$SCRUB" --path "$D_EMPTY"
assert_eq "a sweep over an EMPTY corpus refuses to report CLEAN (exit 2)" 2 "$T_RC"
assert_contains "...and says so" "INCOMPLETE" "$T_OUT"
assert_not_contains "...never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

D_UNS=$(fixture_dir "harmless") || exit 1
printf 'unreadable\n' > "$D_UNS/opaque.bin"
chmod 000 "$D_UNS/opaque.bin"
t_run bash "$SCRUB" --path "$D_UNS"
chmod 644 "$D_UNS/opaque.bin"
assert_eq "an unclassifiable file makes the run INCOMPLETE (exit 2)" 2 "$T_RC"
assert_contains "...naming it UNSWEPT" "UNSWEPT" "$T_OUT"
assert_not_contains "...never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

# An instrument that cannot run must fail differently from one that ran and
# found nothing. Without PCRE every rule silently matches nothing.
D_NOPCRE=$(t_tmpdir) || exit 1
mkdir -p "$D_NOPCRE/bin"
{
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do case "$a" in -*P*) echo "grep: -P unsupported" >&2; exit 2;; esac; done\n'
    printf 'exec %s "$@"\n' "$REAL_GREP"
} > "$D_NOPCRE/bin/grep"
chmod +x "$D_NOPCRE/bin/grep"
t_run env "PATH=$D_NOPCRE/bin:$PATH" bash "$SCRUB" --path "$D_OK"
assert_eq "grep without -P is INCOMPLETE, not CLEAN (exit 2)" 2 "$T_RC"
assert_not_contains "...never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

# =========================================================================
# 9. SELF-LIMITS (spec acceptance criterion 10)
# =========================================================================

t_diag "--- stated limits ---"

t_run bash "$SCRUB" --path "$D_OK"
assert_contains "a CLEAN verdict states it is a lower bound" "lower bound" "$T_OUT"
assert_contains "...naming F2 provenance as uncovered" "F2" "$T_OUT"
assert_contains "...naming register constructions as uncovered" "register" "$T_OUT"
assert_contains "...naming figure content as uncovered" "figure" "$T_OUT"

# =========================================================================
# 10. MODES, REPORT, AND USAGE
# =========================================================================

t_diag "--- modes, report, usage ---"

t_run bash "$SCRUB" --help
assert_eq "--help exits 0" 0 "$T_RC"
assert_contains "--help names the audit mode" "--audit" "$T_OUT"

t_run bash "$SCRUB" --no-such-flag
assert_eq "an unknown flag is a usage error (exit 3)" 3 "$T_RC"

t_run bash "$SCRUB" --audit --staged
assert_eq "two modes at once is a usage error (exit 3)" 3 "$T_RC"

# BLOCK tier is never auto-fixed: substituting a hostname for an address is
# a semantic change a human must make (spec section 5.1).
t_run bash "$SCRUB" --fix --rule rfc1918-host
assert_eq "--fix is refused for the F1 arm (exit 3)" 3 "$T_RC"
assert_contains "...explaining that BLOCK-tier findings are never auto-fixed" "never auto-fixed" "$T_ERR$T_OUT"

mk_repo || exit 1
printf 'a NEW disclosure: %s\n' "$PLANT_IP192" > "$R/added.md"
git -C "$R" add -A
t_run scrub_in "$R" --staged
assert_eq "--staged sees the staged disclosure" 1 "$T_RC"
assert_contains "...naming the staged file" "added.md" "$T_OUT"

D_REP=$(t_tmpdir) || exit 1
scrub_in "$R" --staged --report "$D_REP/report.tsv" >/dev/null 2>&1
assert_eq "--report writes a file" "yes" "$( [ -s "$D_REP/report.tsv" ] && echo yes || echo no )"
assert_contains "...with a column header" "rule" "$(head -c 4096 "$D_REP/report.tsv" 2>/dev/null)"
assert_contains "...and the finding's rule" "rfc1918-host" "$(cat "$D_REP/report.tsv" 2>/dev/null)"
assert_contains "...and its NEW/BASELINE classification" "NEW" "$(cat "$D_REP/report.tsv" 2>/dev/null)"

# =========================================================================
# 11. THE TOOL IS NOT ITSELF A SPECIMEN
#
# cc-scrub.sh and this file are tracked in a PUBLIC repo and are swept by
# --audit. If either carried a literal disclosure, the tool would report
# itself forever and would be an instance of the class it hunts -- the same
# reasoning that keeps the F2 pattern set out of this repo entirely.
# =========================================================================

t_diag "--- the tool is not its own disclosure ---"

D_SELF=$(t_tmpdir) || exit 1
cp "$SCRUB" "$D_SELF/subject.sh"
cp "${BASH_SOURCE[0]}" "$D_SELF/subject-tests.sh"
t_run bash "$SCRUB" --path "$D_SELF"
assert_eq "cc-scrub.sh and its tests carry no BLOCK-tier disclosure" 0 "$T_RC"

# =========================================================================
# 12. AUDIT OVER THE REAL REPO (spec acceptance criterion 2, F1 part)
# =========================================================================

t_diag "--- audit over the public baseline ---"

t_run scrub_in "$REPO_ROOT" --audit
assert_ne "an audit of the repo is not INCOMPLETE" 2 "$T_RC"
assert_eq "an audit of the public repo reports zero BLOCK-tier findings" 0 "$T_RC"
assert_contains "...over a corpus of real size, printed beside the verdict" "swept" "$T_OUT"
AUDIT_N=$(printf '%s\n' "$T_OUT" | grep -oP '(?<=^corpus: )[0-9]+(?= swept)')
if [ -n "${AUDIT_N:-}" ] && [ "$AUDIT_N" -gt 100 ]; then
    t_pass "the audit corpus is the whole repo (>100 files), not a silently empty one"
else
    t_fail "the audit corpus is the whole repo (>100 files), not a silently empty one" \
           "corpus line: $(printf '%s\n' "$T_OUT" | grep -m1 '^corpus:')"
fi

t_finish
