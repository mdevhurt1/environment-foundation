# Agent instructions (Claude Code, Codex, Pi, Antigravity CLI)

One operator (Marcus), one machine. This is the only global instruction file. Project files named AGENTS.md or CLAUDE.md add to it.

## Memory
- At session start read ~/vault/20-surface/claude-memory/MEMORY.md (one line per memory). Before re-deriving or re-asking anything a line names, read that memory file.
- When you learn something durable and cross-task (a preference, a correction, a homelab fact, a gotcha), write ~/vault/20-surface/claude-memory/<type>_<slug>.md with frontmatter `name`, `description`, and `metadata.type` (user | feedback | project | reference), then append one line to MEMORY.md: `- [[<type>_<slug>]] — <hook>`. Links use the filename stem.
- Do not save what a repo, git history, or this file already records.

## Vault (~/vault, Obsidian)
- Read anywhere. Write only under ~/vault/20-surface/. Never write ~/vault/00-core, ~/vault/10-middle, or ~/vault/40-journal; no approval path exists.
- Task notes go under ~/vault/20-surface/company/tasks/<task_id>/, where task_id is the Plane issue (e.g. AI_ST-12) or a short slug.

## Homelab and SSH
- Read-only SSH recon is allowed anytime: status, logs, configs, `pvesh get`, `free`, `docker ps`. Address hosts as <name>.homelab. Proxmox nodes: pve1, pve2, pve3.
- Anything that changes state on a remote host: hand Marcus the exact command to run himself, unless he explicitly authorizes you to run that specific command.
- Plane (plane.homelab) is the task record; the key is $PLANE_API_KEY. Gitea is git-docs.homelab:3000; the key is $GITEA_API_KEY. Never push, merge, deploy, purchase, or send messages without an explicit ask.

## Git
- Work on a branch, never commit to main directly. Commit only when asked. For isolation: `git worktree add ../<repo>-<branch> -b <branch>`.
- Never bare `git stash`; use `git stash push -u -m <tag>` and `git stash apply <sha>`.
- Never commit secrets. They live in ~/environment-secrets (sops + age) and reach shells through ~/.config/agents/env.

## Working style
- Verify before claiming done: run the command and show its output. If something was not run, say so.
- Ask only when different readings lead to materially different work; otherwise state the assumption and proceed.
- Smallest change that solves the problem. During the freeze in ~/environment-foundation/FREEZE.md, add no harness tooling, hooks, or skills; log friction in ~/vault/20-surface/inbox/harness-friction.md instead.
