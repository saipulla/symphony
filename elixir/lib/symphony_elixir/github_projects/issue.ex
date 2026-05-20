defmodule SymphonyElixir.GithubProjects.Issue do
  @moduledoc """
  Normalized GitHub Projects (v2) issue representation used inside the
  `github_projects/` pipeline.

  Mirrors `SymphonyElixir.Linear.Issue` field for field so the rest of the
  orchestrator can consume the converted form via `to_tracker_issue/1`, plus
  carries the GitHub-specific identifiers needed for project mutations.
  """

  alias SymphonyElixir.Linear.Issue, as: TrackerIssue

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :project_item_id,
    :repository_name_with_owner,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          project_item_id: String.t() | nil,
          repository_name_with_owner: String.t() | nil,
          blocked_by: [map()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}), do: labels

  @doc """
  Convert a normalized GitHub Projects issue into the canonical
  `SymphonyElixir.Linear.Issue` struct used by the orchestrator.
  """
  @spec to_tracker_issue(t()) :: TrackerIssue.t()
  def to_tracker_issue(%__MODULE__{} = issue) do
    %TrackerIssue{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      state: issue.state,
      branch_name: issue.branch_name,
      url: issue.url,
      assignee_id: issue.assignee_id,
      blocked_by: issue.blocked_by,
      labels: issue.labels,
      assigned_to_worker: issue.assigned_to_worker,
      created_at: issue.created_at,
      updated_at: issue.updated_at
    }
  end
end
