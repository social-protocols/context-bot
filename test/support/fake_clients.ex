defmodule FakeClientNotFound do
  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeClientExisting do
  def get_record(_repo, _collection, _rkey) do
    created_at = ~U[2026-08-25 12:00:00Z]

    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://getcontext.bot",
      "name" => "Context Bot",
      "createdAt" => DateTime.to_iso8601(created_at)
    }

    {:ok, 200, %{}, %{"value" => record}}
  end
end

defmodule FakeClientMismatch do
  def get_record(_repo, _collection, _rkey) do
    created_at = ~U[2026-08-25 12:00:00Z]

    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://different.url",
      "name" => "Different Name",
      "createdAt" => DateTime.to_iso8601(created_at)
    }

    {:ok, 200, %{}, %{"value" => record}}
  end
end

defmodule FakeDocClientSuccess do
  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeDocClientFailure do
  def put_record(_repo, _collection, _rkey, _record) do
    {:error, :timeout}
  end
end

defmodule FakeDocClientWithDocument do
  def get_record(_repo, _collection, _rkey) do
    created_at = ~U[2026-08-25 12:00:00Z]
    publication_uri = "at://did:plc:test123abc/site.standard.publication/context-bot"

    record = %{
      "$type" => "site.standard.document",
      "site" => publication_uri,
      "title" => "Context on 3k123...",
      "textContent" => "Full response text",
      "publishedAt" => DateTime.to_iso8601(created_at)
    }

    {:ok, 200, %{}, %{"value" => record}}
  end

  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeDocClientNotFound do
  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end
end
