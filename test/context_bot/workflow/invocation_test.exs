defmodule ContextBot.Workflow.InvocationTest do
  use ExUnit.Case, async: true

  import ContextBot.DataCase, only: [errors_on: 1]
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
