defmodule ContextBot.StandardSite.TitleCompletionTest do
  use ExUnit.Case, async: true

  alias ContextBot.StandardSite.{TitleCompletion, TitlePrompt}

  @settings %{anthropic_model_id: "claude-sonnet-5"}
  @invocation "@getcontext.bot Were these East Potomac tree removals actually part of Trump's federal takeover?"

  defmodule SuccessClient do
    @moduledoc false

    def send_message(request, metadata) do
      send(self(), {:title_send, request, metadata})

      {:ok,
       %{
         status: 200,
         headers: %{},
         raw_body:
           Jason.encode!(%{
             "content" => [%{"type" => "text", "text" => "  \"East Potomac Tree Removals\"  "}],
             "usage" => %{"input_tokens" => 40, "output_tokens" => 8}
           }),
         received_at: ~U[2026-08-30 12:00:00Z],
         duration_ms: 9
       }}
    end
  end

  defmodule EmptyClient do
    @moduledoc false

    def send_message(_request, _metadata) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         raw_body: Jason.encode!(%{"content" => [%{"type" => "text", "text" => "   "}]}),
         received_at: ~U[2026-08-30 12:00:00Z],
         duration_ms: 4
       }}
    end
  end

  defmodule HttpErrorClient do
    @moduledoc false

    def send_message(_request, _metadata) do
      {:ok,
       %{
         status: 500,
         headers: %{},
         raw_body: "{}",
         received_at: ~U[2026-08-30 12:00:00Z],
         duration_ms: 3
       }}
    end
  end

  defmodule TransportClient do
    @moduledoc false

    def send_message(_request, _metadata), do: {:error, :transport}
  end

  defmodule BoomClient do
    @moduledoc false

    def send_message(_request, _metadata), do: raise("title client exploded")
  end

  test "builds a small tool-free title request from the raw invocation" do
    request = TitleCompletion.request(@invocation, @settings)

    assert request["model"] == "claude-sonnet-5"
    assert request["max_tokens"] == TitleCompletion.max_tokens()
    assert request["max_tokens"] <= 128
    assert request["stream"] == false
    assert request["system"] == TitlePrompt.prompt()

    assert request["messages"] == [
             %{"role" => "user", "content" => TitlePrompt.user_message(@invocation)}
           ]

    refute Map.has_key?(request, "tools")
    refute Map.has_key?(request, "tool_choice")
    refute request["system"] =~ "CONTEXT_BOT_SYSTEM_V5"
    refute inspect(request) =~ "web_search"
    refute inspect(request) =~ "web_fetch"
    refute inspect(request) =~ "code_execution"
  end

  test "returns the first text completion and does not declare tools" do
    assert {:ok, "East Potomac Tree Removals"} =
             TitleCompletion.complete(@invocation, settings: @settings, client: SuccessClient)

    assert_received {:title_send, request, metadata}
    refute Map.has_key?(request, "tools")
    assert request["system"] == TitlePrompt.prompt()

    assert request["messages"] == [
             %{"role" => "user", "content" => TitlePrompt.user_message(@invocation)}
           ]

    assert metadata.kind == :title
  end

  test "skips the provider when the invoking-post text is blank" do
    assert TitleCompletion.complete("   ", settings: @settings, client: BoomClient) == :error
    assert TitleCompletion.complete(nil, settings: @settings, client: BoomClient) == :error
  end

  test "returns error for empty, HTTP, transport, and raised failures" do
    opts = [settings: @settings]

    assert TitleCompletion.complete(@invocation, Keyword.put(opts, :client, EmptyClient)) ==
             :error

    assert TitleCompletion.complete(@invocation, Keyword.put(opts, :client, HttpErrorClient)) ==
             :error

    assert TitleCompletion.complete(@invocation, Keyword.put(opts, :client, TransportClient)) ==
             :error

    assert TitleCompletion.complete(@invocation, Keyword.put(opts, :client, BoomClient)) ==
             :error
  end
end
