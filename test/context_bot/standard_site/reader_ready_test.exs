defmodule ContextBot.StandardSite.ReaderReadyTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.StandardSite.ReaderReady
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-09-05 18:00:00.000000Z]
  @doc_uri "at://did:plc:bot/site.standard.document/3kfullresp"

  test "latched reader_ready_at is ready and does not probe" do
    invocation = insert_complete!(reader_ready_at: @now)
    check = fn _uri -> flunk("should not probe after reader_ready_at latches") end

    assert {:ready, ready} = ReaderReady.ensure(invocation, check: check, now: @now)
    assert ready.id == invocation.id
    assert ready.reader_ready_at == @now
  end

  test "an indexed probe latches reader_ready_at and is ready" do
    invocation = insert_complete!()

    assert {:ready, ready} =
             ReaderReady.ensure(invocation,
               check: fn uri -> assert uri == @doc_uri && :indexed end,
               now: @now
             )

    persisted = Repo.reload!(invocation)
    assert ready.reader_ready_at == @now
    assert persisted.reader_ready_at == @now
    assert persisted.reader_checked_at == @now
  end

  test "not_indexed keeps waiting and does not latch readiness" do
    invocation = insert_complete!()

    assert {:wait, :not_indexed, waited} =
             ReaderReady.ensure(invocation, check: fn _uri -> :not_indexed end, now: @now)

    assert waited.reader_ready_at == nil
    assert waited.reader_checked_at == @now
    assert Repo.reload!(invocation).reader_ready_at == nil
  end

  test "ambiguous keeps waiting and does not latch readiness" do
    invocation = insert_complete!()

    assert {:wait, :ambiguous, waited} =
             ReaderReady.ensure(invocation, check: fn _uri -> :ambiguous end, now: @now)

    assert waited.reader_ready_at == nil
    assert waited.reader_checked_at == @now
  end

  test "a missing document URI is ambiguous and does not probe" do
    invocation = insert_complete!(standard_site_document_uri: nil)
    check = fn _uri -> flunk("should not probe without a document URI") end

    assert {:wait, :ambiguous, waited} = ReaderReady.ensure(invocation, check: check, now: @now)
    assert waited.reader_ready_at == nil
  end

  defp insert_complete!(overrides \\ []) do
    attrs =
      %{
        dry_run: false,
        invocation_uri: "at://did:plc:alice/app.bsky.feed.post/3kready",
        notification_cid: "bafy-ready-#{System.unique_integer([:positive])}",
        current_cid: "bafy-ready",
        actor_did: "did:plc:alice",
        raw_notification: %{"record" => %{"text" => "What is the evidence?"}},
        received_at: @now,
        status: :complete,
        stage: :complete,
        standard_site_document_uri: @doc_uri,
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
