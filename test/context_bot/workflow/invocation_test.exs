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

    invocation
    |> Invocation.transition_changeset(%{
      full_response: "Detailed writeup.",
      standard_site_document_uri: uri,
      standard_site_document_rkey: "3kfullresp"
    })
    |> Repo.update!()

    persisted = Repo.reload!(invocation)
    assert persisted.full_response == "Detailed writeup."
    assert persisted.standard_site_document_uri == uri
    assert persisted.standard_site_document_rkey == "3kfullresp"
    assert persisted.no_reply == false
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
