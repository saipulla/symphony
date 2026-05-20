defmodule SymphonyElixir.GithubProjects.Cache do
  @moduledoc """
  Per-process cache (via `:persistent_term`) for GitHub Projects v2 metadata
  that mutations need but the `Tracker` callbacks don't carry: the resolved
  project node id, the single-select Status field id with its options, and a
  mapping from issue node id to project item id discovered during polling.

  Symphony keeps Linear's `Tracker` callback shape — mutations only receive an
  issue id and a state name. Because GitHub mutations need the project + item
  + field + option ids, we memoize them at poll time so subsequent
  `update_issue_state/2` calls don't have to re-walk the project.
  """

  @key {__MODULE__, :state}

  @type project_meta :: %{
          required(:project_id) => String.t(),
          required(:status_field_id) => String.t(),
          required(:status_options) => %{optional(String.t()) => String.t()}
        }
  @type t :: %{
          required(:project_meta) => project_meta() | nil,
          required(:item_ids) => %{optional(String.t()) => String.t()}
        }

  @spec get() :: t()
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> %{project_meta: nil, item_ids: %{}}
      %{} = cache -> cache
    end
  end

  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@key, %{project_meta: nil, item_ids: %{}})
    :ok
  end

  @spec put_project_meta(project_meta()) :: :ok
  def put_project_meta(meta) when is_map(meta) do
    cache = get()
    :persistent_term.put(@key, %{cache | project_meta: meta})
    :ok
  end

  @spec project_meta() :: project_meta() | nil
  def project_meta, do: get().project_meta

  @spec put_item_id(String.t(), String.t()) :: :ok
  def put_item_id(issue_id, item_id) when is_binary(issue_id) and is_binary(item_id) do
    cache = get()
    item_ids = Map.put(cache.item_ids, issue_id, item_id)
    :persistent_term.put(@key, %{cache | item_ids: item_ids})
    :ok
  end

  @spec item_id(String.t()) :: String.t() | nil
  def item_id(issue_id) when is_binary(issue_id), do: Map.get(get().item_ids, issue_id)
end
