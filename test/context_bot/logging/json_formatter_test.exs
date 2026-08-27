defmodule ContextBot.Logging.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias ContextBot.Logging.JSONFormatter

  test "formats one JSON line with only allowlisted scalar metadata" do
    event = %{
      level: :info,
      msg: {:string, "research_finished"},
      meta: %{
        time: 1_786_386_000_000_000,
        invocation_id: 42,
        stage: :researching,
        duration_ms: 125,
        raw_thread: "never log this",
        request: %{"messages" => ["secret prompt"]},
        api_key: "sk-ant-secret"
      }
    }

    line = event |> JSONFormatter.format(%{}) |> IO.iodata_to_binary()

    assert String.ends_with?(line, "\n")
    refute String.contains?(String.trim_trailing(line), "\n")

    assert %{
             "timestamp" => "2026-08-10T18:20:00.000000Z",
             "severity" => "info",
             "message" => "logger_event",
             "invocation_id" => 42,
             "stage" => "researching",
             "duration_ms" => 125
           } = Jason.decode!(line)

    refute line =~ "never log this"
    refute line =~ "secret prompt"
    refute line =~ "sk-ant-secret"
  end

  test "replaces arbitrary messages and rejects nested metadata" do
    secret = "Bearer provider-secret"

    for message <- [
          {:string, secret},
          {:report, %{label: {:error_logger, :error_report}, report: %{reason: secret}}},
          {~c"failed: ~s", [secret]}
        ] do
      line =
        %{level: :error, msg: message, meta: %{time: 0, failure_reason: secret}}
        |> JSONFormatter.format(%{})
        |> IO.iodata_to_binary()

      assert %{"message" => "logger_event", "severity" => "error"} = Jason.decode!(line)
      refute line =~ secret
    end
  end

  test "redacts token-shaped arbitrary messages that merely look like event names" do
    for secret <- ["privatequestion", "password123", "skantsecret"] do
      line =
        %{level: :error, msg: {:string, secret}, meta: %{time: 0}}
        |> JSONFormatter.format(%{})
        |> IO.iodata_to_binary()

      assert %{"message" => "logger_event"} = Jason.decode!(line)
      refute line =~ secret
    end
  end

  test "keeps the complete operational scalar allowlist" do
    metadata = %{
      time: 0,
      invocation_id: 7,
      job_id: 8,
      queue: "research",
      worker: "ContextBot.Workers.ResearchWorker",
      attempt: 2,
      attempt_kind: :research,
      attempt_index: 1,
      stage: :researching,
      duration_ms: 99,
      input_tokens: 1_000,
      output_tokens: 200,
      cache_creation_input_tokens: 30,
      cache_read_input_tokens: 40,
      tool_uses: 2,
      web_search_uses: 1,
      cost_microdollars: 12_345,
      failure_category: :provider_response,
      failure_reason: :interrupted_after_send,
      remaining_ms: 12_345,
      action: :new_attempt,
      request_id: "request-safe-id",
      method: "GET",
      path: "/health",
      status: 200,
      status_code: 200
    }

    decoded =
      %{level: :info, msg: {:string, "context_bot_interrupt_recovery"}, meta: metadata}
      |> JSONFormatter.format(%{})
      |> IO.iodata_to_binary()
      |> Jason.decode!()

    assert decoded["message"] == "context_bot_interrupt_recovery"

    for {key, value} <- Map.delete(metadata, :time) do
      assert decoded[Atom.to_string(key)] == normalize(value)
    end
  end

  test "falls back to a safe JSON line for malformed events" do
    assert %{"message" => "logger_format_error", "severity" => "error"} =
             %{unexpected: self()}
             |> JSONFormatter.format(%{})
             |> IO.iodata_to_binary()
             |> Jason.decode!()
  end

  test "Phoenix HTTP request logs are redacted as logger_event without Phoenix.Logger" do
    phoenix_start_log = %{
      level: :info,
      msg: {:string, "GET /health"},
      meta: %{time: 0, request_id: "test-request-id"}
    }

    phoenix_stop_log = %{
      level: :info,
      msg: {:string, "Sent 200 in 2ms"},
      meta: %{time: 0, request_id: "test-request-id"}
    }

    for event <- [phoenix_start_log, phoenix_stop_log] do
      line =
        event
        |> JSONFormatter.format(%{})
        |> IO.iodata_to_binary()

      decoded = Jason.decode!(line)
      assert decoded["message"] == "logger_event"
      assert decoded["request_id"] == "test-request-id"
      refute line =~ "GET"
      refute line =~ "health"
      refute line =~ "Sent"
      refute line =~ "200"
      refute line =~ "2ms"
    end
  end

  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value
end
