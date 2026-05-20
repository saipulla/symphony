defmodule SymphonyElixir.GithubProjectsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GithubProjects.{Adapter, Cache, Client, Issue, ProjectUrl}
  alias SymphonyElixir.Linear.Issue, as: TrackerIssue

  defmodule FakeGithubClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_issue_states_by_ids_called, ids})
      {:ok, ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    prior = Application.get_env(:symphony_elixir, :github_projects_client_module)
    Application.put_env(:symphony_elixir, :github_projects_client_module, FakeGithubClient)
    Cache.reset()

    on_exit(fn ->
      if is_nil(prior) do
        Application.delete_env(:symphony_elixir, :github_projects_client_module)
      else
        Application.put_env(:symphony_elixir, :github_projects_client_module, prior)
      end

      Cache.reset()
    end)

    :ok
  end

  describe "ProjectUrl.parse/1" do
    test "parses organization project URLs" do
      assert {:ok, %{owner_kind: :organization, login: "octo-org", number: 7}} = ProjectUrl.parse("https://github.com/orgs/octo-org/projects/7")
    end

    test "parses user project URLs with trailing path segments" do
      assert {:ok, %{owner_kind: :user, login: "octocat", number: 12}} = ProjectUrl.parse("https://github.com/users/octocat/projects/12/views/1")
    end

    test "rejects non-github hosts and malformed paths" do
      assert {:error, :invalid_github_project_url} = ProjectUrl.parse("https://gitlab.com/orgs/x/projects/1")
      assert {:error, :invalid_github_project_url} = ProjectUrl.parse("https://github.com/orgs/x/issues/1")
      assert {:error, :invalid_github_project_url} = ProjectUrl.parse(nil)
      assert {:error, :invalid_github_project_number} = ProjectUrl.parse("https://github.com/orgs/x/projects/abc")
      assert {:error, :invalid_github_project_login} = ProjectUrl.parse("https://github.com/orgs/-bad!/projects/1")
    end
  end

  describe "Issue.to_tracker_issue/1" do
    test "maps github-specific fields to the canonical tracker issue" do
      issue = %Issue{
        id: "I_1",
        identifier: "octo-org/repo#3",
        title: "Fix bug",
        description: "body",
        state: "In Progress",
        url: "https://github.com/octo-org/repo/issues/3",
        assignee_id: "octocat",
        project_item_id: "PVTI_1",
        repository_name_with_owner: "octo-org/repo",
        labels: ["bug"],
        blocked_by: [%{id: "I_2", identifier: "octo-org/repo#2", state: "open"}],
        assigned_to_worker: true,
        created_at: ~U[2025-01-01 00:00:00Z],
        updated_at: ~U[2025-01-02 00:00:00Z]
      }

      assert %TrackerIssue{
               id: "I_1",
               identifier: "octo-org/repo#3",
               state: "In Progress",
               labels: ["bug"],
               assigned_to_worker: true
             } = Issue.to_tracker_issue(issue)

      assert Issue.label_names(issue) == ["bug"]
    end
  end

  describe "Adapter read delegations" do
    test "delegates fetch calls to the configured client" do
      assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
      assert_receive :fetch_candidate_issues_called

      assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
      assert_receive {:fetch_issues_by_states_called, ["Todo"]}

      assert {:ok, ["I_1"]} = Adapter.fetch_issue_states_by_ids(["I_1"])
      assert_receive {:fetch_issue_states_by_ids_called, ["I_1"]}
    end
  end

  describe "Adapter.create_comment/2" do
    test "treats addComment payloads as success" do
      Process.put({FakeGithubClient, :graphql_result}, {:ok, %{"data" => %{"addComment" => %{"clientMutationId" => nil}}}})
      assert :ok = Adapter.create_comment("I_1", "hello")
      assert_receive {:graphql_called, query, %{body: "hello", subjectId: "I_1"}}
      assert query =~ "addComment"

      Process.put({FakeGithubClient, :graphql_result}, {:ok, %{"data" => %{"addComment" => %{}}}})
      assert :ok = Adapter.create_comment("I_1", "ok")
    end

    test "surfaces api and shape errors" do
      Process.put({FakeGithubClient, :graphql_result}, {:error, :boom})
      assert {:error, :boom} = Adapter.create_comment("I_1", "boom")

      Process.put({FakeGithubClient, :graphql_result}, {:ok, %{"data" => %{}}})
      assert {:error, :comment_create_failed} = Adapter.create_comment("I_1", "weird")
    end
  end

  describe "Adapter.update_issue_state/2" do
    test "uses cached project metadata and item id to drive the mutation" do
      Cache.put_project_meta(%{
        project_id: "PVT_1",
        status_field_id: "F_status",
        status_options: %{"done" => "opt_done", "in progress" => "opt_inprog"}
      })

      Cache.put_item_id("I_1", "PVTI_1")

      Process.put(
        {FakeGithubClient, :graphql_result},
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_1"}}}}}
      )

      assert :ok = Adapter.update_issue_state("I_1", "Done")

      assert_receive {:graphql_called, query, %{projectId: "PVT_1", itemId: "PVTI_1", fieldId: "F_status", optionId: "opt_done"}}

      assert query =~ "updateProjectV2ItemFieldValue"
    end

    test "warms project metadata via fetch_candidate_issues when cache is cold" do
      # The fake client returns :candidate from fetch_candidate_issues without populating the cache,
      # so the adapter detects the missing metadata and surfaces a typed error.
      assert {:error, :missing_github_project_metadata} = Adapter.update_issue_state("I_1", "Done")
      assert_receive :fetch_candidate_issues_called
    end

    test "propagates fetch errors when warming a cold cache" do
      defmodule FailingFetchClient do
        def fetch_candidate_issues, do: {:error, :boom}
      end

      Application.put_env(:symphony_elixir, :github_projects_client_module, FailingFetchClient)
      on_exit(fn -> Application.put_env(:symphony_elixir, :github_projects_client_module, FakeGithubClient) end)

      assert {:error, :boom} = Adapter.update_issue_state("I_1", "Done")
    end

    test "rejects state lookups when cached project metadata lacks status_options" do
      # Simulate a corrupted cache entry (no status_options map) to exercise the fallback clause.
      :persistent_term.put({Cache, :state}, %{
        project_meta: %{project_id: "PVT", status_field_id: "F"},
        item_ids: %{"I_1" => "PVTI_1"}
      })

      assert {:error, :state_not_found} = Adapter.update_issue_state("I_1", "Done")
    end

    test "returns errors for missing item id and unknown state names" do
      Cache.put_project_meta(%{
        project_id: "PVT_1",
        status_field_id: "F_status",
        status_options: %{"done" => "opt_done"}
      })

      assert {:error, :missing_github_project_item_id} = Adapter.update_issue_state("I_unknown", "Done")

      Cache.put_item_id("I_1", "PVTI_1")
      assert {:error, {:state_not_found, "Backlog"}} = Adapter.update_issue_state("I_1", "Backlog")
    end

    test "surfaces mutation failures and unexpected responses" do
      Cache.put_project_meta(%{
        project_id: "PVT_1",
        status_field_id: "F_status",
        status_options: %{"done" => "opt_done"}
      })

      Cache.put_item_id("I_1", "PVTI_1")

      Process.put({FakeGithubClient, :graphql_result}, {:error, :boom})
      assert {:error, :boom} = Adapter.update_issue_state("I_1", "Done")

      Process.put({FakeGithubClient, :graphql_result}, {:ok, %{"data" => %{}}})
      assert {:error, :issue_update_failed} = Adapter.update_issue_state("I_1", "Done")

      Process.put({FakeGithubClient, :graphql_result}, :unexpected)
      assert {:error, :issue_update_failed} = Adapter.update_issue_state("I_1", "Done")
    end
  end

  describe "Cache" do
    test "starts empty and round-trips project meta and item ids" do
      assert Cache.get() == %{project_meta: nil, item_ids: %{}}
      assert Cache.project_meta() == nil
      assert Cache.item_id("nope") == nil

      Cache.put_project_meta(%{project_id: "PVT", status_field_id: "F", status_options: %{"done" => "opt"}})
      assert Cache.project_meta().project_id == "PVT"

      Cache.put_item_id("I_1", "PVTI_1")
      assert Cache.item_id("I_1") == "PVTI_1"

      Cache.reset()
      assert Cache.get() == %{project_meta: nil, item_ids: %{}}
    end
  end

  describe "Tracker dispatch for github_projects kind" do
    test "selects the GitHub Projects adapter when configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp_test",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/octo-org/projects/3",
        tracker_endpoint: nil
      )

      assert Config.settings!().tracker.kind == "github_projects"
      assert Config.settings!().tracker.project_url == "https://github.com/orgs/octo-org/projects/3"
      assert Config.settings!().tracker.endpoint == "https://api.github.com/graphql"
      assert SymphonyElixir.Tracker.adapter() == Adapter
    end

    test "rejects github_projects configuration without a token or URL" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: nil,
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/octo-org/projects/3"
      )

      assert {:error, :missing_github_api_token} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp_test",
        tracker_project_slug: nil,
        tracker_project_url: nil
      )

      assert {:error, :missing_github_project_url} = Config.validate!()
    end

    test "reads GITHUB_TOKEN and GITHUB_PROJECT_URL when values reference env vars" do
      original_token = System.get_env("GITHUB_TOKEN")
      original_url = System.get_env("GITHUB_PROJECT_URL")
      System.put_env("GITHUB_TOKEN", "from-env-token")
      System.put_env("GITHUB_PROJECT_URL", "https://github.com/users/octocat/projects/9")

      on_exit(fn ->
        restore_env("GITHUB_TOKEN", original_token)
        restore_env("GITHUB_PROJECT_URL", original_url)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_project_slug: nil,
        tracker_project_url: "$GITHUB_PROJECT_URL"
      )

      tracker = Config.settings!().tracker
      assert tracker.api_key == "from-env-token"
      assert tracker.project_url == "https://github.com/users/octocat/projects/9"
    end

    test "keeps a literal endpoint when its referenced env var is unset" do
      original = System.get_env("SYMPHONY_TEST_GITHUB_ENDPOINT")
      System.delete_env("SYMPHONY_TEST_GITHUB_ENDPOINT")
      on_exit(fn -> restore_env("SYMPHONY_TEST_GITHUB_ENDPOINT", original) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1",
        tracker_endpoint: "$SYMPHONY_TEST_GITHUB_ENDPOINT"
      )

      assert Config.settings!().tracker.endpoint == "$SYMPHONY_TEST_GITHUB_ENDPOINT"
    end
  end

  describe "Client.normalize_item_for_test/3" do
    @meta %{
      project_id: "PVT_1",
      status_field_id: "F_status",
      status_options: %{"in progress" => "opt_inprog"}
    }

    defp build_item(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "PVTI_1",
          "fieldValues" => %{
            "nodes" => [
              %{
                "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                "name" => "In Progress",
                "field" => %{"id" => "F_status"}
              }
            ]
          },
          "content" => %{
            "__typename" => "Issue",
            "id" => "I_1",
            "number" => 42,
            "title" => "Fix the thing",
            "body" => "Details.",
            "url" => "https://github.com/octo-org/repo/issues/42",
            "state" => "OPEN",
            "createdAt" => "2025-01-01T00:00:00Z",
            "updatedAt" => "2025-01-02T00:00:00Z",
            "repository" => %{"nameWithOwner" => "octo-org/repo"},
            "assignees" => %{"nodes" => [%{"id" => "U_1", "login" => "octocat"}]},
            "labels" => %{"nodes" => [%{"name" => "Bug"}, %{"name" => "P1"}, %{"name" => nil}]},
            "trackedInIssues" => %{
              "nodes" => [
                %{
                  "id" => "I_2",
                  "number" => 7,
                  "state" => "OPEN",
                  "repository" => %{"nameWithOwner" => "octo-org/repo"}
                }
              ]
            }
          }
        },
        overrides
      )
    end

    test "normalizes a full project item into a GithubProjects.Issue" do
      issue = Client.normalize_item_for_test(build_item(), @meta)

      assert %Issue{
               id: "I_1",
               identifier: "octo-org/repo#42",
               title: "Fix the thing",
               description: "Details.",
               state: "In Progress",
               url: "https://github.com/octo-org/repo/issues/42",
               assignee_id: "octocat",
               project_item_id: "PVTI_1",
               repository_name_with_owner: "octo-org/repo",
               labels: ["bug", "p1"],
               assigned_to_worker: true,
               created_at: %DateTime{},
               updated_at: %DateTime{}
             } = issue

      assert [%{id: "I_2", identifier: "octo-org/repo#7", state: "OPEN"}] = issue.blocked_by
    end

    test "returns nil when the project item content is not an Issue (e.g. PR or draft)" do
      assert nil == Client.normalize_item_for_test(%{"content" => %{"__typename" => "PullRequest"}}, @meta)
      assert nil == Client.normalize_item_for_test(%{"content" => %{"__typename" => "DraftIssue"}}, @meta)
      assert nil == Client.normalize_item_for_test(%{}, @meta)
    end

    test "uses bare #number identifier when repository is missing" do
      item =
        build_item(%{
          "content" =>
            Map.merge(build_item()["content"], %{
              "repository" => nil,
              "number" => 99
            })
        })

      assert %Issue{identifier: "#99"} = Client.normalize_item_for_test(item, @meta)
    end

    test "returns nil identifier when the number is missing" do
      content = Map.merge(build_item()["content"], %{"number" => nil, "repository" => nil})
      item = build_item(%{"content" => content})
      assert %Issue{identifier: nil} = Client.normalize_item_for_test(item, @meta)
    end

    test "extracts no status when no single-select value matches the configured status field id" do
      item =
        build_item(%{
          "fieldValues" => %{
            "nodes" => [
              %{
                "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                "name" => "High",
                "field" => %{"id" => "F_priority"}
              }
            ]
          }
        })

      assert %Issue{state: nil} = Client.normalize_item_for_test(item, @meta)
    end

    test "handles missing labels, assignees, and blockers gracefully" do
      content =
        build_item()["content"]
        |> Map.put("labels", nil)
        |> Map.put("assignees", nil)
        |> Map.put("trackedInIssues", nil)

      issue = Client.normalize_item_for_test(build_item(%{"content" => content}), @meta)
      assert issue.labels == []
      assert issue.blocked_by == []
      assert issue.assignee_id == nil
      assert issue.assigned_to_worker == true
    end

    test "applies assignee filter against login and falls back to id" do
      item = build_item()
      assert %Issue{assigned_to_worker: true} = Client.normalize_item_for_test(item, @meta, "octocat")
      assert %Issue{assigned_to_worker: false} = Client.normalize_item_for_test(item, @meta, "someone-else")

      content = Map.put(build_item()["content"], "assignees", %{"nodes" => [%{"id" => "U_42"}]})
      item_id_only = build_item(%{"content" => content})
      assert %Issue{assigned_to_worker: true} = Client.normalize_item_for_test(item_id_only, @meta, "U_42")
    end

    test "parses ISO8601 timestamps and tolerates malformed ones" do
      content = Map.merge(build_item()["content"], %{"createdAt" => "not-a-date", "updatedAt" => nil})
      issue = Client.normalize_item_for_test(build_item(%{"content" => content}), @meta)
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end
  end

  describe "Client.graphql/3 transport behavior" do
    test "wraps non-200 responses with status error and logs body" do
      payload_fun = fn _payload, _headers -> {:ok, %{status: 401, body: "bad creds"}} end

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1"
      )

      log =
        capture_log(fn ->
          assert {:error, {:github_api_status, 401}} =
                   Client.graphql("query Q { x }", %{}, request_fun: payload_fun, operation_name: "Q")
        end)

      assert log =~ "GitHub GraphQL request failed status=401"
      assert log =~ "operation=Q"
    end

    test "wraps transport errors" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1"
      )

      capture_log(fn ->
        assert {:error, {:github_api_request, :nxdomain}} =
                 Client.graphql("query Q { x }", %{}, request_fun: fn _p, _h -> {:error, :nxdomain} end)
      end)
    end

    test "surfaces GraphQL `errors` arrays as a typed error" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1"
      )

      errors = [%{"message" => "Field 'x' doesn't exist"}]

      assert {:error, {:github_graphql_errors, ^errors}} =
               Client.graphql("query Q { x }", %{}, request_fun: fn _p, _h -> {:ok, %{status: 200, body: %{"errors" => errors}}} end)
    end

    test "refuses to send when no API token is configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: nil,
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1"
      )

      assert {:error, :missing_github_api_token} =
               Client.graphql("query Q { x }", %{}, request_fun: fn _p, _h -> {:ok, %{status: 200, body: %{}}} end)
    end

    test "sends Bearer authorization, JSON content type, and operationName header in the payload" do
      parent = self()

      request_fun = fn payload, headers ->
        send(parent, {:request, payload, headers})
        {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
      end

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp_xxx",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/o/projects/1"
      )

      assert {:ok, %{"data" => %{"ok" => true}}} =
               Client.graphql("query Q { x }", %{a: 1}, request_fun: request_fun, operation_name: "Q")

      assert_receive {:request, payload, headers}
      assert payload["operationName"] == "Q"
      assert payload["variables"] == %{a: 1}
      assert {"Authorization", "Bearer ghp_xxx"} in headers
      assert {"Content-Type", "application/json"} in headers
      assert Enum.any?(headers, &match?({"X-GitHub-Api-Version", _}, &1))
    end
  end

  describe "Client end-to-end via injected request_fun" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp_test",
        tracker_project_slug: nil,
        tracker_project_url: "https://github.com/orgs/octo-org/projects/3"
      )

      Cache.reset()
      :ok
    end

    defp stub_responses(responses) do
      agent_pid = start_supervised!({Agent, fn -> responses end})

      request_fun = fn _payload, _headers ->
        Agent.get_and_update(agent_pid, fn
          [head | tail] -> {head, tail}
          [] -> {{:error, :no_more_stub_responses}, []}
        end)
      end

      Application.put_env(:symphony_elixir, :github_projects_request_fun, request_fun)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_projects_request_fun) end)
      :ok
    end

    defp ok_body(body), do: {:ok, %{status: 200, body: body}}

    defp project_meta_body do
      ok_body(%{
        "data" => %{
          "organization" => %{
            "projectV2" => %{
              "id" => "PVT_1",
              "field" => %{
                "id" => "F_status",
                "name" => "Status",
                "options" => [
                  %{"id" => "opt_todo", "name" => "Todo"},
                  %{"id" => "opt_inprog", "name" => "In Progress"},
                  %{"id" => "opt_done", "name" => "Done"}
                ]
              }
            }
          }
        }
      })
    end

    defp items_body(items, has_next \\ false, end_cursor \\ nil) do
      ok_body(%{
        "data" => %{
          "node" => %{
            "items" => %{
              "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => end_cursor},
              "nodes" => items
            }
          }
        }
      })
    end

    defp item_with(id, item_id, status_name) do
      %{
        "id" => item_id,
        "fieldValues" => %{
          "nodes" => [
            %{
              "__typename" => "ProjectV2ItemFieldSingleSelectValue",
              "name" => status_name,
              "field" => %{"id" => "F_status"}
            }
          ]
        },
        "content" => %{
          "__typename" => "Issue",
          "id" => id,
          "number" => :erlang.phash2(id, 1000),
          "title" => "Title #{id}",
          "body" => nil,
          "url" => "https://github.com/octo-org/repo/issues/#{id}",
          "state" => "OPEN",
          "createdAt" => "2025-01-01T00:00:00Z",
          "updatedAt" => "2025-01-02T00:00:00Z",
          "repository" => %{"nameWithOwner" => "octo-org/repo"},
          "assignees" => %{"nodes" => []},
          "labels" => %{"nodes" => []},
          "trackedInIssues" => %{"nodes" => []}
        }
      }
    end

    test "fetch_candidate_issues paginates, filters by active states, caches metadata, and returns tracker issues" do
      stub_responses([
        project_meta_body(),
        items_body(
          [
            item_with("I_a", "PVTI_a", "Todo"),
            item_with("I_b", "PVTI_b", "Done")
          ],
          true,
          "cursor1"
        ),
        items_body([item_with("I_c", "PVTI_c", "In Progress")])
      ])

      assert {:ok, issues} = Client.fetch_candidate_issues()
      ids = Enum.map(issues, & &1.id)
      assert "I_a" in ids
      assert "I_c" in ids
      refute "I_b" in ids
      assert Enum.all?(issues, &match?(%TrackerIssue{}, &1))

      assert Cache.project_meta().project_id == "PVT_1"
      assert Cache.item_id("I_a") == "PVTI_a"
      assert Cache.item_id("I_c") == "PVTI_c"
    end

    test "fetch_candidate_issues errors when the project URL is malformed" do
      stub_responses([])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github_projects",
        tracker_api_token: "ghp_test",
        tracker_project_slug: nil,
        tracker_project_url: "https://gitlab.com/orgs/x/projects/1"
      )

      assert {:error, :invalid_github_project_url} = Client.fetch_candidate_issues()
    end

    test "fetch_candidate_issues errors when the project is not found" do
      stub_responses([
        ok_body(%{"data" => %{"organization" => nil}})
      ])

      assert {:error, :github_project_not_found} = Client.fetch_candidate_issues()
    end

    test "fetch_candidate_issues errors when the configured status field is missing" do
      stub_responses([
        ok_body(%{
          "data" => %{
            "organization" => %{"projectV2" => %{"id" => "PVT_1", "field" => nil}}
          }
        })
      ])

      assert {:error, {:github_status_field_missing, "Status"}} = Client.fetch_candidate_issues()
    end

    test "fetch_candidate_issues errors when pagination metadata is broken" do
      stub_responses([
        project_meta_body(),
        items_body([item_with("I_a", "PVTI_a", "Todo")], true, nil)
      ])

      assert {:error, :github_missing_end_cursor} = Client.fetch_candidate_issues()
    end

    test "fetch_issues_by_states returns [] for empty input without making any request" do
      stub_responses([])
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "fetch_issues_by_states ignores the assignee filter and filters by provided states" do
      stub_responses([
        project_meta_body(),
        items_body([
          item_with("I_a", "PVTI_a", "Done"),
          item_with("I_b", "PVTI_b", "Closed"),
          item_with("I_c", "PVTI_c", "Todo")
        ])
      ])

      assert {:ok, issues} = Client.fetch_issues_by_states(["Done", "Closed"])
      assert Enum.map(issues, & &1.id) |> Enum.sort() == ["I_a", "I_b"]
    end

    test "fetch_issue_states_by_ids preserves requested order and converts to tracker issues" do
      Cache.put_item_id("I_a", "PVTI_a")
      Cache.put_item_id("I_b", "PVTI_b")

      stub_responses([
        ok_body(%{
          "data" => %{
            "nodes" => [
              %{
                "__typename" => "Issue",
                "id" => "I_b",
                "number" => 2,
                "title" => "B",
                "body" => nil,
                "url" => "https://github.com/x/y/issues/2",
                "state" => "CLOSED",
                "createdAt" => nil,
                "updatedAt" => nil,
                "repository" => %{"nameWithOwner" => "x/y"},
                "assignees" => %{"nodes" => []},
                "labels" => %{"nodes" => []},
                "trackedInIssues" => %{"nodes" => []}
              },
              %{
                "__typename" => "Issue",
                "id" => "I_a",
                "number" => 1,
                "title" => "A",
                "body" => nil,
                "url" => "https://github.com/x/y/issues/1",
                "state" => "OPEN",
                "createdAt" => nil,
                "updatedAt" => nil,
                "repository" => %{"nameWithOwner" => "x/y"},
                "assignees" => %{"nodes" => []},
                "labels" => %{"nodes" => []},
                "trackedInIssues" => %{"nodes" => []}
              }
            ]
          }
        })
      ])

      assert {:ok, [%TrackerIssue{id: "I_a"}, %TrackerIssue{id: "I_b"}]} =
               Client.fetch_issue_states_by_ids(["I_a", "I_b"])
    end

    test "fetch_issue_states_by_ids returns [] for empty input" do
      stub_responses([])
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end

    test "Adapter.update_issue_state warms the cache via fetch_candidate_issues when cold and then mutates" do
      # Drop the test-wide FakeGithubClient override so we exercise the real Client.
      Application.delete_env(:symphony_elixir, :github_projects_client_module)

      stub_responses([
        project_meta_body(),
        items_body([item_with("I_a", "PVTI_a", "Todo")]),
        ok_body(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_a"}}}})
      ])

      assert :ok = Adapter.update_issue_state("I_a", "Done")
      assert Cache.item_id("I_a") == "PVTI_a"
    end
  end
end
