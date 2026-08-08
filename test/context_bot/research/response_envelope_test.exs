defmodule ContextBot.Research.ResponseEnvelopeTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.ResponseEnvelope

  test "bounds retained envelope overhead without changing the raw body" do
    raw_body = <<0, 255, 128, 65, 0, 254>>

    response = %{
      status: 200,
      headers: %{
        "anthropic-ratelimit-requests-remaining" => [String.duplicate("7", 262_144)],
        "content-type" => ["application/json"]
      },
      raw_body: raw_body,
      received_at: ~U[2026-07-29 12:00:00.123456Z],
      duration_ms: 17
    }

    prepared =
      ResponseEnvelope.prepare(response, %{
        attempt_key: "invocation-1-attempt-1-research",
        kind: :research
      })

    assert ResponseEnvelope.max_overhead_bytes() == 65_536
    assert prepared.raw_body == raw_body
    assert prepared.storage_bytes - byte_size(raw_body) <= 65_536

    metadata = :erlang.binary_to_term(prepared.metadata_blob, [:safe])
    assert metadata.headers_truncated == true
  end
end
