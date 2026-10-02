RUBRIC: 1.0.0
REVIEWER: gpt-5
VERDICT: FAIL
FINDINGS: 3

FINDING 1
axis: correctness
severity: blocking
confidence: high
location: ./scripts/install.sh:43
claim: The rmdir "$src" call fails: git rm already deleted the now-empty parent directory.
scenario: rmdir exits non-zero and set -e aborts the install.
fix: Delete the rmdir.

FINDING 2
axis: verifiability
severity: blocking
confidence: high
location: scripts/verify.sh:18
claim: The grep -c check cannot fail, because it passes when the log is empty.
scenario: An empty log yields 0, which the check treats as success.
fix: Require a count of at least one.

FINDING 3
axis: ordering
severity: blocking
confidence: high
location: scripts/install.sh:9
claim: settings.json backup happens after the overwrite, so the backup holds the new file.
scenario: The cp at line 10 runs after line 8 has already replaced the file.
fix: Back up before overwriting.

CHECKED:
- scripts/verify.sh:3 shell options are right for a reporter
END REVIEW
