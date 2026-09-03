defmodule ContextBotWeb.BudgetEntriesControllerTest do
  use ContextBotWeb.ConnCase, async: true

  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.Invocation

  describe "GET /api_budget_entries.json" do
    test "lists every budget-entry column as JSON", %{conn: conn} do
      invocation = insert_invocation!()

      entry =
        insert_budget_entry!(invocation, "list-budget-1",
          reserved_microdollars: 250_000,
          settled_microdollars: 200_000,
          state: :settled,
          research_claim_token: "budget-list-token"
        )

      conn = get(conn, "/api_budget_entries.json")
      assert json_content_type?(conn)
      body = json_response(conn, 200)

      assert %{"api_budget_entries" => [row]} = body
      assert_has_schema_fields(row, BudgetEntry)
      assert row["id"] == entry.id
      assert row["invocation_id"] == invocation.id
      assert row["attempt_key"] == "list-budget-1"
      assert row["research_claim_token"] == "budget-list-token"
      assert row["reserved_microdollars"] == 250_000
      assert row["settled_microdollars"] == 200_000
      assert row["state"] == "settled"
    end

    test "does not accept POST", %{conn: conn} do
      conn = post(conn, "/api_budget_entries.json", %{})
      assert conn.status == 404
    end
  end

  describe "GET /api_budget_entries/:id.json" do
    test "returns one budget entry", %{conn: conn} do
      invocation = insert_invocation!()

      entry =
        insert_budget_entry!(invocation, "show-budget-1",
          reserved_microdollars: 100_000,
          settled_microdollars: 90_000,
          state: :settled
        )

      conn = get(conn, "/api_budget_entries/#{entry.id}.json")
      body = json_response(conn, 200)

      assert json_content_type?(conn)
      assert_has_schema_fields(body, BudgetEntry)
      assert body["id"] == entry.id
      assert body["attempt_key"] == "show-budget-1"
    end

    test "returns JSON 404 for an unknown id", %{conn: conn} do
      conn = get(conn, "/api_budget_entries/999999.json")

      assert json_content_type?(conn)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      refute conn.resp_body =~ "<html"
    end
  end

  defp insert_invocation! do
    {:ok, invocation} =
      %Invocation{}
      |> Invocation.changeset(%{
        dry_run: false,
        invocation_uri:
          "at://did:plc:budget/app.bsky.feed.post/#{System.unique_integer([:positive])}",
        notification_cid: "cid-budget-#{System.unique_integer([:positive])}",
        current_cid: "cid-budget",
        actor_did: "did:plc:budget",
        actor_handle: "budget.bsky.social",
        raw_notification: %{},
        received_at: DateTime.utc_now(),
        status: :complete,
        stage: :complete
      })
      |> Repo.insert()

    invocation
  end

  defp insert_budget_entry!(invocation, attempt_key, opts) do
    {:ok, entry} =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: attempt_key,
        invocation_id: invocation.id,
        budget_date: ~D[2026-08-26],
        kind: :research,
        reserved_microdollars: Keyword.fetch!(opts, :reserved_microdollars),
        settled_microdollars: Keyword.fetch!(opts, :settled_microdollars),
        state: Keyword.fetch!(opts, :state),
        usage: %{"input_tokens" => 9, "output_tokens" => 3},
        research_claim_token: Keyword.get(opts, :research_claim_token)
      })
      |> Repo.insert()

    entry
  end

  defp json_content_type?(conn) do
    content_type = List.first(get_resp_header(conn, "content-type")) || ""
    String.starts_with?(content_type, "application/json")
  end

  defp assert_has_schema_fields(row, module) do
    Enum.each(module.__schema__(:fields), fn field ->
      assert Map.has_key?(row, Atom.to_string(field)),
             "expected #{inspect(module)} JSON to include #{field}"
    end)
  end
end
