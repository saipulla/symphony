defmodule SymphonyElixir.GithubProjects.Client do
  @moduledoc """
  GitHub Projects (v2) GraphQL client.

  Mirrors `SymphonyElixir.Linear.Client` in shape and intent: polls a single
  Project for candidate issues, normalizes them into `SymphonyElixir.Linear.Issue`
  structs, and exposes a `graphql/2,3` escape hatch used by mutations and
  client-side tools.

  Project items are filtered to those whose single-select Status field matches
  the configured `active_states` list (case-insensitive). The assignee filter,
  if set, is matched against issue assignee logins (or the literal `"me"`,
  resolved against the authenticated viewer).
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GithubProjects.{Cache, Issue, ProjectUrl}
  alias SymphonyElixir.Linear.Issue, as: TrackerIssue

  @items_page_size 50
  @max_error_body_log_bytes 1_000
  @default_status_field_name "Status"

  @org_project_query """
  query SymphonyGithubProjectIdOrg($login: String!, $number: Int!, $fieldName: String!) {
    organization(login: $login) {
      projectV2(number: $number) {
        id
        field(name: $fieldName) {
          ... on ProjectV2SingleSelectField {
            id
            name
            options { id name }
          }
        }
      }
    }
  }
  """

  @user_project_query """
  query SymphonyGithubProjectIdUser($login: String!, $number: Int!, $fieldName: String!) {
    user(login: $login) {
      projectV2(number: $number) {
        id
        field(name: $fieldName) {
          ... on ProjectV2SingleSelectField {
            id
            name
            options { id name }
          }
        }
      }
    }
  }
  """

  # Single-page query parameterized at runtime per project.
  @items_query """
  query SymphonyGithubProjectItems($projectId: ID!, $first: Int!, $after: String) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: $first, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            fieldValues(first: 30) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2SingleSelectField { id name } }
                }
              }
            }
            content {
              __typename
              ... on Issue {
                id
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                repository { nameWithOwner }
                assignees(first: 10) { nodes { id login } }
                labels(first: 20) { nodes { name } }
                trackedInIssues(first: 20) { nodes { id number state url repository { nameWithOwner } } }
              }
            }
          }
        }
      }
    }
  }
  """

  @issues_by_ids_query """
  query SymphonyGithubIssuesByIds($ids: [ID!]!) {
    nodes(ids: $ids) {
      __typename
      ... on Issue {
        id
        number
        title
        body
        url
        state
        createdAt
        updatedAt
        repository { nameWithOwner }
        assignees(first: 10) { nodes { id login } }
        labels(first: 20) { nodes { name } }
        trackedInIssues(first: 20) { nodes { id number state url repository { nameWithOwner } } }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyGithubViewer {
    viewer { id login }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- require_credentials(tracker),
         {:ok, project} <- ProjectUrl.parse(tracker.project_url),
         {:ok, meta} <- resolve_project_meta(project, status_field_name(tracker)),
         :ok <- Cache.put_project_meta(meta),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, items} <- fetch_all_project_items(meta.project_id),
         {:ok, issues} <- normalize_items(items, meta, assignee_filter, tracker.active_states) do
      {:ok, Enum.map(issues, &Issue.to_tracker_issue/1)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- require_credentials(tracker),
           {:ok, project} <- ProjectUrl.parse(tracker.project_url),
           {:ok, meta} <- resolve_project_meta(project, status_field_name(tracker)),
           :ok <- Cache.put_project_meta(meta),
           {:ok, items} <- fetch_all_project_items(meta.project_id),
           {:ok, issues} <- normalize_items(items, meta, nil, normalized_states) do
        {:ok, Enum.map(issues, &Issue.to_tracker_issue/1)}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, body} <- graphql(@issues_by_ids_query, %{ids: ids}),
             {:ok, issues} <- normalize_issue_nodes(body, assignee_filter) do
          {:ok, issues |> sort_by_requested(ids) |> Enum.map(&Issue.to_tracker_issue/1)}
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, response} <- send_request(request_fun, payload, headers),
         {:ok, body} <- handle_response(payload, response) do
      {:ok, body}
    end
  end

  defp send_request(request_fun, payload, headers) do
    case request_fun.(payload, headers) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp handle_response(_payload, %{status: 200, body: body}) do
    case body do
      %{"errors" => errors} when is_list(errors) and errors != [] -> {:error, {:github_graphql_errors, errors}}
      _ -> {:ok, body}
    end
  end

  defp handle_response(payload, %{status: status} = response) do
    Logger.error("GitHub GraphQL request failed status=#{status}" <> github_error_context(payload, response))
    {:error, {:github_api_status, status}}
  end

  @doc false
  @spec normalize_item_for_test(map(), Cache.project_meta(), String.t() | nil) :: Issue.t() | nil
  def normalize_item_for_test(item, meta, assignee \\ nil) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            _ -> nil
          end

        _ ->
          nil
      end

    normalize_item(item, meta, assignee_filter)
  end

  defp require_credentials(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_github_api_token}
      is_nil(tracker.project_url) -> {:error, :missing_github_project_url}
      true -> :ok
    end
  end

  defp status_field_name(tracker) do
    case Map.get(tracker, :status_field_name) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_status_field_name
    end
  end

  defp resolve_project_meta(project, field_name) do
    case Cache.project_meta() do
      %{project_id: _} = meta -> {:ok, meta}
      _ -> fetch_project_meta(project, field_name)
    end
  end

  defp fetch_project_meta(%{owner_kind: kind, login: login, number: number}, field_name) do
    {query, owner_key} =
      case kind do
        :organization -> {@org_project_query, "organization"}
        :user -> {@user_project_query, "user"}
      end

    with {:ok, body} <- graphql(query, %{login: login, number: number, fieldName: field_name}) do
      case get_in(body, ["data", owner_key, "projectV2"]) do
        %{"id" => project_id, "field" => %{"id" => field_id, "options" => options}} when is_binary(project_id) and is_binary(field_id) ->
          {:ok,
           %{
             project_id: project_id,
             status_field_id: field_id,
             status_options: options_by_name(options)
           }}

        %{"id" => project_id} when is_binary(project_id) ->
          {:error, {:github_status_field_missing, field_name}}

        _ ->
          {:error, :github_project_not_found}
      end
    end
  end

  defp options_by_name(options) when is_list(options) do
    Enum.reduce(options, %{}, fn
      %{"id" => option_id, "name" => name}, acc when is_binary(option_id) and is_binary(name) ->
        Map.put(acc, normalize_state(name), option_id)

      _, acc ->
        acc
    end)
  end

  defp options_by_name(_), do: %{}

  defp fetch_all_project_items(project_id) do
    fetch_items_page(project_id, nil, [])
  end

  defp fetch_items_page(project_id, after_cursor, acc) do
    case graphql(@items_query, %{projectId: project_id, first: @items_page_size, after: after_cursor}) do
      {:ok, body} ->
        case get_in(body, ["data", "node", "items"]) do
          %{"nodes" => nodes, "pageInfo" => page_info} when is_list(nodes) ->
            updated = Enum.reverse(nodes, acc)

            case next_cursor(page_info) do
              {:ok, cursor} -> fetch_items_page(project_id, cursor, updated)
              :done -> {:ok, Enum.reverse(updated)}
              {:error, reason} -> {:error, reason}
            end

          _ ->
            {:error, :github_unknown_payload}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor}) when is_binary(cursor) and cursor != "",
    do: {:ok, cursor}

  defp next_cursor(%{"hasNextPage" => true}), do: {:error, :github_missing_end_cursor}
  defp next_cursor(_), do: :done

  defp normalize_items(items, meta, assignee_filter, allowed_states) do
    allowed = MapSet.new(Enum.map(allowed_states, &normalize_state/1))

    issues =
      items
      |> Enum.map(&normalize_item(&1, meta, assignee_filter))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn %Issue{state: state} -> state && MapSet.member?(allowed, normalize_state(state)) end)

    Enum.each(issues, fn %Issue{id: id, project_item_id: item_id} ->
      if is_binary(id) and is_binary(item_id), do: Cache.put_item_id(id, item_id)
    end)

    {:ok, issues}
  end

  defp normalize_item(%{"content" => %{"__typename" => "Issue"} = content} = item, meta, assignee_filter) do
    project_item_id = item["id"]
    status = extract_status(item["fieldValues"], meta.status_field_id)
    assignees = get_in(content, ["assignees", "nodes"]) || []
    primary_assignee = List.first(assignees) || %{}

    %Issue{
      id: content["id"],
      identifier: identifier_for(content),
      title: content["title"],
      description: content["body"],
      priority: nil,
      state: status,
      branch_name: nil,
      url: content["url"],
      assignee_id: primary_assignee["login"] || primary_assignee["id"],
      project_item_id: project_item_id,
      repository_name_with_owner: get_in(content, ["repository", "nameWithOwner"]),
      blocked_by: extract_blockers(content),
      labels: extract_labels(content),
      assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
      created_at: parse_datetime(content["createdAt"]),
      updated_at: parse_datetime(content["updatedAt"])
    }
  end

  defp normalize_item(_item, _meta, _assignee_filter), do: nil

  defp normalize_issue_nodes(%{"data" => %{"nodes" => nodes}}, assignee_filter) when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(fn
        %{"__typename" => "Issue"} = content ->
          assignees = get_in(content, ["assignees", "nodes"]) || []
          primary_assignee = List.first(assignees) || %{}

          %Issue{
            id: content["id"],
            identifier: identifier_for(content),
            title: content["title"],
            description: content["body"],
            priority: nil,
            state: content["state"],
            branch_name: nil,
            url: content["url"],
            assignee_id: primary_assignee["login"] || primary_assignee["id"],
            project_item_id: Cache.item_id(content["id"]),
            repository_name_with_owner: get_in(content, ["repository", "nameWithOwner"]),
            blocked_by: extract_blockers(content),
            labels: extract_labels(content),
            assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
            created_at: parse_datetime(content["createdAt"]),
            updated_at: parse_datetime(content["updatedAt"])
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp normalize_issue_nodes(_other, _assignee_filter), do: {:error, :github_unknown_payload}

  defp sort_by_requested(issues, ids) do
    order = ids |> Enum.with_index() |> Map.new()
    fallback = map_size(order)
    Enum.sort_by(issues, fn %Issue{id: id} -> Map.get(order, id, fallback) end)
  end

  defp identifier_for(%{"repository" => %{"nameWithOwner" => repo}, "number" => number})
       when is_binary(repo) and is_integer(number) do
    repo <> "#" <> Integer.to_string(number)
  end

  defp identifier_for(%{"number" => number}) when is_integer(number), do: "#" <> Integer.to_string(number)
  defp identifier_for(_), do: nil

  defp extract_status(%{"nodes" => nodes}, status_field_id) when is_list(nodes) do
    Enum.find_value(nodes, fn
      %{"__typename" => "ProjectV2ItemFieldSingleSelectValue", "field" => %{"id" => ^status_field_id}, "name" => name} ->
        name

      _ ->
        nil
    end)
  end

  defp extract_status(_, _), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"trackedInIssues" => %{"nodes" => nodes}}) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{"id" => id, "number" => number} = blocker when is_binary(id) ->
        repo = get_in(blocker, ["repository", "nameWithOwner"])

        identifier =
          cond do
            is_binary(repo) and is_integer(number) -> repo <> "#" <> Integer.to_string(number)
            is_integer(number) -> "#" <> Integer.to_string(number)
            true -> nil
          end

        [%{id: id, identifier: identifier, state: blocker["state"]}]

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values}) when is_list(assignees) and is_struct(match_values, MapSet) do
    Enum.any?(assignees, fn assignee ->
      login = normalize_match_value(assignee["login"])
      id = normalize_match_value(assignee["id"])
      (login && MapSet.member?(match_values, login)) || (id && MapSet.member?(match_values, id))
    end)
  end

  defp assigned_to_worker?(_assignees, _filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_match_value(assignee) do
      nil -> {:ok, nil}
      "me" -> resolve_viewer_assignee_filter()
      normalized -> {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        viewer
        |> viewer_identifiers()
        |> case do
          [] -> {:error, :missing_github_viewer_identity}
          values -> {:ok, %{configured_assignee: "me", match_values: MapSet.new(values)}}
        end

      {:ok, _body} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp viewer_identifiers(viewer) do
    [viewer["login"], viewer["id"]]
    |> Enum.map(&normalize_match_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_match_value(_), do: nil

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_), do: ""

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp build_payload(query, variables, operation_name) do
    %{"query" => query, "variables" => variables}
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, name) when is_binary(name) do
    case String.trim(name) do
      "" -> payload
      trimmed -> Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _), do: payload

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"User-Agent", "symphony-elixir"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    request_fun =
      Application.get_env(:symphony_elixir, :github_projects_request_fun, &default_post_graphql_request/2)

    request_fun.(payload, headers)
  end

  defp default_post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp github_error_context(payload, response) do
    operation =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body = response |> Map.get(:body) |> summarize_body()
    operation <> " body=" <> body
  end

  defp summarize_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
    |> inspect()
  end

  defp summarize_body(body), do: body |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes) |> truncate()

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
