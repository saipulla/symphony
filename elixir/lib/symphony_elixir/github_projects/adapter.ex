defmodule SymphonyElixir.GithubProjects.Adapter do
  @moduledoc """
  GitHub Projects (v2) backed implementation of `SymphonyElixir.Tracker`.

  Reads delegate to `SymphonyElixir.GithubProjects.Client`. Mutations use the
  GitHub REST-equivalent GraphQL mutations (`addComment`,
  `updateProjectV2ItemFieldValue`) and rely on `Client` having populated the
  project metadata cache during a recent poll so that the project/item/field
  ids are available without an extra round-trip.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GithubProjects.{Cache, Client}

  @add_comment_mutation """
  mutation SymphonyGithubAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      clientMutationId
    }
  }
  """

  @update_field_mutation """
  mutation SymphonyGithubUpdateStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item { id }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().graphql(@add_comment_mutation, %{subjectId: issue_id, body: body}) do
      {:ok, %{"data" => %{"addComment" => %{"clientMutationId" => _}}}} -> :ok
      {:ok, %{"data" => %{"addComment" => _}}} -> :ok
      {:ok, _other} -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, meta} <- ensure_project_meta(),
         {:ok, item_id} <- ensure_item_id(issue_id, meta),
         {:ok, option_id} <- lookup_option_id(meta, state_name),
         {:ok, response} <-
           client_module().graphql(@update_field_mutation, %{
             projectId: meta.project_id,
             itemId: item_id,
             fieldId: meta.status_field_id,
             optionId: option_id
           }),
         true <- match?(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => _}}}}, response) do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp ensure_project_meta do
    case Cache.project_meta() do
      %{project_id: _} = meta ->
        {:ok, meta}

      _ ->
        # Trigger a poll-equivalent fetch to warm the cache.
        with {:ok, _issues} <- client_module().fetch_candidate_issues(),
             %{project_id: _} = meta <- Cache.project_meta() do
          {:ok, meta}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :missing_github_project_metadata}
        end
    end
  end

  defp ensure_item_id(issue_id, _meta) do
    case Cache.item_id(issue_id) do
      item_id when is_binary(item_id) -> {:ok, item_id}
      _ -> {:error, :missing_github_project_item_id}
    end
  end

  defp lookup_option_id(%{status_options: options}, state_name) when is_map(options) do
    key = state_name |> String.trim() |> String.downcase()

    case Map.get(options, key) do
      option_id when is_binary(option_id) -> {:ok, option_id}
      _ -> {:error, {:state_not_found, state_name}}
    end
  end

  defp lookup_option_id(_, _state_name), do: {:error, :state_not_found}

  defp client_module do
    Application.get_env(:symphony_elixir, :github_projects_client_module, Client)
  end
end
