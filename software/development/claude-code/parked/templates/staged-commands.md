<!-- ===================================================================
     Canonical staged-command host-guard template (AI_ST-100).
     The EA fills every {{placeholder}} AT STAGING TIME — the hostname
     from a probe on the machine the commands must run on, each hash
     from a sha256sum run against the exact file the commands will ship
     — and DELETES all <!-- EA: ... --> comment lines before handing
     the block over. The CEO receives plain shell, not scaffolding.
     Same rule as dispatch-brief.md, applied at staging instead of
     dispatch: NO copied environment constants. A hostname or hash here
     is the output of a probe run at staging time, never a value
     remembered, reused from a prior staging, or copied from a brief.
     ==================================================================== -->

# Staged-command host guard — preamble for `!` mutation commands

**When this applies:** every time shell commands are staged for a human
to run via the `!` prefix (or by paste) and those commands (a) mutate
state — deploy, restart, overwrite, delete — or (b) copy files across
machines. Read-only command sequences need no guard.

**Why (dated incident):** on 2026-09-11 (AI_ST-100, during the MONIT-17
deploy) staged `!` commands were run from the desktop instead of the
laptop hosting the session. The desktop's stale checkout was scp'd to
production, silently reverting live config, and a later re-run without a
fresh copy left a service crash-looping with the alert channel down.
Every command exited 0. The `!` convention assumes the human's terminal
shares the session's machine and file state; nothing verifies this, and
identical shells and identical paths on multiple machines make a
wrong-host run silent and destructive. The guard makes it loud instead.

## The guard block

Prepend this to the staged sequence, filled at staging time:

```bash
# -- host guard (staged {{YYYY-MM-DD}} by session {{session_id}}) --
[ "$(hostname)" = "{{expected_hostname}}" ] || { echo WRONG-MACHINE; exit 1; }
echo "{{sha256_recorded_at_staging}}  {{source_file}}" | sha256sum -c - \
  || { echo STALE-OR-WRONG-FILE; exit 1; }
```

<!-- EA: one `echo ... | sha256sum -c -` line PER source file the
     sequence ships. The two spaces between hash and path are load-
     bearing — sha256sum's checklist format requires them. -->

Rules that make the guard worth having:

- **The hash is probed, not recalled.** At staging time, run
  `sha256sum <file>` against the working tree the commands are meant to
  ship, and paste that output into the guard. A hash reused from an
  earlier staging pins the wrong state — which is the incident again,
  one level up.
- **The guard and the mutations travel as one block**, `&&`-chained or
  in one script, so nothing mutates when the guard fails. A guard the
  human can skip by running the third command first is decoration.
- **Re-stage when the source changes.** If the file is edited after
  staging, the recorded hash is stale and the guard will (correctly)
  refuse; re-hash and re-issue the block rather than telling the human
  to ignore it. A guard failure is never to be overridden by hand —
  WRONG-MACHINE or STALE-OR-WRONG-FILE means stop and re-stage.
- **Cross-machine copy steps echo checksums on both ends**, so the
  transfer verifies content, not just exit status:

```bash
sha256sum {{source_file}}                          # sending end
scp {{source_file}} {{user}}@{{target_host}}:{{dest_path}}
ssh {{user}}@{{target_host}} sha256sum {{dest_path}}   # receiving end — must match the line above
```

## Worked example

Filled block as the CEO would receive it (every value below was probed
at staging time on 2026-09-11 — the hostname from `hostname` on the
session's machine, the hash from `sha256sum` on the file being shipped;
they are examples of *shape*, not constants to copy):

```bash
# -- host guard (staged 2026-09-11 by session 5501a0e855b1) --
[ "$(hostname)" = "ea-laptop" ] || { echo WRONG-MACHINE; exit 1; }
echo "9f2c1a7e0b4d8c6f3a5e2d1b0c9f8e7d6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d  $HOME/homelab/ai-coworker-stack/docker-compose.yml" | sha256sum -c - \
  || { echo STALE-OR-WRONG-FILE; exit 1; }

sha256sum ~/homelab/ai-coworker-stack/docker-compose.yml
scp ~/homelab/ai-coworker-stack/docker-compose.yml deploy@stack-vm:/opt/stack/docker-compose.yml
ssh deploy@stack-vm sha256sum /opt/stack/docker-compose.yml
ssh deploy@stack-vm 'cd /opt/stack && docker compose up -d --force-recreate n8n signal-cli'
```

The failure this converts: run from the wrong machine, line 1 prints
`WRONG-MACHINE` and nothing mutates. Run from the right machine with a
stale file, line 2 prints `STALE-OR-WRONG-FILE` and nothing mutates.
Both were silent exit-0 successes in the incident this template exists
to prevent.
