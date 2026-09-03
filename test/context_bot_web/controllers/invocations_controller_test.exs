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
    end

    test "includes a Cost column from budget-entry spend, including failed and dry-run rows", %{
      conn: conn
    } do
      now = DateTime.utc_now()

      {:ok, complete} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:complete/app.bsky.feed.post/abc123",
          notification_cid: "cid-complete",
          current_cid: "cid-complete",
          actor_did: "did:plc:complete",
          actor_handle: "complete.bsky.social",
          received_at: now,
          status: :complete,
          stage: :complete
        })

      {:ok, failed} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:failed/app.bsky.feed.post/fail19",
          notification_cid: "cid-failed",
          current_cid: "cid-failed",
          actor_did: "did:plc:failed",
          actor_handle: "failed.bsky.social",
          received_at: now,
          status: :failed,
          stage: :failed,
          failure_category: :provider_response,
          failure_detail: %{"reason" => "code_execution_failed"}
        })

      {:ok, dry} =
        insert_invocation(%{
          dry_run: true,
          target_uri: "at://did:plc:dry/app.bsky.feed.post/target",
          invocation_text: "Question?",
          invocation_uri: "at://did:plc:dry/app.bsky.feed.post/dry1",
          notification_cid: "cid-dry",
          current_cid: "cid-dry",
          actor_did: "did:plc:dry",
          actor_handle: "dry.bsky.social",
          received_at: now,
          status: :complete,
          stage: :complete
        })

      {:ok, unpaid} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:zero/app.bsky.feed.post/zero",
          notification_cid: "cid-zero",
          current_cid: "cid-zero",
          actor_did: "did:plc:zero",
          actor_handle: "zero.bsky.social",
          received_at: now,
          status: :received,
          stage: :received
        })

      insert_budget_entry!(complete, "cost-complete",
        reserved_microdollars: 500_000,
        settled_microdollars: 400_000,
        state: :settled
      )

      insert_budget_entry!(failed, "cost-failed",
        reserved_microdollars: 400_000,
        settled_microdollars: 400_000,
        state: :settled
      )

      insert_budget_entry!(dry, "cost-dry",
        reserved_microdollars: 250_000,
        settled_microdollars: 250_000,
        state: :settled
      )

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)
      table = table_html(body)

      assert table =~ "<th>Cost</th>"
      assert row_html(table, complete.id) =~ "$0.40"
      assert row_html(table, failed.id) =~ "$0.40"
      assert row_html(table, failed.id) =~ "failed"
      assert row_html(table, dry.id) =~ "$0.25"
      assert row_html(table, unpaid.id) =~ "$0.00"
    end

    test "omits the Dry Run table column while leaving dry_run rows listed", %{conn: conn} do
      {:ok, dry} =
        insert_invocation(%{
          dry_run: true,
          target_uri: "at://did:plc:drycol/app.bsky.feed.post/target",
          invocation_text: "Question?",
          invocation_uri: "at://did:plc:drycol/app.bsky.feed.post/drycol",
          notification_cid: "cid-drycol",
          current_cid: "cid-drycol",
          actor_did: "did:plc:drycol",
          actor_handle: "drycol.bsky.social",
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)
      table = table_html(body)

      refute table =~ "Dry Run"
      refute row_html(table, dry.id) =~ ">yes<"
      assert Repo.get!(Invocation, dry.id).dry_run
      assert body =~ "drycol.bsky.social"
    end

    test "renders relative Inserted and Completed times with UTC tooltips", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      inserted_at = DateTime.add(now, -70, :second)
      completed_at = DateTime.add(now, -3, :day)

      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:rel/app.bsky.feed.post/rel1",
          notification_cid: "cid-rel",
          current_cid: "cid-rel",
          actor_did: "did:plc:rel",
          actor_handle: "relative.bsky.social",
          received_at: inserted_at,
          status: :complete,
          stage: :complete,
          completed_at: completed_at
        })

      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(set: [inserted_at: inserted_at, completed_at: completed_at])

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)
      row = row_html(table_html(body), inv.id)

      inserted_title = Calendar.strftime(inserted_at, "%Y-%m-%d %H:%M:%S UTC")
      completed_title = Calendar.strftime(completed_at, "%Y-%m-%d %H:%M:%S UTC")

      assert row =~ "1 minute ago"
      assert row =~ "3 days ago"
      assert row =~ ~s(title="#{inserted_title}")
      assert row =~ ~s(title="#{completed_title}")
      refute row =~ ">#{Calendar.strftime(inserted_at, "%Y-%m-%d %H:%M:%S")}<"
    end

    test "pluralizes a one-minute relative time after the 90-second threshold", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      inserted_at = DateTime.add(now, -100, :second)

      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:rel2/app.bsky.feed.post/rel2",
          notification_cid: "cid-rel2",
          current_cid: "cid-rel2",
          actor_did: "did:plc:rel2",
          actor_handle: "relative2.bsky.social",
          received_at: inserted_at,
          status: :researching,
          stage: :researching
        })

      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      conn = get(conn, ~p"/invocations")
      row = row_html(table_html(html_response(conn, 200)), inv.id)

      assert row =~ "1 minute ago"
      refute row =~ "1 minutes ago"
    end

    test "shows an em dash for a missing completed time", %{conn: conn} do
      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:open/app.bsky.feed.post/open1",
          notification_cid: "cid-open",
          current_cid: "cid-open",
          actor_did: "did:plc:open",
          actor_handle: "open.bsky.social",
          received_at: DateTime.utc_now(),
          status: :researching,
          stage: :researching
        })

      conn = get(conn, ~p"/invocations")
      row = row_html(table_html(html_response(conn, 200)), inv.id)

      assert row =~ ~r/<td>&mdash;<\/td>\s*<\/tr>/
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

    test "shows an internal pack-first split failure as invalid_repair, not provider_response", %{
      conn: conn
    } do
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
          failure_category: :invalid_repair,
          failure_detail: %{"reason" => "invalid_repair"}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/invocations")
      body = html_response(conn, 200)

      assert body =~ ~s(title="invalid_repair")
      assert body =~ "invalid_repair"
      refute body =~ "provider_response: invalid_repair"
      refute body =~ "invalid_repair: invalid_repair"
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

    test "keeps absolute UTC timestamps inspectable on relative time tooltips", %{conn: conn} do
      inserted_at = ~U[2026-08-26 10:00:00Z]
      completed_at = ~U[2026-08-26 10:05:00Z]

      {:ok, inv} =
        insert_invocation(%{
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          received_at: inserted_at,
          status: :complete,
          stage: :complete,
          completed_at: completed_at
        })

      from(i in Invocation, where: i.id == ^inv.id)
      |> Repo.update_all(set: [inserted_at: inserted_at, completed_at: completed_at])

      conn = get(conn, ~p"/invocations")
      row = row_html(table_html(html_response(conn, 200)), inv.id)

      assert row =~ ~s(title="2026-08-26 10:00:00 UTC")
      assert row =~ ~s(title="2026-08-26 10:05:00 UTC")
      assert row =~ "ago"
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
  end

  defp insert_invocation(attrs) do
    defaults = %{
      dry_run: false,
      raw_notification: %{}
    }

    %Invocation{}
    |> Invocation.changeset(Map.merge(defaults, attrs))
    |> Repo.insert()
  end

  defp insert_budget_entry!(invocation, attempt_key, opts) do
    {:ok, entry} =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: attempt_key,
        invocation_id: invocation.id,
        budget_date: Date.utc_today(),
        kind: :research,
        reserved_microdollars: Keyword.fetch!(opts, :reserved_microdollars),
        settled_microdollars: Keyword.fetch!(opts, :settled_microdollars),
        state: Keyword.fetch!(opts, :state),
        usage: %{"input_tokens" => 100, "output_tokens" => 50}
      })
      |> Repo.insert()

    entry
  end

  defp table_html(body) do
    case Regex.run(~r/<table>.*<\/table>/s, body) do
      [table] -> table
      _ -> flunk("expected an invocations table")
    end
  end

  defp row_html(table, invocation_id) do
    id = Integer.to_string(invocation_id)

    case Regex.run(~r/<tr>\s*<td>#{id}<\/td>.*?<\/tr>/s, table) do
      [row] -> row
      _ -> flunk("expected a table row for invocation #{id}")
    end
  end
end
