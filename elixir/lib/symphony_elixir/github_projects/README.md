# GitHub Projects tracker

This directory contains the GitHub Projects (v2) implementation of the
`SymphonyElixir.Tracker` behaviour. It is the GitHub-flavoured counterpart to
`../linear/` and lets the Symphony orchestrator drive Codex against issues on
a GitHub Project board instead of a Linear team.

## What's in here

| File             | Responsibility                                                                                                                                  |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `project_url.ex` | Parses `https://github.com/{orgs,users}/<login>/projects/<n>` URLs (with optional `/views/...` suffix) into `{:org \| :user, login, number}`.   |
| `issue.ex`       | GitHub-flavoured issue struct plus `to_tracker_issue/1`, which converts it to a `SymphonyElixir.Linear.Issue` so downstream code stays uniform. |
| `cache.ex`       | `:persistent_term`-backed cache for the resolved project id, `Status` field id, status option map, and per-issue project item ids.              |
| `client.ex`      | GraphQL client against `api.github.com/graphql`: pagination, status filtering, viewer (`me`) resolution, comment + status mutations.            |
| `adapter.ex`     | Implements `SymphonyElixir.Tracker` – fetches candidate / specific issues, posts comments, updates the `Status` single-select field.            |

The adapter is selected automatically when a workflow's front-matter sets
`tracker.kind: github_projects` (see `lib/symphony_elixir/tracker.ex`).

## Using the bundled `WORKFLOW_github.md`

A ready-to-use example workflow lives at `elixir/WORKFLOW_github.md`. To run
Symphony against a GitHub Project using it:

1. **Create a fine-grained PAT** with at least:
   - `repo` (read/write on the repos Symphony will touch),
   - `project` (read/write on the target Project v2).

2. **Export the env vars** the workflow references:

   ```bash
   export GITHUB_TOKEN="ghp_xxx"                                  # required
   export GITHUB_PROJECT_URL="https://github.com/orgs/your-org/projects/3"
   export GITHUB_ASSIGNEE="me"                                    # optional; "me" = viewer
   ```

   `GITHUB_PAT` is accepted as a fallback for `GITHUB_TOKEN`. Both org-level
   (`/orgs/<login>/projects/<n>`) and user-level (`/users/<login>/projects/<n>`)
   URLs are supported.

3. **Configure the Project's `Status` field.** The workflow expects a
   single-select field named `Status` (override with `tracker.status_field_name`
   in the YAML if yours differs) with options matching the `active_states` and
   `terminal_states` lists. The default `WORKFLOW_github.md` uses:

   - active: `Todo`, `In Progress`, `Merging`, `Rework`
   - terminal: `Done`, `Cancelled`

   Option names are matched case-insensitively.

4. **Point Symphony at the file** when starting the orchestrator:

   ```bash
   cd elixir
   export SYMPHONY_WORKFLOW_PATH="$(pwd)/WORKFLOW_github.md"
   mise exec -- mix run --no-halt
   ```

   `SYMPHONY_WORKFLOW_PATH` defaults to `./WORKFLOW.md`, so either set it
   explicitly or rename/symlink `WORKFLOW_github.md` to `WORKFLOW.md`.

5. **(Optional) Override values inline.** Anything in the YAML beats the env
   fallbacks – replace `$GITHUB_TOKEN` with a literal value (not recommended)
   or pin a specific board:

   ```yaml
   tracker:
     kind: github_projects
     api_key: $GITHUB_TOKEN
     project_url: https://github.com/orgs/your-org/projects/3
     status_field_name: Status
     active_states: [Todo, "In Progress"]
     terminal_states: [Done]
   ```

## How polling and mutations work

- On every poll, `Client.fetch_candidate_issues/0` walks the Project's items
  page-by-page, joins each item's content with its `Status` field value, and
  keeps only items whose status matches an `active_state`. As a side effect it
  populates `Cache` with `project_id`, `status_field_id`, the option map, and
  the issue→`projectV2Item` id mapping so subsequent mutations don't need to
  re-query.
- `Adapter.create_comment/2` posts a regular issue comment via `addComment`.
- `Adapter.update_issue_state/2` looks up the cached item id + option id and
  calls `updateProjectV2ItemFieldValue`. If the cache is cold (e.g. after a
  restart before the first poll), it triggers a fetch to warm it.
- All GitHub items are converted to `SymphonyElixir.Linear.Issue` at the
  boundary, so the orchestrator, agent runner, and Memory tracker work
  unchanged. GitHub-only metadata (`project_item_id`,
  `repository_name_with_owner`) lives on `GithubProjects.Issue`.

## Testing

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/github_projects_test.exs
mise exec -- mix test --cover   # full suite + 100% coverage gate
```

The test file injects a stub HTTP function via the
`:symphony_elixir, :github_projects_request_fun` application env, so end-to-end
fetch + mutation flows are exercised without touching the network.
