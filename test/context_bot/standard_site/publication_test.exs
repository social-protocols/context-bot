defmodule ContextBot.StandardSite.PublicationTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.StandardSite.Publication

  @repo "did:plc:test123abc"
  @created_at ~U[2026-08-25 12:00:00Z]

  describe "ensure_exists/3" do
    test "creates publication record when it doesn't exist" do
      client = fake_client_with_not_found()
      assert {:ok, uri} = Publication.ensure_exists(client, @repo, @created_at)
      assert uri == "at://#{@repo}/site.standard.publication/context-bot"
    end

    test "returns success when publication already exists with same content" do
      client = fake_client_with_existing_record()
      assert {:ok, uri} = Publication.ensure_exists(client, @repo, @created_at)
      assert uri == "at://#{@repo}/site.standard.publication/context-bot"
    end

    test "returns error when publication exists with different content" do
      client = fake_client_with_mismatched_record()

      assert {:error, :publication_conflict} =
               Publication.ensure_exists(client, @repo, @created_at)
    end
  end

  describe "publication_uri/1" do
    test "returns the correct URI" do
      assert Publication.publication_uri(@repo) ==
               "at://#{@repo}/site.standard.publication/context-bot"
    end
  end

  defp fake_client_with_not_found do
    %{
      get_record: fn _repo, _collection, _rkey ->
        {:error, :record_not_found}
      end,
      put_record: fn _repo, _collection, _rkey, _record ->
        {:ok, 200, %{}, %{}}
      end
    }
  end

  defp fake_client_with_existing_record do
    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://getcontext.bot",
      "name" => "Context Bot",
      "createdAt" => DateTime.to_iso8601(@created_at)
    }

    %{
      get_record: fn _repo, _collection, _rkey ->
        {:ok, 200, %{}, %{"value" => record}}
      end
    }
  end

  defp fake_client_with_mismatched_record do
    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://different.url",
      "name" => "Different Name",
      "createdAt" => DateTime.to_iso8601(@created_at)
    }

    %{
      get_record: fn _repo, _collection, _rkey ->
        {:ok, 200, %{}, %{"value" => record}}
      end
    }
  end
end
