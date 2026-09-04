defmodule ContextBotWeb.ResponseEnvelopesControllerTest do
  use ContextBotWeb.ConnCase, async: true

  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Research.ResponseEnvelope
  alias ContextBot.Workflow.Invocation

  describe "GET /anthropic_response_envelopes.json" do
    test "lists every envelope column as JSON, including binary fields", %{conn: conn} do
      {invocation, entry, envelope} = insert_envelope_row!("list-envelope-1", "LIST_RAW_BODY")

      conn = get(conn, "/anthropic_response_envelopes.json")
      assert json_content_type?(conn)
      body = json_response(conn, 200)

      assert %{"anthropic_response_envelopes" => [row]} = body
      assert_has_schema_fields(row, ResponseEnvelope)
      assert row["id"] == envelope.id
      assert row["invocation_id"] == invocation.id
      assert row["budget_entry_id"] == entry.id
      assert row["attempt_key"] == "list-envelope-1"
      assert Base.decode64!(row["raw_body"]) == "LIST_RAW_BODY"
      assert is_binary(row["metadata_blob"])
      assert row["metadata"]["attempt_key"] == "list-envelope-1"
    end

    test "does not accept POST", %{conn: conn} do
      conn = post(conn, "/anthropic_response_envelopes.json", %{})
      assert conn.status == 404
    end
  end

  describe "GET /anthropic_response_envelopes/:id.json" do
    test "returns one envelope", %{conn: conn} do
      {_invocation, _entry, envelope} = insert_envelope_row!("show-envelope-1", "SHOW_RAW_BODY")

      conn = get(conn, "/anthropic_response_envelopes/#{envelope.id}.json")
      body = json_response(conn, 200)

      assert json_content_type?(conn)
      assert_has_schema_fields(body, ResponseEnvelope)
      assert body["id"] == envelope.id
      assert Base.decode64!(body["raw_body"]) == "SHOW_RAW_BODY"
    end

    test "returns JSON 404 for an unknown id", %{conn: conn} do
      conn = get(conn, "/anthropic_response_envelopes/999999.json")

      assert json_content_type?(conn)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      refute conn.resp_body =~ "<html"
    end
  end

  defp insert_envelope_row!(attempt_key, raw_body) do
    {:ok, invocation} =
      %Invocation{}
      |> Invocation.changeset(%{
        dry_run: false,
        invocation_uri:
          "at://did:plc:envelope/app.bsky.feed.post/#{System.unique_integer([:positive])}",
        notification_cid: "cid-envelope-#{System.unique_integer([:positive])}",
        current_cid: "cid-envelope",
        actor_did: "did:plc:envelope",
        actor_handle: "envelope.bsky.social",
        raw_notification: %{},
        received_at: DateTime.utc_now(),
        status: :complete,
        stage: :complete
      })
      |> Repo.insert()

    {:ok, entry} =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: attempt_key,
        invocation_id: invocation.id,
        budget_date: ~D[2026-08-26],
        kind: :research,
        reserved_microdollars: 50_000,
        settled_microdollars: 50_000,
        state: :settled
      })
      |> Repo.insert()

    metadata = %{status: 200, attempt_key: attempt_key}
    metadata_blob = :erlang.term_to_binary(metadata, [:deterministic])

    envelope =
      %ResponseEnvelope{}
      |> ResponseEnvelope.changeset(%{
        invocation_id: invocation.id,
        budget_entry_id: entry.id,
        attempt_key: attempt_key,
        kind: :research,
        status: 200,
        metadata_blob: metadata_blob,
        raw_body: raw_body,
        received_at: ~U[2026-08-26 10:06:00.000000Z],
        duration_ms: 9,
        storage_bytes: byte_size(metadata_blob) + byte_size(raw_body)
      })
      |> Repo.insert!()

    {invocation, entry, envelope}
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
