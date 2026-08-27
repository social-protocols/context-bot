defmodule ContextBot.StandardSite.PublicationTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.StandardSite.Publication

  @repo "did:plc:test123abc"
  @created_at ~U[2026-08-25 12:00:00Z]

  describe "ensure_exists/3" do
    test "creates publication record when it doesn't exist" do
      assert {:ok, uri} = Publication.ensure_exists(FakeClientNotFound, @repo, @created_at)
      assert uri == "at://#{@repo}/site.standard.publication/context-bot"
    end

    test "returns success when publication already exists with same content" do
      assert {:ok, uri} = Publication.ensure_exists(FakeClientExisting, @repo, @created_at)
      assert uri == "at://#{@repo}/site.standard.publication/context-bot"
    end

    test "returns success when publication exists with a different createdAt" do
      later = ~U[2026-08-27 18:00:00Z]

      assert {:ok, uri} =
               Publication.ensure_exists(FakeClientExistingDifferentCreatedAt, @repo, later)

      assert uri == "at://#{@repo}/site.standard.publication/context-bot"
    end

    test "returns error when publication exists with different content" do
      assert {:error, :publication_conflict} =
               Publication.ensure_exists(FakeClientMismatch, @repo, @created_at)
    end
  end

  describe "publication_uri/1" do
    test "returns the correct URI" do
      assert Publication.publication_uri(@repo) ==
               "at://#{@repo}/site.standard.publication/context-bot"
    end
  end
end
