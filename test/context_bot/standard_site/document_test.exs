defmodule ContextBot.StandardSite.DocumentTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.StandardSite.Document

  @repo "did:plc:test123abc"
  @publication_uri "at://#{@repo}/site.standard.publication/context-bot"
  @created_at ~U[2026-08-25 12:00:00Z]
  @content %{
    full_response: "This is the full research response with detailed analysis.",
    selected_reply: "Compact summary here.",
    invocation_uri: "at://did:plc:abc/app.bsky.feed.post/3k123"
  }

  describe "create/5" do
    test "creates a document record successfully" do
      client = fake_client_success()

      assert {:ok, result} =
               Document.create(client, @repo, @publication_uri, @content, @created_at)

      assert is_binary(result.uri)
      assert is_binary(result.rkey)
      assert is_binary(result.reader_url)
      assert String.starts_with?(result.reader_url, "https://standard-reader.app/a/")
    end

    test "returns error when put_record fails" do
      client = fake_client_failure()

      assert {:error, :timeout} =
               Document.create(client, @repo, @publication_uri, @content, @created_at)
    end
  end

  describe "add_post_ref/4" do
    test "updates document with bskyPostRef" do
      client = fake_client_with_document()
      post_uri = "at://did:plc:abc/app.bsky.feed.post/3k456"

      assert :ok = Document.add_post_ref(client, @repo, "3k123", post_uri)
    end

    test "returns error when document doesn't exist" do
      client = fake_client_not_found()
      post_uri = "at://did:plc:abc/app.bsky.feed.post/3k456"

      assert {:error, :record_not_found} = Document.add_post_ref(client, @repo, "3k123", post_uri)
    end
  end

  defp fake_client_success do
    %{
      put_record: fn _repo, _collection, _rkey, _record ->
        {:ok, 200, %{}, %{}}
      end
    }
  end

  defp fake_client_failure do
    %{
      put_record: fn _repo, _collection, _rkey, _record ->
        {:error, :timeout}
      end
    }
  end

  defp fake_client_with_document do
    record = %{
      "$type" => "site.standard.document",
      "site" => @publication_uri,
      "title" => "Context on 3k123...",
      "textContent" => "Full response text",
      "publishedAt" => DateTime.to_iso8601(@created_at)
    }

    %{
      get_record: fn _repo, _collection, _rkey ->
        {:ok, 200, %{}, %{"value" => record}}
      end,
      put_record: fn _repo, _collection, _rkey, _record ->
        {:ok, 200, %{}, %{}}
      end
    }
  end

  defp fake_client_not_found do
    %{
      get_record: fn _repo, _collection, _rkey ->
        {:error, :record_not_found}
      end
    }
  end
end
