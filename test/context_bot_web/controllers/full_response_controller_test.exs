defmodule ContextBotWeb.FullResponseControllerTest do
  use ContextBotWeb.ConnCase, async: true

  alias ContextBot.Repo
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-09-06 00:00:00.000000Z]
  @writeup "SECRET_WRITEUP should never appear on /r/."
  @doc_uri "at://did:plc:bot/site.standard.document/3kfullresp"
  @reader_url "https://standard-reader.app/a/did:plc:bot/3kfullresp"

  test "GET /r/:id 301s to the Standard Reader URL when the document uri is present", %{
    conn: conn
  } do
    invocation = insert_published!()

    conn = get(conn, "/r/#{invocation.id}")

    assert redirected_to(conn, 301) == @reader_url
    refute conn.resp_body =~ @writeup
  end

  test "GET /r/:rkey 301s using the stored document rkey as an alias", %{conn: conn} do
    insert_published!()

    conn = get(conn, "/r/3kfullresp")

    assert redirected_to(conn, 301) == @reader_url
    refute conn.resp_body =~ @writeup
  end

  test "GET /r/:id is 404 when the document uri is missing", %{conn: conn} do
    invocation =
      insert_published!(
        notification_cid: "bafy-missing-uri",
        standard_site_document_uri: nil,
        standard_site_document_rkey: nil
      )

    conn = get(conn, "/r/#{invocation.id}")

    assert conn.status == 404
    assert conn.resp_body =~ "No published full response"
    refute conn.resp_body =~ @writeup
    refute conn.resp_body =~ "standard-reader.app"
  end

  test "GET /r/:id is 404 when the stored uri is not a document AT URI", %{conn: conn} do
    invocation =
      insert_published!(
        notification_cid: "bafy-bad-uri",
        standard_site_document_uri: "at://did:plc:bot/app.bsky.feed.post/3kfullresp"
      )

    conn = get(conn, "/r/#{invocation.id}")

    assert conn.status == 404
    refute conn.resp_body =~ @writeup
    refute conn.resp_body =~ "standard-reader.app"
  end

  test "GET /r/:id is 404 for an unknown id or rkey", %{conn: conn} do
    assert conn |> get("/r/999999") |> Map.fetch!(:status) == 404
    assert conn |> get("/r/3kmissingrkey") |> Map.fetch!(:status) == 404
  end

  test "GET /r/:id does not serve the sqlite writeup as a page", %{conn: conn} do
    invocation = insert_published!()

    conn = get(conn, "/r/#{invocation.id}")

    assert redirected_to(conn, 301) == @reader_url
    refute conn.resp_body =~ "Research Analysis"
    refute conn.resp_body =~ "Detailed analysis"
    refute conn.resp_body =~ @writeup
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
        raw_notification: %{},
        received_at: @now,
        status: :complete,
        stage: :complete,
        full_response: @writeup,
        selected_reply: "The claim is only partly true.",
        standard_site_document_uri: @doc_uri,
        standard_site_document_rkey: "3kfullresp",
        reply_repo: "did:plc:bot"
      }
      |> Map.merge(Map.new(overrides))

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end
end
