defmodule ContextBotWeb.FullResponseControllerTest do
  use ContextBotWeb.ConnCase, async: false

  alias ContextBot.Repo
  alias ContextBot.StandardSite.Mirror
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-09-04 18:00:00.000000Z]
  @writeup "Detailed analysis of the claim with a [citation](https://example.test/source)."
  @compact "The claim is only partly true."
  @doc_uri "at://did:plc:bot/site.standard.document/3kfullresp"

  setup do
    previous = Application.get_env(:context_bot, Mirror, [])

    Application.put_env(:context_bot, Mirror,
      index_check: fn _uri -> :not_indexed end,
      now: @now
    )

    on_exit(fn ->
      if previous == [] do
        Application.delete_env(:context_bot, Mirror)
      else
        Application.put_env(:context_bot, Mirror, previous)
      end
    end)

    :ok
  end

  test "GET /r/:id renders the stored writeup when Reader is not indexed", %{conn: conn} do
    invocation = insert_published!()

    conn = get(conn, ~p"/r/#{invocation.id}")
    body = html_response(conn, 200)

    assert body =~ "The claim is only partly true."
    assert body =~ "Detailed analysis of the claim"
    assert body =~ "Summary"
    assert body =~ "Research Analysis"
    assert body =~ "How this response was produced"
    assert body =~ "temporary mirror"
    assert body =~ "https://standard-reader.app/a/did:plc:bot/3kfullresp"
    assert body =~ ~s(href="https://example.test/source")
    refute body =~ "<script>alert(1)</script>"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
  end

  test "GET /r/:rkey serves already-published documents by document rkey", %{conn: conn} do
    insert_published!()

    conn = get(conn, "/r/3kfullresp")
    body = html_response(conn, 200)

    assert body =~ "Detailed analysis of the claim"
    assert body =~ @compact
    assert body =~ ~s(href="https://example.test/source")
  end

  test "GET /r/:id stays on the mirror when the index probe is ambiguous", %{conn: conn} do
    invocation = insert_published!()
    Application.put_env(:context_bot, Mirror, index_check: fn _uri -> :ambiguous end)

    conn = get(conn, ~p"/r/#{invocation.id}")

    assert conn.status == 200
    assert html_response(conn, 200) =~ "Detailed analysis of the claim"
  end

  test "GET /r/:id redirects to Standard Reader once indexed", %{conn: conn} do
    invocation = insert_published!()
    Application.put_env(:context_bot, Mirror, index_check: fn _uri -> :indexed end)

    conn = get(conn, ~p"/r/#{invocation.id}")

    assert redirected_to(conn, 302) ==
             "https://standard-reader.app/a/did:plc:bot/3kfullresp"
  end

  test "GET /r/:id uses a latched ready row without a live probe", %{conn: conn} do
    invocation = insert_published!(reader_ready_at: @now)
    Application.put_env(:context_bot, Mirror, index_check: fn _uri -> flunk("probed") end)

    conn = get(conn, ~p"/r/#{invocation.id}")

    assert redirected_to(conn, 302) ==
             "https://standard-reader.app/a/did:plc:bot/3kfullresp"
  end

  test "GET /r/:id is 404 for dry-run or unpublished rows", %{conn: conn} do
    dry =
      insert_published!(
        dry_run: true,
        target_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
        invocation_text: "dry question"
      )

    bare =
      insert_published!(
        notification_cid: "bafy-bare",
        standard_site_document_uri: nil,
        standard_site_document_rkey: nil
      )

    assert conn |> get(~p"/r/#{dry.id}") |> html_response(404) =~ "No published full response"
    assert conn |> get(~p"/r/#{bare.id}") |> html_response(404) =~ "No published full response"
    assert conn |> get("/r/999999") |> html_response(404)
  end

  test "GET /r/:id escapes script-bearing writeup text", %{conn: conn} do
    invocation =
      insert_published!(full_response: "Hello <script>alert(1)</script> world")

    body = conn |> get(~p"/r/#{invocation.id}") |> html_response(200)

    refute body =~ "<script>alert"
    assert body =~ "alert"
  end

  defp insert_published!(overrides \\ []) do
    attrs =
      %{
        dry_run: false,
        invocation_uri: "at://did:plc:alice/app.bsky.feed.post/3k123",
        notification_cid: "bafy-full-#{System.unique_integer([:positive])}",
        current_cid: "bafy-full",
        actor_did: "did:plc:alice",
        actor_handle: "alice.test",
        raw_notification: %{
          "author" => %{"handle" => "alice.test"},
          "record" => %{"text" => "What bird is that?"}
        },
        received_at: @now,
        status: :complete,
        stage: :complete,
        full_response: @writeup,
        selected_reply: @compact,
        standard_site_document_uri: @doc_uri,
        standard_site_document_rkey: "3kfullresp",
        reply_repo: "did:plc:bot"
      }
      |> Map.merge(Map.new(overrides))

    invocation =
      %Invocation{}
      |> Invocation.changeset(attrs)
      |> Repo.insert!()

    cache =
      overrides
      |> Keyword.take([:reader_ready_at, :reader_checked_at])
      |> Map.new()

    if cache == %{} do
      invocation
    else
      invocation
      |> Invocation.reader_index_changeset(cache)
      |> Repo.update!()
    end
  end
end
