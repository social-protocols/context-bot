defmodule ContextBot.StandardSite.MirrorTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.StandardSite.Mirror
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-09-04 18:00:00.000000Z]
  @writeup "This is the stored full research writeup with a [source](https://example.test/a)."
  @compact "Compact summary of the writeup."
  @doc_uri "at://did:plc:bot/site.standard.document/3kfullresp"

  test "public_url/1 is the stable getcontext.bot mirror path" do
    assert Mirror.public_url(31) == "https://getcontext.bot/r/31"
    assert Mirror.public_url(%Invocation{id: 31}) == "https://getcontext.bot/r/31"
    assert Mirror.public_url(%{id: 31}) == "https://getcontext.bot/r/31"
    assert Mirror.public_url(nil) == nil
  end

  test "serve/2 renders stored markdown while Reader is not indexed" do
    invocation = insert_published!()

    assert {:mirror, served, markdown} =
             Mirror.serve(invocation.id, check: fn _uri -> :not_indexed end, now: @now)

    assert served.id == invocation.id
    assert markdown =~ "## Summary"
    assert markdown =~ @compact
    assert markdown =~ @writeup
    assert markdown =~ "# Research Analysis"
    assert markdown =~ "How this response was produced"
    assert markdown =~ "https%3A%2F%2Fgetcontext.bot%2Fr%2F#{invocation.id}"

    persisted = Repo.reload!(invocation)
    assert persisted.reader_ready_at == nil
    assert persisted.reader_checked_at == @now
  end

  test "serve/2 stays on the mirror when the index probe is ambiguous" do
    invocation = insert_published!()

    assert {:mirror, _served, markdown} =
             Mirror.serve(invocation.id, check: fn _uri -> :ambiguous end, now: @now)

    assert markdown =~ @writeup
    assert Repo.reload!(invocation).reader_ready_at == nil
  end

  test "serve/2 redirects after Reader reports the document indexed" do
    invocation = insert_published!()

    assert {:redirect, url} =
             Mirror.serve(invocation.id, check: fn _uri -> :indexed end, now: @now)

    assert url == "https://standard-reader.app/a/did:plc:bot/3kfullresp"

    persisted = Repo.reload!(invocation)
    assert persisted.reader_ready_at == @now
    assert persisted.reader_checked_at == @now
  end

  test "serve/2 uses the ready latch and does not probe Reader again" do
    invocation = insert_published!(reader_ready_at: @now, reader_checked_at: @now)
    check = fn _uri -> flunk("should not probe after reader_ready_at latches") end

    assert {:redirect, url} = Mirror.serve(invocation.id, check: check, now: @now)
    assert url == "https://standard-reader.app/a/did:plc:bot/3kfullresp"
  end

  test "serve/2 uses the negative TTL and does not probe again before it expires" do
    checked = DateTime.add(@now, -10, :second)
    invocation = insert_published!(reader_checked_at: checked)
    check = fn _uri -> flunk("should not probe inside the negative TTL") end

    assert {:mirror, _served, markdown} =
             Mirror.serve(invocation.id, check: check, now: @now, ttl_ms: 60_000)

    assert markdown =~ @writeup
  end

  test "serve/2 looks up already-published documents by rkey" do
    invocation = insert_published!()

    assert {:mirror, served, markdown} =
             Mirror.serve("3kfullresp", check: fn _uri -> :not_indexed end, now: @now)

    assert served.id == invocation.id
    assert markdown =~ @writeup
  end

  test "serve/2 hides dry-run writeups" do
    invocation =
      insert_published!(
        dry_run: true,
        target_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
        invocation_text: "secret dry-run question"
      )

    assert Mirror.serve(invocation.id, check: fn _uri -> :indexed end) == :not_found
    assert Mirror.serve("3kfullresp", check: fn _uri -> :indexed end) == :not_found
  end

  test "serve/2 returns not_found without a published document" do
    invocation =
      insert_published!(standard_site_document_uri: nil, standard_site_document_rkey: nil)

    assert Mirror.serve(invocation.id, check: fn _uri -> :indexed end) == :not_found
  end

  defp insert_published!(overrides \\ []) do
    attrs =
      %{
        dry_run: false,
        invocation_uri: "at://did:plc:alice/app.bsky.feed.post/3k123",
        notification_cid: "bafy-mirror-#{System.unique_integer([:positive])}",
        current_cid: "bafy-mirror",
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

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
    |> maybe_put_index_cache(overrides)
  end

  defp maybe_put_index_cache(invocation, overrides) do
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
