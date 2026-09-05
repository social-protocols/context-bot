defmodule ContextBot.Workflow.InvocationTest do
  use ContextBot.DataCase, async: false

  import Ecto.Changeset, only: [get_field: 2]

  alias ContextBot.Workflow.Invocation

  @received_at ~U[2026-08-09 12:00:00.000000Z]

  test "public receipts default to non-dry-run state" do
    changeset = Invocation.changeset(%Invocation{}, public_attrs())

    assert changeset.valid?
    assert get_field(changeset, :dry_run) == false
    assert get_field(changeset, :target_uri) == nil
    assert get_field(changeset, :invocation_text) == nil
  end

  test "dry-run receipts require their target and invocation text" do
    attrs = Map.put(public_attrs(), :dry_run, true)

    changeset = Invocation.changeset(%Invocation{}, attrs)

    refute changeset.valid?
    assert errors_on(changeset).target_uri == ["can't be blank"]
    assert errors_on(changeset).invocation_text == ["can't be blank"]
  end

  test "persists canonical media descriptors without changing legacy rows" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    assert Repo.reload!(invocation).canonical_media == []

    media = [
      %{
        "type" => "image",
        "index" => 1,
        "post_uri" => "at://did:plc:actor/app.bsky.feed.post/public",
        "url" => "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:actor/cid@jpeg",
        "alt" => "A bounded description"
      }
    ]

    invocation
    |> Invocation.transition_changeset(%{canonical_media: media})
    |> Repo.update!()

    assert Repo.reload!(invocation).canonical_media == media
  end

  test "persists Standard.site document fields on research handoff" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    uri = "at://did:plc:bot/site.standard.document/3kfullresp"

    publication_uri = "at://did:plc:bot/site.standard.publication/context-bot"

    invocation
    |> Invocation.transition_changeset(%{
      full_response: "Detailed writeup.",
      standard_site_document_uri: uri,
      standard_site_document_rkey: "3kfullresp",
      standard_site_document_cid: FakeSiteCids.document(),
      standard_site_publication_uri: publication_uri,
      standard_site_publication_cid: FakeSiteCids.publication()
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.full_response == "Detailed writeup."
    assert persisted.standard_site_document_uri == uri
    assert persisted.standard_site_document_rkey == "3kfullresp"
    assert persisted.standard_site_document_cid == FakeSiteCids.document()
    assert persisted.standard_site_publication_uri == publication_uri
    assert persisted.standard_site_publication_cid == FakeSiteCids.publication()
    assert persisted.reader_ready_at == nil
    assert persisted.reader_checked_at == nil
    assert persisted.no_reply == false
  end

  test "persists Standard Reader index cache timestamps" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    checked = ~U[2026-09-04 12:00:00.000000Z]
    ready = ~U[2026-09-04 12:01:00.000000Z]

    invocation
    |> Invocation.reader_index_changeset(%{
      reader_checked_at: checked,
      reader_ready_at: ready
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.reader_checked_at == checked
    assert persisted.reader_ready_at == ready
  end

  test "persists follower-feed post coordinates on the invocation" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    record = %{
      "$type" => "app.bsky.feed.post",
      "text" => "getcontext.bot/r/33",
      "embed" => %{"$type" => "app.bsky.embed.recordWithMedia"}
    }

    invocation
    |> Invocation.transition_changeset(%{
      follower_post_rkey: "3mfollower1abc",
      follower_post_record: record,
      follower_post_uri: "at://did:plc:bot/app.bsky.feed.post/3mfollower1abc",
      follower_post_cid: "bafy-follower"
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.follower_post_rkey == "3mfollower1abc"
    assert persisted.follower_post_record == record
    assert persisted.follower_post_uri == "at://did:plc:bot/app.bsky.feed.post/3mfollower1abc"
    assert persisted.follower_post_cid == "bafy-follower"
  end

  test "persists a completed no-reply decision" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    invocation
    |> Invocation.transition_changeset(%{
      status: :complete,
      stage: :complete,
      no_reply: true,
      reply_validation: %{"result" => "no_reply", "repair_used" => false},
      completed_at: @received_at
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.no_reply == true
    assert persisted.stage == :complete
    assert persisted.reply_validation == %{"result" => "no_reply", "repair_used" => false}
  end

  test "persists an internal invalid_repair failure without remapping it to provider_response" do
    invocation =
      %Invocation{}
      |> Invocation.changeset(public_attrs())
      |> Repo.insert!()

    invocation
    |> Invocation.transition_changeset(%{
      status: :failed,
      stage: :failed,
      failure_category: :invalid_repair,
      failure_detail: %{"reason" => "invalid_repair"}
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.failure_category == :invalid_repair
    assert persisted.failure_detail == %{"reason" => "invalid_repair"}
  end

  defp public_attrs do
    %{
      invocation_uri: "at://did:plc:actor/app.bsky.feed.post/public",
      notification_cid: "bafy-public",
      current_cid: "bafy-public",
      actor_did: "did:plc:actor",
      raw_notification: %{},
      received_at: @received_at,
      status: :received,
      stage: :received
    }
  end
end
