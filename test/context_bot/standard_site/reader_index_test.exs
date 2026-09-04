defmodule ContextBot.StandardSite.ReaderIndexTest do
  use ExUnit.Case, async: true

  alias ContextBot.StandardSite.ReaderIndex

  @uri "at://did:plc:bot/site.standard.document/3kfullresp"

  describe "classify/3" do
    test "treats a 200 with matching uri and hasRenderableBody as indexed" do
      body = %{
        "uri" => @uri,
        "title" => "Gulf of America naming",
        "hasRenderableBody" => true,
        "content" => %{"text" => %{"markdown" => "## Summary\n\nHello"}}
      }

      assert ReaderIndex.classify(200, body, @uri) == :indexed
    end

    test "does not treat a 200 SPA-like card without a renderable body as indexed" do
      body = %{
        "uri" => @uri,
        "title" => "Article",
        "hasRenderableBody" => false
      }

      assert ReaderIndex.classify(200, body, @uri) == :ambiguous
    end

    test "does not treat a 200 for a different document as indexed" do
      body = %{
        "uri" => "at://did:plc:other/site.standard.document/other",
        "title" => "Other title",
        "hasRenderableBody" => true
      }

      assert ReaderIndex.classify(200, body, @uri) == :ambiguous
    end

    test "treats InvalidRequest Document not found as not indexed" do
      body = %{"error" => "InvalidRequest", "message" => "Document not found"}

      assert ReaderIndex.classify(400, body, @uri) == :not_indexed
    end

    test "treats RecordNotFound as not indexed" do
      assert ReaderIndex.classify(404, %{"error" => "RecordNotFound"}, @uri) == :not_indexed
    end

    test "treats timeouts and 5xx as ambiguous so the mirror stays up" do
      assert ReaderIndex.classify(503, %{"error" => "Unavailable"}, @uri) == :ambiguous
      assert ReaderIndex.classify(200, "not-json", @uri) == :ambiguous
    end
  end
end
