---
name: plane-api
description: Use when making API calls to the self-hosted Plane instance — creating, reading, updating, or deleting issues, managing cycles and modules, or querying project/state/cycle IDs.
---

# Plane API Guide

Self-hosted Plane at `http://192.168.1.82`. All requests require the auth header below.

## Before You Start

Check that your credentials are available:

```bash
echo $PLANE_API_KEY
```

If this prints nothing, run `source ~/.bashrc` before proceeding. Do **not** continue with an empty `PLANE_API_KEY` — all requests will be rejected.

**Sandboxed subshell warning:** Claude Code's Bash sandbox does not inherit exported environment variables. Even if `$PLANE_API_KEY` is set in your shell session, it will likely be empty inside tool calls. If any request returns `{"detail": "Authentication credentials were not provided."}`, the env var didn't make it through. Fix: read the key directly from `~/.bashrc` and pass it inline. Use this pattern — it tolerates quoted *or* unquoted values in `~/.bashrc`:

```bash
PLANE_API_KEY=$(grep -oP "(?<=^export PLANE_API_KEY=)['\"]?\K[^'\"]+" ~/.bashrc)
```

If you use a simpler pattern that assumes quotes (e.g. `(?<=PLANE_API_KEY=')[^']*`) and the value is unquoted, it will silently return empty and every subsequent request will fail with auth errors.

**Network access from the sandbox:** The sandbox sets `no_proxy` to include `192.168.0.0/16`, which bypasses the sandbox proxy for LAN addresses. Direct connections to LAN IPs are then blocked by the sandbox firewall — `curl` returns `Failed to connect to 192.168.1.82 port 80: Network is unreachable`. To reach Plane (or any LAN service) from within the sandbox, override `no_proxy` on every call:

```bash
no_proxy="" NO_PROXY="" curl -s -H "X-Api-Key: $PLANE_API_KEY" \
  "http://192.168.1.82/api/v1/workspaces/homelab/projects/"
```

**Combined first-call template** — copy-paste this for the very first request of a session, since it handles both the auth and network gotchas at once:

```bash
PLANE_API_KEY=$(grep -oP "(?<=^export PLANE_API_KEY=)['\"]?\K[^'\"]+" ~/.bashrc)
no_proxy="" NO_PROXY="" curl -s -H "X-Api-Key: $PLANE_API_KEY" \
  "http://192.168.1.82/api/v1/workspaces/homelab/projects/"
```

---

## Authentication

```
X-Api-Key: $PLANE_API_KEY
```

Base URL pattern: `http://192.168.1.82/api/v1/workspaces/{workspace_slug}/`

Known workspace slugs: `homelab`, `umd`

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
- `identifier` → short code (e.g. `ENPM701`)

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

## Known Workspaces

| Slug | Purpose |
|---|---|
| `homelab` | Home lab infrastructure (Plane Stack, AI Stack, Media Stack, Monitoring, Infrastructure) |
| `umd` | University coursework (ENPM 701 Grand Challenge, ENPM 673 Final Project) |

## Known Projects (umd workspace)

Avoid a lookup round-trip by using these IDs directly:

| Identifier | Name | Project ID |
|---|---|---|
| `GC701` | ENPM 701 Grand Challenge | `0f180c25-7635-4f1c-b0ab-295027f82439` |
| `ENPM701` | ENPM 701 Final Project | `16cf8028-0496-41a2-bc81-a6fca87eacad` |
| `ENPM673` | ENPM 673 Final Project (Visual Odometry) | `3f2f1379-f6e7-4088-bcf6-0e3e1e9b2ece` |
