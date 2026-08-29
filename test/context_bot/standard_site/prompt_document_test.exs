defmodule ContextBot.StandardSite.PromptDocumentTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.Research.Request
  alias ContextBot.StandardSite.PromptDocument

  @repo "did:plc:test123abc"
  @publication_uri "at://#{@repo}/site.standard.publication/context-bot"
  @created_at ~U[2026-08-25 12:00:00Z]

  describe "ensure_exists/4" do
    test "creates the hashed prompt document when it is missing" do
      assert {:ok, result} =
               PromptDocument.ensure_exists(
                 FakeStandardSiteTrackingClient,
                 @repo,
                 @publication_uri,
                 @created_at
               )

      rkey = Request.system_prompt_rkey()
      assert result.rkey == rkey
      assert result.uri == "at://#{@repo}/site.standard.document/#{rkey}"
      assert result.reader_url == "https://standard-reader.app/a/#{@repo}/#{rkey}"

      assert_received {:standard_site_get, "site.standard.document", ^rkey}

      assert_received {:standard_site_put, "site.standard.document", ^rkey, record}

      assert record["$type"] == "site.standard.document"
      assert record["site"] == @publication_uri
      assert record["textContent"] == Request.system_prompt()
      assert record["title"] =~ Request.system_prompt_id()
      markdown = record["content"]["text"]["markdown"]
      assert markdown =~ Request.system_prompt_id()
      assert markdown =~ Request.system_prompt_semantic_version()
      assert markdown =~ Request.system_prompt_sha256()
      assert markdown =~ Request.system_prompt()
      assert markdown =~ "LENGTH_REPAIR"
      assert markdown =~ Request.length_repair_sha256()
      assert markdown =~ "Hidden model reasoning is not available"
      refute markdown =~ "Funded for"
      refute markdown =~ "Funded from the community pot"
      refute markdown =~ "GitHub Sponsors"
    end

    test "keeps the published prompt bytes identical to the versioned system prompt" do
      assert {:ok, _result} =
               PromptDocument.ensure_exists(
                 FakeStandardSiteTrackingClient,
                 @repo,
                 @publication_uri,
                 @created_at
               )

      assert_received {:standard_site_get, "site.standard.document", _rkey}
      assert_received {:standard_site_put, "site.standard.document", _rkey, record}
      assert record["textContent"] == Request.system_prompt()
      assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V5"
      refute record["textContent"] =~ "Funded for"
    end

    test "reuses a matching prompt document without rewriting it" do
      assert {:ok, result} =
               PromptDocument.ensure_exists(
                 FakePromptDocumentExists,
                 @repo,
                 @publication_uri,
                 @created_at
               )

      rkey = Request.system_prompt_rkey()
      assert result.rkey == rkey
      assert result.reader_url == "https://standard-reader.app/a/#{@repo}/#{rkey}"
      assert_received {:standard_site_get, "site.standard.document", ^rkey}
      refute_received {:standard_site_put, "site.standard.document", _, _}
    end

    test "fails closed when the stored prompt bytes do not match" do
      assert {:error, :prompt_document_conflict} =
               PromptDocument.ensure_exists(
                 FakePromptDocumentMismatch,
                 @repo,
                 @publication_uri,
                 @created_at
               )
    end

    test "returns the put_record error when create fails" do
      assert {:error, :timeout} =
               PromptDocument.ensure_exists(
                 FakeDocClientFailure,
                 @repo,
                 @publication_uri,
                 @created_at
               )
    end
  end
end
