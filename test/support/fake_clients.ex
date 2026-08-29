defmodule FakeClientNotFound do
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeClientExisting do
  @moduledoc false

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

defmodule FakeClientExistingDifferentCreatedAt do
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://getcontext.bot",
      "name" => "Context Bot",
      "createdAt" => DateTime.to_iso8601(~U[2026-08-25 12:00:00Z])
    }

    {:ok, 200, %{}, %{"value" => record}}
  end
end

defmodule FakeClientMismatch do
  @moduledoc false

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
  @moduledoc false

  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeDocClientFailure do
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, _collection, _rkey, _record) do
    {:error, :timeout}
  end
end

defmodule FakeDocClientWithDocument do
  @moduledoc false

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
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end
end

defmodule FakeStandardSiteClient do
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, _collection, _rkey, _record) do
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeStandardSiteTrackingClient do
  @moduledoc false

  def get_record(_repo, collection, rkey) do
    send(self(), {:standard_site_get, collection, rkey})
    {:error, :record_not_found}
  end

  def put_record(_repo, collection, rkey, record) do
    send(self(), {:standard_site_put, collection, rkey, record})
    {:ok, 200, %{}, %{}}
  end
end

defmodule FakeStandardSiteLexiconUnknown do
  @moduledoc false

  def get_record(_repo, _collection, _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, collection, _rkey, _record) do
    {:error,
     {:permanent, 400,
      %{
        "error" => "InvalidRequest",
        "message" => "Lexicon not found: #{collection}"
      }}}
  end
end

defmodule FakePublicationExistsDocumentFails do
  @moduledoc false

  def get_record(_repo, "site.standard.publication", _rkey) do
    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://getcontext.bot",
      "name" => "Context Bot",
      "createdAt" => DateTime.to_iso8601(~U[2026-08-25 12:00:00Z])
    }

    {:ok, 200, %{}, %{"value" => record}}
  end

  def get_record(_repo, "site.standard.document", _rkey) do
    {:error, :record_not_found}
  end

  def put_record(_repo, "site.standard.document", _rkey, _record) do
    {:error,
     {:permanent, 400,
      %{
        "error" => "InvalidRequest",
        "message" => "Lexicon not found: site.standard.document"
      }}}
  end
end

defmodule FakePublicationAndPromptExistDocumentFails do
  @moduledoc false

  alias ContextBot.Research.Request

  def get_record(_repo, "site.standard.publication", _rkey) do
    record = %{
      "$type" => "site.standard.publication",
      "url" => "https://getcontext.bot",
      "name" => "Context Bot",
      "createdAt" => DateTime.to_iso8601(~U[2026-08-25 12:00:00Z])
    }

    {:ok, 200, %{}, %{"value" => record}}
  end

  def get_record(_repo, "site.standard.document", rkey) do
    if String.starts_with?(rkey, "prompt-") do
      record = %{
        "$type" => "site.standard.document",
        "textContent" => Request.system_prompt()
      }

      {:ok, 200, %{}, %{"value" => record}}
    else
      {:error, :record_not_found}
    end
  end

  def put_record(_repo, "site.standard.document", rkey, _record) do
    if String.starts_with?(rkey, "prompt-") do
      {:ok, 200, %{}, %{}}
    else
      {:error,
       {:permanent, 400,
        %{
          "error" => "InvalidRequest",
          "message" => "Lexicon not found: site.standard.document"
        }}}
    end
  end
end

defmodule FakePromptDocumentExists do
  @moduledoc false

  alias ContextBot.Research.Request

  def get_record(_repo, "site.standard.document", rkey) do
    record = %{
      "$type" => "site.standard.document",
      "textContent" => Request.system_prompt(),
      "title" => "Context Bot system prompt #{Request.system_prompt_id()}"
    }

    send(self(), {:standard_site_get, "site.standard.document", rkey})
    {:ok, 200, %{}, %{"value" => record}}
  end
end

defmodule FakePromptDocumentMismatch do
  @moduledoc false

  def get_record(_repo, "site.standard.document", _rkey) do
    record = %{
      "$type" => "site.standard.document",
      "textContent" => "CONTEXT_BOT_SYSTEM_V4\n\nstale prompt"
    }

    {:ok, 200, %{}, %{"value" => record}}
  end
end
