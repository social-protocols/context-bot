defmodule ContextBot.Research.AnthropicClientTest.RequestCapture do
  @moduledoc false

  def attach(request) do
    Req.Request.prepend_request_steps(request,
      capture_anthropic_options: fn request ->
        if pid = Process.get(:anthropic_client_capture_pid) do
          send(pid, {:anthropic_client_options, request.options})
        end

        request
      end
    )
  end
end

defmodule ContextBot.Research.AnthropicClientTest.PoolCheckoutFailureAdapter do
  @moduledoc false

  @error_message """
  Finch was unable to provide a connection within the timeout due to excess queuing for connections. Consider adjusting the pool size, count, timeout or reducing the rate of requests if it is possible that the downstream service is unable to keep up with the current rate.
  """

  def run(_request), do: raise(@error_message)
end

defmodule ContextBot.Research.AnthropicClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContextBot.Research.AnthropicClient
  alias ContextBot.Research.AnthropicClientTest.PoolCheckoutFailureAdapter

  @api_key "anthropic-test-key-never-expose"
  @attempt_metadata %{invocation_id: "invocation-123", attempt_number: 2}
  @request %{
    "model" => "claude-sonnet-5-20260203",
    "max_tokens" => 512,
    "messages" => [%{"role" => "user", "content" => "Give context"}],
    "stream" => true
  }

  setup {Req.Test, :verify_on_exit!}

  test "posts a non-streaming JSON message with the required Anthropic headers" do
    raw_body = fixture("success.json")
    Process.put(:anthropic_client_capture_pid, self())
    on_exit(fn -> Process.delete(:anthropic_client_capture_pid) end)

    Req.Test.expect(AnthropicClient, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.anthropic.test"
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@api_key]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/json")
      assert conn.body_params == Map.put(@request, "stream", false)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("request-id", "req_success")
      |> Plug.Conn.put_resp_header("retry-after", "11")
      |> Plug.Conn.put_resp_header("anthropic-ratelimit-requests-remaining", "4")
      |> Plug.Conn.put_resp_header("server", "unsafe-upstream-detail")
      |> Plug.Conn.put_resp_header("x-api-key", @api_key)
      |> Plug.Conn.send_resp(200, raw_body)
    end)

    assert {:ok, envelope} = AnthropicClient.send_message(@request, @attempt_metadata)

    assert envelope.status == 200
    assert envelope.raw_body == raw_body

    assert envelope.headers == %{
             "anthropic-ratelimit-requests-remaining" => ["4"],
             "content-type" => ["application/json"],
             "request-id" => ["req_success"],
             "retry-after" => ["11"]
           }

    assert %DateTime{time_zone: "Etc/UTC"} = envelope.received_at
    assert is_integer(envelope.duration_ms) and envelope.duration_ms >= 0
    refute Map.has_key?(envelope, :attempt_metadata)

    assert_receive {:anthropic_client_options, options}

    assert options.finch == [
             name: ContextBot.Finch,
             pool_timeout: 5_000,
             receive_timeout: 1_000,
             request_timeout: 6_000
           ]

    assert options.retry == false
    assert options.redirect == false
    assert options.raw == true
    assert options.finch_private == %{context_bot_attempt: @attempt_metadata}
    refute inspect(options.finch_private) =~ @api_key
    refute Map.has_key?(options, :receive_timeout)
    refute Map.has_key?(options, :request_timeout)
  end

  test "uses the runtime Anthropic API version and HTTP timeout without test overrides" do
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_config = Application.fetch_env!(:context_bot, AnthropicClient)

    settings =
      original_settings
      |> Map.put(:anthropic_api_version, "2027-08-09")
      |> Map.put(:anthropic_http_timeout_ms, 23_456)

    Application.put_env(:context_bot, :settings, settings)
    Application.put_env(:context_bot, AnthropicClient, Keyword.delete(original_config, :timeout))
    Process.put(:anthropic_client_capture_pid, self())

    on_exit(fn ->
      Application.put_env(:context_bot, :settings, original_settings)
      Application.put_env(:context_bot, AnthropicClient, original_config)
      Process.delete(:anthropic_client_capture_pid)
    end)

    Req.Test.expect(AnthropicClient, fn conn ->
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2027-08-09"]
      Req.Test.json(conn, %{"type" => "message"})
    end)

    assert {:ok, %{status: 200}} =
             AnthropicClient.send_message(@request, @attempt_metadata)

    assert_receive {:anthropic_client_options, options}
    assert options.finch[:receive_timeout] == 23_456
    assert options.finch[:request_timeout] == 28_456
  end

  test "returns pause, refusal, 429, and 5xx bodies as exact raw envelopes" do
    cases = [
      {200, "pause.json"},
      {200, "refusal.json"},
      {429, "error.json"},
      {503, "error.json"}
    ]

    Enum.each(cases, fn {status, fixture_name} ->
      raw_body = fixture(fixture_name)

      Req.Test.expect(AnthropicClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(status, raw_body)
      end)

      assert {:ok, %{status: ^status, raw_body: ^raw_body}} =
               AnthropicClient.send_message(@request, @attempt_metadata)
    end)
  end

  test "maps response overflow before decoding" do
    original_settings = Application.fetch_env!(:context_bot, :settings)
    limited_settings = %{original_settings | max_response_bytes: 4}
    Application.put_env(:context_bot, :settings, limited_settings)

    on_exit(fn -> Application.put_env(:context_bot, :settings, original_settings) end)

    Req.Test.expect(AnthropicClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("content-length", "5")
      |> Plug.Conn.send_resp(200, "12345")
    end)

    assert AnthropicClient.send_message(@request, @attempt_metadata) ==
             {:error, :response_too_large}
  end

  test "distinguishes timeouts from other transport failures without leaking the API key" do
    Req.Test.expect(AnthropicClient, &Req.Test.transport_error(&1, :timeout))

    timeout_log =
      capture_log(fn ->
        send(self(), {:client_result, AnthropicClient.send_message(@request, @attempt_metadata)})
      end)

    assert_receive {:client_result, {:error, :timeout}}
    refute timeout_log =~ @api_key

    Req.Test.expect(AnthropicClient, &Req.Test.transport_error(&1, :closed))

    transport_log =
      capture_log(fn ->
        send(self(), {:client_result, AnthropicClient.send_message(@request, @attempt_metadata)})
      end)

    assert_receive {:client_result, {:error, :transport}}
    refute transport_log =~ @api_key
    refute inspect({:error, :transport}) =~ @api_key
  end

  test "normalizes only Finch pool checkout exhaustion without leaking the API key" do
    original_config = Application.fetch_env!(:context_bot, AnthropicClient)
    original_api_key = Application.fetch_env!(:context_bot, :anthropic_api_key)

    Application.put_env(
      :context_bot,
      AnthropicClient,
      Keyword.put(original_config, :req_options, adapter: PoolCheckoutFailureAdapter)
    )

    on_exit(fn ->
      Application.put_env(:context_bot, AnthropicClient, original_config)
      Application.put_env(:context_bot, :anthropic_api_key, original_api_key)
    end)

    log =
      capture_log(fn ->
        send(self(), {:client_result, AnthropicClient.send_message(@request, @attempt_metadata)})
      end)

    assert_receive {:client_result, result}
    assert result == {:error, :transport}
    refute log =~ @api_key
    refute inspect(result) =~ @api_key

    Application.delete_env(:context_bot, :anthropic_api_key)

    assert_raise ArgumentError, fn ->
      AnthropicClient.send_message(@request, @attempt_metadata)
    end
  end

  defp fixture(name) do
    Path.expand("../../fixtures/anthropic/#{name}", __DIR__)
    |> File.read!()
  end
end
