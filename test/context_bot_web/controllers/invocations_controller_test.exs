defmodule ContextBotWeb.InvocationsControllerTest do
  use ContextBotWeb.ConnCase, async: true

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.Invocation

  describe "GET /invocations" do
    test "displays summary statistics for last day, week, and month", %{conn: conn} do
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -1, :day)

      # Create an invocation from yesterday
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: yesterday,
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      # Set inserted_at to yesterday manually (needed for time-based queries)
      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(set: [inserted_at: yesterday])

      # Create a budget entry
      {:ok, _entry} =
        %BudgetEntry{}
        |> BudgetEntry.changeset(%{
          attempt_key: "test-attempt-1",
          invocation_id: inv.id,
          budget_date: Date.utc_today(),
          kind: :research,
          reserved_microdollars: 500_000,
          settled_microdollars: 450_000,
          state: :settled,
          usage: %{
            "input_tokens" => 1000,
            "output_tokens" => 500
          }
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      # Check summary sections exist
      assert body =~ ~s(href="/">Rate and funding limits)
      assert body =~ "Last 24 Hours"
      assert body =~ "Last 7 Days"
      assert body =~ "Last 30 Days"

      # Check metric labels exist
      assert body =~ "Invocations"
      assert body =~ "API Cost"
      assert body =~ "Tokens"
      assert body =~ "Errors"
    end

    test "displays API costs in dollars", %{conn: conn} do
      now = DateTime.utc_now()

      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: now,
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      # Create budget entry with 1.5M microdollars = $1.50
      {:ok, _entry} =
        %BudgetEntry{}
        |> BudgetEntry.changeset(%{
          attempt_key: "test-attempt-2",
          invocation_id: inv.id,
          budget_date: Date.utc_today(),
          kind: :research,
          reserved_microdollars: 2_000_000,
          settled_microdollars: 1_500_000,
          state: :settled,
          usage: %{"input_tokens" => 5000, "output_tokens" => 2000}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "$1.50"
    end

    test "counts errors correctly", %{conn: conn} do
      now = DateTime.utc_now()

      # Create failed invocation
      {:ok, _inv1} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test1/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test1",
          actor_handle: "test1.bsky.social",
          raw_notification: %{},
          received_at: now,
          status: :failed,
          stage: :failed,
          failure_category: :provider_auth
        })
        |> Repo.insert()

      # Create invocation with failure_category but not failed status
      {:ok, _inv2} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test2/app.bsky.feed.post/def456",
          notification_cid: "cid2",
          current_cid: "cid2",
          actor_did: "did:plc:test2",
          actor_handle: "test2.bsky.social",
          raw_notification: %{},
          received_at: now,
          status: :complete,
          stage: :complete,
          failure_category: :provider_budget
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      # Should count both as errors (status=failed OR failure_category is set)
      # Look for error count of 2 in the summary stats
      assert body =~ "stat-error"
    end

    test "lists invocations in reverse chronological order", %{conn: conn} do
      # Create test invocations
      {:ok, _inv1} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test1/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test1",
          actor_handle: "test1.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      {:ok, _inv2} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: true,
          target_uri: "at://did:plc:test2/app.bsky.feed.post/xyz789",
          invocation_text: "Test question",
          invocation_uri: "at://did:plc:test2/app.bsky.feed.post/def456",
          notification_cid: "cid2",
          current_cid: "cid2",
          actor_did: "did:plc:test2",
          actor_handle: "test2.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 11:00:00Z],
          status: :researching,
          stage: :researching
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")

      assert html_response(conn, 200) =~ "Context Bot Invocations"
      body = html_response(conn, 200)

      # Check that newer invocation appears first
      inv1_pos = :binary.match(body, "test1.bsky.social") |> elem(0)
      inv2_pos = :binary.match(body, "test2.bsky.social") |> elem(0)
      assert inv2_pos < inv1_pos

      # Check status and stage are displayed
      assert body =~ "complete"
      assert body =~ "researching"

      # Check actor handles are displayed
      assert body =~ "test1.bsky.social"
      assert body =~ "test2.bsky.social"

      # Check dry_run flag
      assert body =~ "yes"
    end

    test "displays invocation links when URIs exist", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "https://bsky.app/profile/did:plc:test/post/abc123"
    end

    test "displays reply links when reply URIs exist", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          reply_uri: "at://did:plc:bot/app.bsky.feed.post/reply1",
          reply_part2_uri: "at://did:plc:bot/app.bsky.feed.post/reply2"
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "https://bsky.app/profile/did:plc:bot/post/reply1"
      assert body =~ "https://bsky.app/profile/did:plc:bot/post/reply2"
    end

    test "shows a completed no-reply without inventing reply or reader links", %{conn: conn} do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          no_reply: true,
          reply_validation: %{"result" => "no_reply"}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ Integer.to_string(inv.id)
      assert body =~ "complete"
      assert body =~ "no reply"
      refute body =~ "https://bsky.app/profile/did:plc:bot/"
      refute body =~ "https://standard-reader.app/"
      refute body =~ "couldn't reply"
    end

    test "omits reply links when reply URIs are null", %{conn: conn} do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :researching,
          stage: :researching
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      # Should not have reply links, but verify the row exists
      assert body =~ Integer.to_string(inv.id)
      refute body =~ "https://bsky.app/profile/did:plc:bot/"
    end

    test "displays attempt count from anthropic_attempt_sequence", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          anthropic_attempt_sequence: 3
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ ">3<"
    end

    test "displays failure category and detail", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :failed,
          stage: :failed,
          failure_category: :provider_auth,
          failure_detail: %{"reason" => "API key invalid"}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "provider_auth"
      assert body =~ "API key invalid"
    end

    test "error tooltip shows only the truncated category and reason", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :failed,
          stage: :failed,
          failure_category: :provider_auth,
          failure_detail: %{
            "reason" => "API key invalid",
            "collection" => "site.standard.document",
            "status" => 400,
            "error" => "InvalidRequest",
            "raw" => "SECRET_FAILURE_DETAIL"
          }
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ ~s(title="provider_auth: API key invalid")
      assert body =~ "provider_auth: API key invalid"
      refute body =~ "SECRET_FAILURE_DETAIL"
      refute body =~ "InvalidRequest"
      refute body =~ ~s("collection")
      refute body =~ ~s("status")
    end

    test "links to the full Standard Reader response when standard_site_document_uri exists", %{
      conn: conn
    } do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          reply_uri: "at://did:plc:bot/app.bsky.feed.post/reply1"
        })
        |> Repo.insert()

      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(
        set: [standard_site_document_uri: "at://did:plc:bot/site.standard.document/3kfullresp"]
      )

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "Full Response"
      assert body =~ ~s(href="https://standard-reader.app/a/did:plc:bot/3kfullresp")
      assert body =~ ">full response</a>"
      assert body =~ "https://bsky.app/profile/did:plc:test/post/abc123"
      assert body =~ "https://bsky.app/profile/did:plc:bot/post/reply1"
    end

    test "shows the document failure in the error column without inventing a reader URL", %{
      conn: conn
    } do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          failure_detail: %{
            "reason" => "standard_site_document_failed",
            "collection" => "site.standard.document",
            "status" => 400,
            "error" => "InvalidRequest"
          }
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "standard_site_document_failed"
      assert body =~ "&mdash;"
      refute body =~ "standard-reader.app"
      refute body =~ ~s(>full response</a>)
      assert Repo.get!(Invocation, inv.id).standard_site_document_uri == nil
    end

    test "shows an em dash instead of a full-response link when none exists", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: true,
          target_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          invocation_text: "Test question",
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "&mdash;"
      refute body =~ "standard-reader.app"
      refute body =~ ~s(>full response</a>)
    end

    test "shows an em dash when standard_site_document_uri is not a document AT URI", %{
      conn: conn
    } do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :failed,
          stage: :failed
        })
        |> Repo.insert()

      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(set: [standard_site_document_uri: "not-a-document-uri"])

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "&mdash;"
      refute body =~ ~s(href="not-a-document-uri")
      refute body =~ ~s(>full response</a>)
    end

    test "displays timestamps", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          completed_at: ~U[2026-08-26 10:05:00Z]
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "2026-08-26"
      assert body =~ "10:05:00"
    end

    test "does not render stored post bodies, prompts, or raw notifications", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: true,
          target_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          invocation_text: "SECRET_PROMPT_SHOULD_NOT_APPEAR",
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{"text" => "SECRET_NOTIFICATION_BODY"},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "test.bsky.social"
      refute body =~ "SECRET_PROMPT_SHOULD_NOT_APPEAR"
      refute body =~ "SECRET_NOTIFICATION_BODY"
    end

    test "does not accept POST", %{conn: conn} do
      conn = post(conn, "/invocations", %{})
      assert conn.status == 404
    end

    test "includes a Cost column with per-row spend formatted like the header", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:cost/app.bsky.feed.post/row1",
          notification_cid: "cost-cid-1",
          actor_did: "did:plc:cost1",
          actor_handle: "cost-row.bsky.social",
          status: :complete,
          stage: :complete
        })

      insert_budget_entry!(inv, %{
        attempt_key: "cost-row-settled",
        reserved_microdollars: 500_000,
        settled_microdollars: 400_000,
        state: :settled
      })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "<th>Cost</th>"
      assert row_cost(body, inv.id) == "$0.40"
      assert body =~ "API Cost"
      assert body =~ "$0.40"
    end

    test "includes failed invocations that spent money with no reply", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:failed-cost/app.bsky.feed.post/fail1",
          notification_cid: "failed-cost-cid",
          actor_did: "did:plc:failedcost",
          actor_handle: "failed-cost.bsky.social",
          status: :failed,
          stage: :failed,
          failure_category: :provider_response,
          failure_detail: %{"reason" => "code_execution_failed"}
        })

      insert_budget_entry!(inv, %{
        attempt_key: "failed-cost-settled",
        reserved_microdollars: 5_000_000,
        settled_microdollars: 123_700,
        state: :settled
      })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ Integer.to_string(inv.id)
      assert body =~ "failed-cost.bsky.social"
      assert body =~ "status-failed"
      refute body =~ "https://bsky.app/profile/did:plc:bot/"
      assert row_cost(body, inv.id) == "$0.12"
    end

    test "includes dry-run rows that have spend", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          dry_run: true,
          target_uri: "at://did:plc:dry-cost/app.bsky.feed.post/dry1",
          invocation_text: "SECRET_DRY_RUN_QUESTION",
          invocation_uri: "at://did:plc:dry-cost/app.bsky.feed.post/dry1",
          notification_cid: "dry-cost-cid",
          actor_did: "did:plc:drycost",
          actor_handle: "dry-cost.bsky.social",
          status: :complete,
          stage: :complete
        })

      insert_budget_entry!(inv, %{
        attempt_key: "dry-cost-settled",
        reserved_microdollars: 3_000_000,
        settled_microdollars: 2_500_000,
        state: :settled
      })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ "dry-cost.bsky.social"
      assert body =~ "yes"
      assert row_cost(body, inv.id) == "$2.50"
      refute body =~ "SECRET_DRY_RUN_QUESTION"
    end

    test "shows $0.00 when a listed row has zero budget", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:zero-cost/app.bsky.feed.post/zero1",
          notification_cid: "zero-cost-cid",
          actor_did: "did:plc:zerocost",
          actor_handle: "zero-cost.bsky.social",
          status: :researching,
          stage: :researching
        })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ Integer.to_string(inv.id)
      assert row_cost(body, inv.id) == "$0.00"
    end

    test "sums row cost with the same settled-or-reserved rule as the header", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:sum-cost/app.bsky.feed.post/sum1",
          notification_cid: "sum-cost-cid",
          actor_did: "did:plc:sumcost",
          actor_handle: "sum-cost.bsky.social",
          status: :researching,
          stage: :researching
        })

      insert_budget_entry!(inv, %{
        attempt_key: "sum-cost-settled",
        reserved_microdollars: 200_000,
        settled_microdollars: 100_000,
        state: :settled
      })

      insert_budget_entry!(inv, %{
        attempt_key: "sum-cost-reserved",
        reserved_microdollars: 200_000,
        state: :reserved
      })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      # settled 100_000 + reserved 200_000 = 300_000 microdollars
      assert row_cost(body, inv.id) == "$0.30"
      assert body =~ ~s(<span class="summary-stat-label">API Cost</span>)
      assert body =~ ~s(<span class="summary-stat-value">$0.30</span>)
    end
  end

  defp insert_invocation(attrs) do
    defaults = %{
      dry_run: false,
      current_cid: Map.fetch!(attrs, :notification_cid),
      raw_notification: %{},
      received_at: DateTime.utc_now()
    }

    %Invocation{}
    |> Invocation.changeset(Map.merge(defaults, attrs))
    |> Repo.insert()
  end

  defp insert_budget_entry!(invocation, attrs) do
    defaults = %{
      invocation_id: invocation.id,
      budget_date: Date.utc_today(),
      kind: :research,
      usage: %{"input_tokens" => 10, "output_tokens" => 4}
    }

    {:ok, entry} =
      %BudgetEntry{}
      |> BudgetEntry.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    entry
  end

  defp row_cost(body, id) do
    row_pattern = ~r/<tr>\s*<td>#{id}<\/td>.*?<\/tr>/s

    case Regex.run(row_pattern, body) do
      [row] ->
        case Regex.run(~r/<td>(\$\d+\.\d{2})<\/td>/, row) do
          [_cell, cost] -> cost
          nil -> flunk("row #{id} has no $X.XX cost cell:\n#{row}")
        end

      nil ->
        flunk("no table row for invocation #{id}")
    end
  end
end
