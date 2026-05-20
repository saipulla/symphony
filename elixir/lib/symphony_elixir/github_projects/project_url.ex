defmodule SymphonyElixir.GithubProjects.ProjectUrl do
  @moduledoc """
  Parses GitHub Projects v2 URLs into the owner kind, login, and project number
  needed by the GraphQL API.

  Accepts:

    * `https://github.com/orgs/<login>/projects/<number>` (organization projects)
    * `https://github.com/users/<login>/projects/<number>` (user projects)

  Both forms tolerate a trailing slash, `/views/...` suffix, or query string.
  """

  @type owner_kind :: :organization | :user
  @type t :: %{owner_kind: owner_kind(), login: String.t(), number: pos_integer()}

  @spec parse(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(url) when is_binary(url) do
    trimmed = String.trim(url)

    case URI.parse(trimmed) do
      %URI{host: host, path: path} when is_binary(path) and host in ["github.com", "www.github.com"] ->
        parse_path(path)

      _ ->
        {:error, :invalid_github_project_url}
    end
  end

  def parse(_), do: {:error, :invalid_github_project_url}

  defp parse_path(path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.take(4)

    case segments do
      [owner_segment, login, "projects", number_string] when owner_segment in ["orgs", "users"] ->
        with {:ok, number} <- parse_number(number_string),
             {:ok, login} <- validate_login(login) do
          {:ok, %{owner_kind: owner_kind(owner_segment), login: login, number: number}}
        end

      _ ->
        {:error, :invalid_github_project_url}
    end
  end

  defp owner_kind("orgs"), do: :organization
  defp owner_kind("users"), do: :user

  defp parse_number(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_project_number}
    end
  end

  defp validate_login(login) when is_binary(login) do
    if login != "" and String.match?(login, ~r/^[A-Za-z0-9][A-Za-z0-9\-_.]*$/) do
      {:ok, login}
    else
      {:error, :invalid_github_project_login}
    end
  end
end
