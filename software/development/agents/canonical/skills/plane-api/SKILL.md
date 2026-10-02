---
name: plane-api
description: Use when making API calls to the self-hosted Plane instance — creating, reading, updating, or deleting issues, managing cycles and modules, or querying project/state/cycle IDs.
---

# Plane API Guide

Self-hosted Plane at `http://plane.homelab`. Always use the hostname — it
survives a VM IP change. All requests require the auth header below.

## Before You Start

**Probe the key, don't assume its location.** Check the environment first:
`[ -n "$PLANE_API_KEY" ] && echo set` — as of 2026-09-03 (verified, EA probe)
the `env` block from `~/.claude/settings.local.json` IS injected into the Bash
tool's shell, so the variable is usually already set. Only if the probe says
otherwise, read it from the JSON (its canonical home, provisioned by the
`environment-secrets` repo's `install.sh`):

```bash
PLANE_API_KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/settings.local.json')))['env']['PLANE_API_KEY'])")
```

If that errors with `KeyError` or `FileNotFoundError`, the secrets install has not
run on this machine — clone `environment-secrets` and run its `install.sh`. Do
**not** continue with an empty key; every request returns
`{"detail": "Authentication credentials were not provided."}` (HTTP 401).

**Network access — probe before working around anything:**
`curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://plane.homelab/` — as of
2026-09-03 (verified, EA probe) a plain curl from an unsandboxed session
returns 200 with no overrides. Only if that probe fails with
`Network is unreachable` (seen historically in sandboxed sessions where
`no_proxy` includes the private LAN ranges and the sandbox firewall blocks direct
LAN connections) apply the override:

```bash
no_proxy="" NO_PROXY="" curl -s -H "X-Api-Key: $PLANE_API_KEY" \
  "http://plane.homelab/api/v1/workspaces/homelab/projects/"
```

**Combined first-call template** — copy-paste this for the very first request of a session, since it handles both the auth and network gotchas at once:

```bash
PLANE_API_KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/settings.local.json')))['env']['PLANE_API_KEY'])")
no_proxy="" NO_PROXY="" curl -s -H "X-Api-Key: $PLANE_API_KEY" \
  "http://plane.homelab/api/v1/workspaces/homelab/projects/"
```

---

## Authentication

```
X-Api-Key: $PLANE_API_KEY
```

Base URL pattern: `http://plane.homelab/api/v1/workspaces/{workspace_slug}/`

Default workspace slug: `homelab`. The API key cannot list workspaces; other
slugs are recorded in the operator's vault, not here.

---

## Discovery

Always resolve names to IDs before operating. Run the relevant lookup first, extract the ID you need, then proceed with the operation.

### List projects

```
GET /api/v1/workspaces/{workspace_slug}/projects/
```

**Response envelope:** All list endpoints wrap results in a paginated envelope — iterate `response["results"]`, not the response directly:

```json
{
  "results": [ { "id": "...", "name": "...", "identifier": "..." }, ... ],
  "total_count": 5,
  "next_cursor": "...",
  "next_page_results": false
}
```

Key response fields per result:
- `id` → `project_id` (required in all subsequent project-scoped calls)
- `name` → human-readable name
- `identifier` → short code (e.g. `INFRA`)

Resolve an identifier to its `project_id` (project IDs are not recorded in this
skill; they change when a project is recreated):

```bash
curl -s -H "X-Api-Key: $PLANE_API_KEY" \
  "http://plane.homelab/api/v1/workspaces/homelab/projects/" \
  | python3 -c "import json,sys;[print(p['identifier'],p['id'],p['name'],sep='\t') for p in json.load(sys.stdin)['results']]"
```

Archived projects are left out of this list; add `?include_archived=true` to see them.

### List states

```
GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/states/
```

Key response fields per result:
- `id` → `state_id` (use when creating or updating issues)
- `name` → e.g. `Todo`, `In Progress`, `Done`
- `group` → `backlog | unstarted | started | completed | cancelled`

### List cycles

```
GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/cycles/
```

Key response fields per result:
- `id` → `cycle_id`
- `name` → e.g. `Sprint 1`
- `start_date`, `end_date` → ISO 8601

### List modules

```
GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/modules/
```

Key response fields per result:
- `id` → `module_id`
- `name` → e.g. `Phase 1: Hardware & Setup`
- `status` → `backlog | planned | in-progress | paused | completed`

---

## Issues

### List / filter

```
GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/issues/
```

Useful query parameters:
- `state=<state_id>` — filter to a single state
- `priority=urgent|high|medium|low|none`
- `per_page=N` — default 100
- `cursor=<next_cursor>` — paginate using `next_cursor` from the previous response

Key response fields per result:
- `id` → `issue_id`
- `name` → title
- `state` → current `state_id`
- `priority`
- `completed_at` → non-null means the issue is done
- `next_page_results` → `true` if more pages exist (top-level field)

To list issues across all projects in a workspace:
```
GET /api/v1/workspaces/{workspace_slug}/issues/
```

### Create

```
POST /api/v1/workspaces/{workspace_slug}/projects/{project_id}/issues/

{
  "name": "<required>",
  "state": "<state_id>",
  "priority": "urgent|high|medium|low|none",
  "start_date": "YYYY-MM-DD",
  "target_date": "YYYY-MM-DD",
  "description_html": "<p>...</p>",
  "parent": "<issue_id>",
  "assignees": ["<user_id>"],
  "labels": ["<label_id>"]
}
```

Only `name` is required. Returns the created issue object.

### Update

```
PATCH /api/v1/workspaces/{workspace_slug}/projects/{project_id}/issues/{issue_id}/

{ <any subset of create fields> }
```

Most common use — advance an issue's state:
```
{ "state": "<state_id>" }
```

### Delete

```
DELETE /api/v1/workspaces/{workspace_slug}/projects/{project_id}/issues/{issue_id}/
```

Returns 204 No Content on success.

---

## Workflow Management

### Add issue to a cycle

```
POST /api/v1/workspaces/{workspace_slug}/projects/{project_id}/cycles/{cycle_id}/cycle-issues/

{ "issues": ["<issue_id>"], "project_id": "<project_id>" }
```

⚠ `project_id` is required in the request body even though it appears in the URL. Omitting it returns `{"error": "Work items are required", "code": "MISSING_WORK_ITEMS"}`.

The response is a list of cycle-issue wrapper objects. Their `id` fields are internal — do not use them for DELETE.

### Remove issue from a cycle

```
DELETE /api/v1/workspaces/{workspace_slug}/projects/{project_id}/cycles/{cycle_id}/cycle-issues/{issue_id}/
```

⚠ Use the **issue's** `id`, not the cycle-issue wrapper `id` returned by the POST above.

### Add issue to a module

```
POST /api/v1/workspaces/{workspace_slug}/projects/{project_id}/modules/{module_id}/module-issues/

{ "issues": ["<issue_id>"] }
```

The response is a list of module-issue wrapper objects. Their `id` fields are internal — do not use them for DELETE.

### Remove issue from a module

```
DELETE /api/v1/workspaces/{workspace_slug}/projects/{project_id}/modules/{module_id}/module-issues/{issue_id}/
```

⚠ Use the **issue's** `id`, not the module-issue wrapper `id` returned by the POST above.

---

## Error Patterns

| Response | Cause |
|---|---|
| `{"name": ["This field is required."]}` | Issue create missing `name` |
| `{"error": "Work items are required", "code": "MISSING_WORK_ITEMS"}` | Cycle add missing `project_id` in body |
| `{"error": "The requested resource does not exist."}` | Bad ID in URL, or used wrapper id instead of issue_id for remove |
| `{"error": "The payload is not valid"}` | Wrong field name in request body |

---

## Operational Notes

- **Calls fail after earlier calls in the same session succeeded** (HTTP `000`, timeouts): check the network path before the Plane stack, and don't churn on `no_proxy`/auth workarounds. `nc -zv plane.homelab 80` succeeding while HTTP times out points at something on the path dropping the session, not at Plane. This applies only to that mid-session pattern; it is not a reason to assume Plane is unreachable up front. The site-specific diagnosis is in the operator's vault memory (`reference_plane_api`).
- **Archive endpoint:** `POST /api/v1/workspaces/{slug}/projects/{id}/archive/` returns 204 on success. Sometimes returns 404 on the response despite the archive completing — verify with a follow-up list query using `?include_archived=true`.
- **Delete endpoint:** `DELETE /api/v1/workspaces/{slug}/projects/{id}/` returns 204 on success.
