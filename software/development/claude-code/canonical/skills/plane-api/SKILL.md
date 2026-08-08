---
name: plane-api
description: Use when making API calls to the self-hosted Plane instance — creating, reading, updating, or deleting issues, managing cycles and modules, or querying project/state/cycle IDs.
---

# Plane API Guide

Self-hosted Plane at `http://plane.homelab` (currently `192.168.1.82`). Always use the
hostname — it survives a VM IP change. All requests require the auth header below.

## Before You Start

**The API key is NOT an environment variable.** It lives in
`~/.claude/settings.local.json` under `.env.PLANE_API_KEY`, provisioned by the
`environment-secrets` repo's `install.sh`. Claude Code does **not** inject that
`env` block into the Bash tool's shell, so `$PLANE_API_KEY` is empty inside every
tool call — and it is **not** in `~/.bashrc` or `~/.zshrc` either. Do not `echo
$PLANE_API_KEY` and conclude the key is missing; read it from the JSON:

```bash
PLANE_API_KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/settings.local.json')))['env']['PLANE_API_KEY'])")
```

If that errors with `KeyError` or `FileNotFoundError`, the secrets install has not
run on this machine — clone `environment-secrets` and run its `install.sh`. Do
**not** continue with an empty key; every request returns
`{"detail": "Authentication credentials were not provided."}` (HTTP 401).

**Network access from the sandbox:** The sandbox sets `no_proxy` to include
`192.168.0.0/16`, which bypasses the sandbox proxy for LAN addresses. Direct
connections to LAN addresses are then blocked by the sandbox firewall — `curl`
returns `Failed to connect ... Network is unreachable`. To reach Plane (or any LAN
service) from within the sandbox, override `no_proxy` on every call:

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
| `homelab` | Home lab infrastructure (Plane Stack, AI Stack, Media Stack, Monitoring, Infrastructure, Research Queue) |
| `umd` | University coursework (Spring 2026 cohort fully archived 2026-05-19; reserved for future terms) |

## Known Projects (homelab workspace)

| Identifier | Name | Project ID |
|---|---|---|
| `PLANE` | Plane Stack | `870b6c1b-983a-4dae-b0e5-20474fe928ad` |
| `INFRA` | Infrastructure | `9c19f93e-3d33-4e2d-8a39-e76cf983caf3` |
| `MEDIA` | Media Stack | `b5fdad68-311f-4bba-b50a-8cc938e43249` |
| `AI_ST` | AI Stack | `06588b14-1056-4369-b2a8-a5d27f624265` |
| `MONIT` | Monitoring | `e056f3d9-a6a6-40ef-948c-09909b6a1fa6` |
| `RESEARCH` | Research Queue | `70bcb81f-1336-44bb-a78a-79e890445c82` |

## Archived Projects

The umd workspace is empty as of 2026-05-19 (Spring 2026 coursework complete). For reference if those archives are unarchived:

| Identifier | Name | Project ID | Archived |
|---|---|---|---|
| `ENPM701` | ENPM 701 Grand Challenge (held all ENPM701 work including Phase 5/6 final-project issues #14–#26) | `0f180c25-7635-4f1c-b0ab-295027f82439` | 2026-05-19 |
| `ENPM673` | ENPM 673 Final Project (Visual Odometry) | `3f2f1379-f6e7-4088-bcf6-0e3e1e9b2ece` | 2026-05-19 |

## Operational Notes

- **Intermittent failures vs sandbox/auth issues:** If HTTP requests return `000` / timeouts after earlier requests succeeded in the same session, the most likely cause is **the UDM SE IPS/Threat Management dropping the inter-VLAN HTTP session** — not a Plane stack outage. The workstation is on `192.168.2.0/24` and Plane on `192.168.1.0/24`, so traffic traverses the UDM and IPS signatures occasionally flag legitimate API payloads (UUID paths, large JSON, bearer tokens). Diagnose:
  1. `nc -zv 192.168.1.82 80` — if TCP succeeds but HTTP times out, it's a session-level drop (IPS smoking gun).
  2. Check the UDM threat log (UniFi controller → Insights → Threats, or Settings → Security → Threat Management → History) for events involving `192.168.1.82` around the failure time.
  3. Only then suspect the Plane stack. VM 107 has very generous resource headroom (~5.8 GB RAM, 11 containers using <2 GB combined) — actual stack-internal outages are rare.
  Don't churn on `no_proxy`/auth workarounds when the symptom is a sudden cliff after working calls. See cross-task memory `project_udm_ips_blocks_lan_api.md` (2026-05-19 root-cause investigation).
- **Archive endpoint:** `POST /api/v1/workspaces/{slug}/projects/{id}/archive/` returns 204 on success. Sometimes returns 404 on the response despite the archive completing — verify with a follow-up list query using `?include_archived=true`.
- **Delete endpoint:** `DELETE /api/v1/workspaces/{slug}/projects/{id}/` returns 204 on success.
