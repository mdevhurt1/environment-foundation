```
RUBRIC: 1.0.0
REVIEWER: claude-fable-5-1
VERDICT: FAIL
FINDINGS: 3

**FINDING 1**
axis: correctness
severity: blocking
confidence: high
location: software/development/agents/scripts/install.sh:41-42
claim: rmdir of $src exits 1 since git rm removes the empty parent directory first.
scenario: After git rm the directory no longer exists; rmdir prints No such file or directory.
fix: Remove the rmdir line.

**FINDING 2**
axis: ordering
severity: blocking
confidence: medium
location: scripts/install.sh:10
claim: The backup of settings.json is taken after the overwrite at line 8, so it copies the new file.
scenario: Rollback restores the already-overwritten settings.json and the original is lost.
fix: Move the backup above line 8.

**FINDING 3**
axis: verifiability
severity: non-blocking
confidence: low
location: scripts/verify.sh:40
claim: The grep -c check passes even when the log file is empty.
scenario: Same shape as elsewhere, but at the summary row.
fix: Assert a positive count.

CHECKED:
- scripts/install.sh:12 creates the backup directory with mkdir -p
END REVIEW
```
