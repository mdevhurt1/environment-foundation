RUBRIC: 1.0.0
REVIEWER: claude-opus-5-5
VERDICT: FAIL
FINDINGS: 3

FINDING 1
axis: correctness
severity: blocking
confidence: high
location: scripts/install.sh:42
claim: `rmdir "$src"` fails because `git rm` already removed the empty parent directory.
scenario: git rm of the last tracked file deletes the directory, so rmdir exits 1 under set -e and the task stops half done.
fix: Drop the rmdir, or guard it with [ -d "$src" ].

FINDING 2
axis: verifiability
severity: non-blocking
confidence: high
location: scripts/verify.sh:17
claim: The `grep -c` check passes even when the log file is empty.
scenario: grep -c prints 0 and the check compares nothing, so an empty log reports PASS.
fix: Assert the count is greater than zero.

FINDING 3
axis: correctness
severity: non-blocking
confidence: medium
location: scripts/install.sh:44
claim: chmod sets mode 644 on the pre-commit hook, which leaves it non-executable.
scenario: git silently skips a non-executable hook, so the scrub never runs.
fix: Use chmod 755.

CHECKED:
- scripts/install.sh:12 backs up the target before linking
- scripts/verify.sh:3 sets -uo pipefail
END REVIEW
