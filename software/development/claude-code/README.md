# Claude Code

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04, windows-11 (WSL)

Anthropic's official CLI for Claude. Provides an agentic coding assistant
directly in the terminal with tool use, codebase context, and extensibility
via MCP servers and hooks.

## Dependencies

- Node.js 20+ and npm (installed by `install.sh` if not present)

## Install

```bash
bash scripts/install.sh
```

## Configure

```bash
bash scripts/configure.sh
```

Configure sets up `~/.claude/settings.json` with a baseline configuration and
prints instructions for setting your `ANTHROPIC_API_KEY`.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Fully supported, primary target |
| ubuntu-22.04 | Fully supported |
| windows-11 | Run inside WSL2 Ubuntu terminal |

## Verify

```bash
claude --version
```

## Workflow SOP

This module deploys a deterministic Claude Code workflow. See the design spec at:
`docs/superpowers/specs/2026-05-08-claude-obsidian-workflow-sop-design.md`
(gitignored — local copy).

### Install

```bash
bash scripts/install.sh        # installs Claude Code itself
bash scripts/configure.sh      # symlinks canonical/ into ~/.claude/, adds cc-* wrappers
```

Then clone and install secrets (separate private repo):

```bash
git clone <gitea>/mhurt/environment-secrets ~/environment-secrets
~/environment-secrets/install.sh
```

Verify: `cc-doctor`

### Wrappers

| Command | Mode | When |
|---|---|---|
| `cc-explore <slug>` | sandbox + git worktree + strict perms | research, debug, brainstorm |
| `cc-build` | main worktree, requires a plan/spec | execute approved plan |
| `cc-continue [name]` | inherits original mode from `.cc-mode` | resume a worktree/session |
| `cc-branch <task-id> [<repo>]` | branched worker in its own worktree + tmux window | delegate a task from the EA |
| `cc-doctor` | n/a | verify install, detect drift |

Direct `claude` invocation still works but is non-SOP — prefer wrappers.
Only the wrappers apply the model policy below; a bare `claude` still gets
Claude Code's Default.

### Permission mode

The wrappers pass **no permission flag** unless someone asked for one. Absent
an override, `settings.json` `permissions.defaultMode` governs — today `auto`.

They used to append `--dangerously-skip-permissions` to every launch, which
silently out-voted that setting for the EA and for every task the company
delegates. A wrapper may carry an override; it may not out-vote a versioned,
reviewed, checked-in choice. Resolution order, mirroring the model policy:

| Order | Source | Result |
|---|---|---|
| 1 | `$CC_PERM_MODE` | `--permission-mode <value>`, recorded as `perm_mode_source=env` |
| 2 | `roles.<role>.permission_mode` in `canonical/model-policy.json` | `--permission-mode <value>`, recorded as `policy:<role>` |
| 3 | neither (the steady state) | **no flag**; `settings.json` `permissions.defaultMode` governs |

```bash
CC_PERM_MODE=bypassPermissions cc-branch <task-id> [<repo-path>]
```

Valid values are read from `claude --help` at launch rather than hardcoded —
the list has already changed shape once (2.1.236 offers `manual` and `dontAsk`,
and rejects `Default`). An unknown value is **refused before any worktree,
branch or tmux window is created**, the same before-any-side-effect rule the
model resolver follows.

The asymmetry with the model policy is deliberate: a missing policy, role or
`jq` is **not** fatal here. `__cc_resolve_model` refuses because Default is a
moving referent and falling through to it costs money silently; falling through
on permission mode lands on an explicit value in a tracked file, which is the
outcome we want.

`.cc-mode` and the tree slot carry `perm_mode` / `perm_mode_source`, so an
override is as visible in the tree as a model choice is. On the settings-default
path `perm_mode` is empty and `perm_mode_source=settings-default`.

### The `.cc-mode` format

One `key=value` per line. A value is written **bare** iff every character of it
is in `[A-Za-z0-9_@%+:,./-]` (the empty string qualifies, which is what makes
`perm_mode=` a legal line); otherwise it is **single-quoted**, with each
embedded `'` written as `'\''`. A line break cannot be represented and is
stripped at the write boundary — the only lossy step. Every value the wrappers
write today is a bare token, so real files are unquoted in practice.

The invariant, enforced by `tests/test_mode_file_roundtrip.sh`: **sourcing a
`.cc-mode` produced by `__cc_write_mode_file` can never execute anything, and
can never alter a field other than the one being assigned.**

Nothing in this repo sources the file any more. `statusline-command.sh` parses
it against a whitelist of the keys it displays, so a `.cc-mode` from *any*
origin — an older writer, a hand edit, a restored backup — is inert to it. Use
`__cc_mode_unquote` when reading a value that could be quoted; the six helpers
that read ids and slugs with `grep '^key=' | cut -d= -f2-` are fine as they are,
because those values are bare tokens. Full reasoning is in the contract comment
above `__cc_mode_quote` in `canonical/shell/cc-functions.sh` (INFRA-45).

**Workspace trust.** Claude Code asks interactively before touching a directory
it has not been told to trust, and — measured on 2.1.236 — it asks under *every*
permission mode, `--dangerously-skip-permissions` included. The bypass flag was
never what suppressed that dialog; what suppressed it was that most launch
directories had already been trusted by hand. Every `cc-branch` / `cc-explore`
worktree is brand new, so an unattended child would sit on the dialog forever.
Both wrappers therefore pre-register the worktree they just created by setting
`projects["<path>"].hasTrustDialogAccepted` in `~/.claude.json` — the remedy
Claude Code itself names in its untrusted-workspace error. It is skipped when
trust is already effective, serialised with `flock`, landed with an atomic
rename, and **never fatal**: a session stopped on a trust dialog is recoverable
by a human, a clobbered `~/.claude.json` is not.

### Model policy

Claude Code's "Default" resolves to the **most capable model available to the
account**, so it is a moving referent: when a new model joins the account
roster, Default silently captures every session that has not pinned one. On
2026-08-20 that moved the EA session from Opus 5 to Fable 5 with no diff and no
output anywhere. It had already moved Opus 4.8 -> Opus 5 before that.

`canonical/model-policy.json` maps **session roles to model choices**, and the
`cc-*` wrappers resolve `--model` from it at launch:

| Role | Used by |
|---|---|
| `ea` | `cc` — the command-center / EA session |
| `branched-worker` | `cc-branch` children |
| `explore` | `cc-explore` |
| `build` | `cc-build` |
| `review-lane`, `cheap-mechanical`, `subagent-default`, `scheduled` | reserved; not yet mechanized |

Each role takes one of three legal values:

- `"track-latest"` — deliberately accept Default; the tier **may move**. The
  wrapper passes no `--model` and records `model_source=policy:<role>`, so the
  choice is on record even though the command line looks unpinned.
- a tier alias — `opus`, `sonnet`, `fable`, `haiku`. Tier pinned, version
  tracks within it. This is what survives a new model joining the roster.
- an exact id — e.g. `claude-opus-5[1m]`. Fully pinned.

The point is not to ban Default. It is that Default must be **chosen** rather
than inherited.

**The EA session picks its model up here.** `cc` resolves role `ea` before
creating the tmux session and passes the flag inside the window's command
string, so the EA is subject to the same policy as everything it spawns.

**Override a single launch** with an env prefix — recorded as
`model_source=env`, so an override is as visible in the tree as a policy
choice is:

```bash
CC_MODEL=opus cc-branch <task-id> [<repo-path>]
```

`CC_MODEL` also bypasses policy lookup entirely, so a missing or broken policy
file can never strand you. Absent that override the wrappers **refuse to
launch** rather than falling back to Default — a refusal costs one command,
whereas the silent version was discovered by a bill.

**Where the choice is visible:**

- `.cc-mode` and the session's tree slot carry `model` / `model_source`
  (intent).
- The statusline shows the **running** model from the harness, plus a
  `MODEL-DRIFT` marker when it disagrees with the stamped intent (reality).

**When the account roster changes**, `cc-doctor` check 10c WARNs about any
model not listed in the policy's `known_models`. Adding it there *is* the act
of deciding that `track-latest` still applies; pinning the affected roles is
the other option.

### Bookend skills

- **session-start** — auto-runs via SessionStart hook. Verifies mode,
  surfaces vault context, declares goal.
- **end-conversation** — run `/end-conversation` (or react to `CTX-WARN` in
  statusline). Walks the closing ritual: memory delta, spec/plan
  capture, transcript decision, vault sync, promotion candidates,
  worktree fold.

### Vault

`~/vault/` (designed in `homelab/obsidian-stack/`, not deployed by
this module). Three rings + journal:
- `00-core/` — human-only inner ring
- `10-middle/` — human-curated synthesis
- `20-surface/` — machine-fed by end-conversation
- `40-journal/` — daily voice practice

Promotion is always manual, weekly cadence. See `00-core/_rituals/weekly-review.md`.

## Where canonical payload lives

Three directories under `canonical/`, split by who invokes the file rather
than by what language it is written in. INFRA-59 settled this before wiring
made it expensive to move anything:

| directory | invoked by | examples |
|---|---|---|
| `shell/` | the harness and the skills — sourced, or run as a helper | `cc-functions.sh`, `cc-plane-sync.sh`, `cc-outbound-guard.sh` |
| `scripts/` | a person or a gate, by path, with its own CLI and exit-code contract | `cc-scrub.sh`, `cc-scrub-outbound.sh` |
| `hooks/` | git | `pre-commit.sh`, `pre-push.sh`, `cc-scrub-hook-lib.sh` |

The open question was whether `cc-scrub.sh` belonged in `shell/` with
everything else, since it was the only file under `scripts/` when it landed.
It stays: it is not a harness helper, it has a documented CLI and four
distinct exit codes, and the outbound arm joined it there under INFRA-62, so
`scripts/` is now a populated category rather than an exception of one.

## cc-scrub — disclosure scan (F1 arm)

`canonical/scripts/cc-scrub.sh` scans a diff for **disclosure and topology
tells** before they reach a public remote: RFC1918 host literals, absolute
paths naming an operator account, session identifiers, and internal
hostnames. It exists because a commit bound for this repo's public remote
once carried the live LAN address of the Plane server, and finding it cost a
full review session reading 1,283 added lines. One range-checked regex finds
it and nothing else in the entire repository.

```bash
bash canonical/scripts/cc-scrub.sh                  # diff <baseline>..HEAD, incl. commit messages
bash canonical/scripts/cc-scrub.sh --staged         # pre-commit
bash canonical/scripts/cc-scrub.sh --range A..B     # pre-push
bash canonical/scripts/cc-scrub.sh --audit          # absolute tree scan; not the default
bash canonical/scripts/cc-scrub.sh --path <dir>     # pre-submission
bash canonical/scripts/cc-scrub.sh --calibrate-only # prove the instrument, sweep nothing
bash canonical/scripts/cc-scrub.sh --report <file>  # TSV for a reviewing session
```

`configure.sh` also deploys it as `~/.claude/cc-scrub`. The file keeps its
`.sh` extension so the module-wide static gate still globs it; the deployed
name drops it, because `cc-scrub` is what the docs and the operator call the
tool.

### Wired into git, not into memory (INFRA-59)

The first two lines above are not suggestions. `configure.sh` installs them
as hooks, so the sweep is mechanical:

| hook | corpus | cc-scrub mode |
|---|---|---|
| `pre-commit` | the staged changes | `--staged` |
| `pre-push` | each outgoing range, commit messages included | `--range <remote-sha>..<local-sha>` |

**Why both.** They sweep different corpora and neither contains the other.
`pre-commit` cannot see a commit *message*, because the message does not
exist yet when it runs — and measured on this repository, an earlier hand
scrub removed a LAN address from the tracked files and then quoted it four
times in its own commit message. Push is also the moment the boundary is
actually crossed: a local commit discloses nothing, and history rewritten
before a push is free.

**Only exit `0` clears.** `1` (blocking findings) and `2` (INCOMPLETE — the
sweep could not prove itself) both refuse, as does a scrubber that cannot be
found at all. A gate that fails open converts "unguarded" into "verified
guarded", which is the one failure mode a gate may not have.

**There is no override of its own.** git already provides `--no-verify` and
cannot be stopped from honouring it, so a second bypass would only add a
quieter one that leaves no trace in shell history. The refusal message names
it; the house rule is that a commit or push made that way is a reportable
event that belongs in the session report.

**How they are deployed.** As symlinks from the repository's *common* hooks
directory (`git rev-parse --git-path hooks`) into `canonical/hooks/`, which
is how every other canonical asset ships. Two consequences worth knowing:
editing `canonical/hooks/` edits the live gate rather than forking it, and
one install from the main checkout arms every `cc-branch` worktree, because
a linked worktree runs the common directory's hooks with its own root as
cwd. Re-running `configure.sh` re-points the same two links and stacks
nothing.

`configure.sh` declines to install in three cases, each with a warning
rather than a failure: the checkout is not a git repository; `core.hooksPath`
points somewhere else (installing anyway would produce a hook git ignores,
reported as installed); or the canonical hook file is missing. An operator's
own pre-existing hook is moved to `<name>.backup-<timestamp>` beside itself
— `.git/hooks` is untracked, so an overwrite there is unrecoverable.

**Known gap:** `scripts/uninstall.sh` does not remove the hooks or the two
scrubber links. Its `LINK_NAMES` list has drifted behind `configure.sh` by
nine entries; see the INFRA-59 report.

| rule | tier | what it matches |
|---|---|---|
| `rfc1918-host` | BLOCK | an RFC1918 address with all four octets range-checked, excluding network and broadcast addresses |
| `home-path` | BLOCK | an absolute path naming an operator account |
| `session-id` | BLOCK | a session identifier token |
| `homelab-host` | ADVISORY | an internal hostname |

| exit | meaning |
|---|---|
| 0 | calibration passed, no blocking findings |
| 1 | blocking findings |
| 2 | **INCOMPLETE** — calibration failed, or the corpus could not be fully swept |
| 3 | usage error |

Three design decisions carry the whole tool, and each one is load-bearing:

**It diffs against a baseline; it does not scan absolutely.** Every finding
is classified `NEW` or `BASELINE` against a declared ref (default
`origin/main`), and only a `NEW` hit in a BLOCK-tier rule blocks. Run
absolutely, a scrubber reports the same already-published values on every
invocation and is muted within a week. `--audit` is the mode you reach for
deliberately, never the default.

**Classification is channel-consistent.** A finding in file content is judged
against the baseline's *files*; a finding in a commit message is judged
against files *and* message history. This is not pedantry — measured on this
repo, an earlier scrub removed the LAN address from tracked files and then
quoted it four times in its own commit message. Judging file content against
message history would have downgraded the exact literal that produced the
company's only BLOCK verdict. A file-channel hit that is new to the tree but
present in published history is still reported, with a note saying so.

**It calibrates before it sweeps, and every failure exits differently.**
Each run plants one positive control per enabled rule, sweeps them through
the same code path the real corpus takes, and refuses to report CLEAN unless
every plant was caught *and* a negative control of documented
false-positive baits stayed silent. A corpus that could not be fully
classified is `INCOMPLETE`, never `CLEAN`. This is a direct response to two
instruments that printed a clean bill of health over real disclosures in one
evening — an OCR arm that had never been calibrated, and a corpus classifier
that matched 1 file of 185 and reported zero of everything. An uncalibrated
scrubber is worse than no scrubber, because it turns "unmeasured" into
"verified clean".

**Scope.** This is the F1 arm only. Provenance and AI-thread vocabulary (F2)
is excluded permanently: that pattern set is itself a disclosure, so it stays
in the private sweep, and excluding it is what lets cc-scrub live in a public
repo at all. Register, typography and commit trailers (F3) are not
implemented — they are gated on two undecided policy questions. A CLEAN
verdict is a lower bound over mechanical tells; the tool prints that,
together with what it does not cover, on every run.

Not yet wired into any hook, and not symlinked into `~/.claude/` by
`configure.sh` — invoke it by path for now.

## cc-scrub-outbound — outbound PR/issue text (register + delegated F1)

`canonical/scripts/cc-scrub-outbound.sh` sweeps a **staged outbound
package** — the `.title` / `.body.md` / `.target` triple for a PR, issue or
comment — before any of it is posted. Outbound text is the third scrub
surface: tracked files were always covered, commit messages were added
under RESEARCH-1, and this is the one that leaks under the operator's own
account on somebody else's repository.

It reports both risk classes. The register and typography rules are this
tool's own; the four F1 disclosure rules are **delegated to `cc-scrub.sh`**
as a subprocess, so those range-checked patterns keep living in exactly one
file.

```bash
bash canonical/scripts/cc-scrub-outbound.sh <dir>          # a package directory
bash canonical/scripts/cc-scrub-outbound.sh a.title a.body.md   # explicit files
bash canonical/scripts/cc-scrub-outbound.sh --calibrate-only    # prove the instrument
bash canonical/scripts/cc-scrub-outbound.sh <dir> --report <f>  # TSV for a reviewing session
```

| rule | tier | what it matches |
|---|---|---|
| `em-dash` | BLOCK | U+2014 |
| `curly-quote` | BLOCK | U+2018 U+2019 U+201C U+201D |
| `session-id-bare` | BLOCK | a bare 22-hex session identifier |
| `ai-trailer` | BLOCK | an assistant co-author trailer or session URL |
| `nbsp` | ADVISORY | U+00A0 U+202F |
| `ellipsis` | ADVISORY | U+2026 |
| `en-dash` | ADVISORY | U+2013 flanked by spaces, standing in for an em dash |

Plus `rfc1918-host`, `home-path`, `session-id` and `homelab-host` from the
F1 arm, reported under their own names. Exit codes match cc-scrub's: `0`
clean, `1` blocking, `2` **INCOMPLETE**, `3` usage.

**Why a sibling tool and not a flag on cc-scrub.** cc-scrub parks the
register class on an undecided policy question and warns that shipping it
early "would block 81% of this repo's text files on a taste call".
Measured on this checkout: 86 files in this module alone carry an em-dash,
this README among them. The CEO ruling that made em-dashes blocking applies
to **outbound drafts only** and says nothing about repo prose. A separate
tool whose corpus is an outbound package cannot be pointed at the tracked
tree by accident; a mode flag could be, and `cc-scrub --audit` would start
failing on this file the day the rules landed inside it. The scope
restriction is structural, which is the only kind that survives.

**It calibrates itself and its delegate.** Seven plants, one per rule,
swept through the same code path the real corpus takes, against twelve
baits drawn from constructions a legitimate draft is supposed to use — the
ASCII hyphen, `--staged`, three ASCII dots, a 40-hex sha, a co-author
trailer naming a human. A delegate that is missing, or that fails its own
calibration, makes the whole run INCOMPLETE: an empty finding list from a
tool that never ran is not a clean F1 sweep.

**Patterns are UTF-8 byte sequences matched under `LC_ALL=C`.** `grep -P
'\x{2014}'` means the *character* U+2014 only while PCRE is in UTF mode,
which GNU grep enables from the locale; under a C locale the same pattern
means byte `0x14` and matches nothing. That failure is invisible and
locale-dependent, so the patterns are bytes and the locale is pinned.

**A package with no `.body.md` is INCOMPLETE, not clean.** The false zero
specific to this surface is sweeping the outbound folder, getting CLEAN,
and posting a body that was never in the folder. A stem carrying a
`.title` or a `.target` without a body is exactly that state. A body with
no target is fine — that is a comment draft, and a target is not posted
text. The gate applies to directory sweeps; an explicit file list is the
operator naming what they want swept.

**Scope.** Lexical AI-isms — register vocabulary and sentence-shape tells —
are deliberately **not** implemented, and every run says so. The F2
provenance vocabulary stays out of this public repo permanently on
cc-scrub's reasoning. The generic register vocabulary has no measured
precision here, and cc-scrub's own negative control already records review
verdicts against the obvious candidates: "comprehensive test coverage and
robust handling" and a plain "let me know if you want changes" are both
baits that must not fire. Shipping a word list now would be the tool
guessing at the operator's taste.

**Deliberately not wired into a git hook.** `configure.sh` symlinks it to
`~/.claude/cc-scrub-outbound` for convenience, but no hook calls it: its
corpus is a staged outbound *package* (`.title` / `.body.md` / `.target`),
which is not a git diff and not a commit range. There is no hook whose
corpus it could sweep. Invoke it by path, or by its deployed name, before
anything is posted — exit `0` is the only clearance.
