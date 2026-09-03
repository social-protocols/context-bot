defmodule ContextBot.Research.RunnerTest.Client do
  @moduledoc false

  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry

  def send_message(request, metadata) do
    test_pid = Process.get(:runner_test_pid)
    send(test_pid, {:anthropic_call, request, metadata, Repo.in_transaction?()})

    entry = Repo.get_by!(BudgetEntry, attempt_key: metadata.attempt_key)
    send(test_pid, {:attempt_at_send, entry.state, entry.sent_at, entry.response_recorded_at})

    if hook = Process.get(:runner_client_hook), do: hook.()

    [result | rest] = Process.get(:runner_client_results)
    Process.put(:runner_client_results, rest)
    result
  end
end

defmodule ContextBot.Research.RunnerTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Research.{
    Budget,
    BudgetEntry,
    Citations,
    ReplyLimits,
    Request,
    ResponseEnvelope,
    Runner
  }

  alias ContextBot.Research.StructuredFixtures
  alias ContextBot.Workflow.{Invocation, Store}
  alias Ecto.Adapters.SQL

  @now ~U[2026-07-29 12:00:00.123456Z]
  @claim_token "runner-test-claim"

  setup do
    Process.put(:runner_test_pid, self())

    on_exit(fn ->
      Process.delete(:runner_test_pid)
      Process.delete(:runner_client_results)
      Process.delete(:runner_client_hook)
    end)

    :ok
  end

  test "uses the configured server tool versions in the durable initial request" do
    invocation = invocation("configured-tools")
    Process.put(:runner_client_results, two_phase_results())

    custom_settings =
      settings()
      |> Map.put(:anthropic_web_search_tool_type, "web_search_20270809")
      |> Map.put(:anthropic_web_fetch_tool_type, "web_fetch_20270809")

    assert {:ok, _result} = Runner.run(invocation, options(settings: custom_settings))

    assert_received {:anthropic_call, request, %{kind: :research}, false}
    assert_received {:anthropic_call, structure, %{kind: :structure}, false}

    assert Enum.map(request["tools"], & &1["type"]) == [
             "web_search_20270809",
             "web_fetch_20270809"
           ]

    assert request["output_config"]["effort"] == "medium"
    refute Map.has_key?(request["output_config"], "format")
    assert Enum.at(request["tools"], 1)["citations"] == %{"enabled" => true}

    refute Map.has_key?(structure, "tools")
    refute Map.has_key?(structure, "thinking")
    refute Map.has_key?(structure, "effort")
    refute Map.has_key?(structure["output_config"], "effort")
    refute get_in(structure, ["thinking", "type"]) == "adaptive"
    assert structure["output_config"]["format"]["type"] == "json_schema"
    assert structure["output_config"]["format"]["schema"] == Request.structure_schema()

    refute Map.has_key?(
             structure["output_config"]["format"]["schema"]["properties"],
             "full_response"
           )

    assert Repo.reload!(invocation).anthropic_messages == structure
  end

  test "checkpoints version 2 image blocks before the provider call" do
    image_url =
      "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:actor/bafkreiimage@jpeg"

    invocation =
      invocation("image-request", %{
        canonical_thread: "CONTEXT_BOT_THREAD_V2\n\n[image 1] Alt text: Aurora",
        canonical_thread_version: "2",
        canonical_media: [
          %{
            "type" => "image",
            "index" => 1,
            "post_uri" => "at://did:plc:actor/app.bsky.feed.post/image-request",
            "url" => image_url,
            "alt" => "Aurora"
          }
        ]
      })

    Process.put(:runner_client_results, two_phase_results())

    assert {:ok, _result} = Runner.run(invocation, options())
    assert_received {:anthropic_call, request, %{kind: :research}, false}

    assert get_in(request, ["messages", Access.at(0), "content"]) == [
             %{
               "type" => "image",
               "source" => %{"type" => "url", "url" => image_url}
             },
             %{
               "type" => "text",
               "text" => "CONTEXT_BOT_THREAD_V2\n\n[image 1] Alt text: Aurora"
             }
           ]

    assert_received {:anthropic_call, _structure, %{kind: :structure}, false}
  end

  test "rejects malformed persisted canonical media before budget or provider work" do
    valid = %{
      "type" => "image",
      "index" => 1,
      "post_uri" => "at://did:plc:actor/app.bsky.feed.post/media-validation",
      "url" => "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:actor/bafkreivalid@jpeg",
      "alt" => "Valid"
    }

    long_did = "did:plc:" <> String.duplicate("a", 1_950)

    oversized =
      Enum.map(1..4, fn index ->
        %{
          "type" => "image",
          "index" => index,
          "post_uri" =>
            "at://#{long_did}/app.bsky.feed.post/#{String.duplicate("r", 500)}#{index}",
          "url" =>
            "https://cdn.bsky.app/img/feed_fullsize/plain/#{String.duplicate("u", 1_990)}#{index}",
          "alt" => String.duplicate("a", 4_096)
        }
      end)

    invalid_media = [
      [Map.put(valid, "url", "https://example.com/img/feed_fullsize/plain/a/b@jpeg")],
      Enum.map(1..5, &Map.put(valid, "index", &1)),
      [Map.delete(valid, "alt")],
      [Map.put(valid, "index", 2)],
      [Map.put(valid, "alt", String.duplicate("a", 4_097))],
      oversized
    ]

    Process.put(:runner_client_results, [])

    Enum.with_index(invalid_media, 1)
    |> Enum.each(fn {media, index} ->
      invocation =
        invocation("invalid-media-#{index}", %{
          canonical_thread: "CONTEXT_BOT_THREAD_V2\n\nInvalid stored media",
          canonical_thread_version: "2",
          canonical_media: media
        })

      assert {:error, :invalid_canonical_thread} = Runner.run(invocation, options())
    end)

    assert Repo.aggregate(BudgetEntry, :count) == 0
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "commits a complete 200 envelope and sent marker before decoding" do
    invocation = invocation("persist-before-decode")
    raw_body = fixture("tool_success.json")
    Process.put(:runner_client_results, two_phase_results(raw_body))

    decoder = fn body ->
      stored = hd(responses(invocation))
      entry = Repo.get_by!(BudgetEntry, attempt_key: stored.attempt_key)

      send(self(), {
        :decode_observed,
        stored.raw_body,
        stored.status,
        entry.response_recorded_at
      })

      Jason.decode(body)
    end

    assert {:ok, result} = Runner.run(invocation, options(decoder: decoder))
    assert result.text == "Useful context from primary sources."

    assert result.full_response ==
             "Useful context from primary sources.\n\n## Sources\n\n- https://primary.example/report"

    assert result.document_title == "Primary Sources"

    assert_received {:attempt_at_send, :sent, %DateTime{}, nil}
    assert_received {:decode_observed, ^raw_body, 200, %DateTime{}}

    [research_stored, structure_stored] = responses(invocation)
    assert research_stored.raw_body == raw_body
    assert research_stored.attempt_key =~ "-attempt-1-research"
    assert research_stored.kind == :research
    assert structure_stored.kind == :structure
    assert structure_stored.attempt_key =~ "-attempt-2-structure"

    for stored <- [research_stored, structure_stored] do
      entry = Repo.get_by!(BudgetEntry, attempt_key: stored.attempt_key)
      assert entry.state == :settled
      assert entry.response_recorded_at != nil
    end
  end

  test "a capacity change after preflight is caught before decode or another request" do
    invocation = invocation("persistence-failure")
    raw_body = fixture("tool_success.json")
    Process.put(:runner_client_results, [{:ok, envelope(200, raw_body)}])

    Process.put(:runner_client_hook, fn ->
      prepared =
        ResponseEnvelope.prepare(
          envelope(503, String.duplicate("occupied-after-preflight", 3_000))
        )

      %ResponseEnvelope{}
      |> ResponseEnvelope.changeset(Map.put(prepared, :invocation_id, invocation.id))
      |> Repo.insert!()
    end)

    decoder = fn _body ->
      send(self(), :decoder_called)
      {:ok, %{}}
    end

    constrained_settings =
      settings()
      |> Map.put(:max_response_bytes, 1)
      |> Map.put(
        :max_storage_bytes,
        Store.provider_response_storage_bytes(invocation) +
          ResponseEnvelope.max_overhead_bytes() + 1
      )

    assert {:error, :provider_storage_limit} =
             Runner.run(invocation, options(decoder: decoder, settings: constrained_settings))

    assert_received {:anthropic_call, _request, _metadata, false}
    refute_received :decoder_called
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert [%{status: 503}] = responses(invocation)

    entry = Repo.one!(BudgetEntry)
    assert entry.state == :sent
    assert entry.response_recorded_at == nil
  end

  test "refuses a new attempt before reservation when actual provider storage is insufficient" do
    invocation = invocation("storage-preflight-insufficient") |> seed_provider_storage()
    body = fixture("tool_success.json")
    required_bytes = byte_size(body) + ResponseEnvelope.max_overhead_bytes()
    used_bytes = actual_provider_storage_bytes(invocation)

    settings =
      settings()
      |> Map.put(:max_response_bytes, byte_size(body))
      |> Map.put(:max_storage_bytes, used_bytes + required_bytes - 1)

    Process.put(:runner_client_results, [])

    assert {:error, :provider_storage_limit} =
             Runner.run(invocation, options(settings: settings))

    assert Repo.aggregate(BudgetEntry, :count) == 0
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "starts a new attempt when actual provider storage is exactly sufficient" do
    invocation = invocation("storage-preflight-exact") |> seed_provider_storage()
    body = fixture("tool_success.json")
    required_bytes = byte_size(body) + ResponseEnvelope.max_overhead_bytes()
    used_bytes = actual_provider_storage_bytes(invocation)

    settings =
      settings()
      |> Map.put(:max_response_bytes, byte_size(body))
      |> Map.put(:max_storage_bytes, used_bytes + 2 * required_bytes)

    Process.put(:runner_client_results, two_phase_results(body))

    assert {:ok, _result} = Runner.run(invocation, options(settings: settings))
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), & &1.kind) == [
             :research,
             :structure
           ]
  end

  test "persists 429 before honoring retry-after and sends the retry under a new reservation" do
    invocation = invocation("retry-after")
    error_body = fixture("error.json")
    success_body = fixture("tool_success.json")

    Process.put(:runner_client_results, [
      {:ok, envelope(429, error_body, %{"retry-after" => ["7"]})},
      {:ok, envelope(200, success_body)},
      {:ok, envelope(200, fixture("structure_success.json"))}
    ])

    sleep = fn milliseconds ->
      [persisted_error] = responses(invocation)
      send(self(), {:retry_sleep, milliseconds, persisted_error.raw_body})
    end

    assert {:ok, result} = Runner.run(invocation, options(sleep: sleep))
    assert result.text == "Useful context from primary sources."
    assert_received {:retry_sleep, 7_000, ^error_body}

    entries = Repo.all(from entry in BudgetEntry, order_by: entry.id)
    assert Enum.map(entries, & &1.kind) == [:research, :retry, :structure]

    assert Enum.map(entries, & &1.attempt_key) == [
             "invocation-#{invocation.id}-attempt-1-research",
             "invocation-#{invocation.id}-attempt-2-retry",
             "invocation-#{invocation.id}-attempt-3-structure"
           ]

    assert Enum.all?(entries, &(&1.response_recorded_at != nil))

    assert Enum.map(responses(invocation), & &1.raw_body) == [
             error_body,
             success_body,
             fixture("structure_success.json")
           ]
  end

  test "persists 500 before parsing an HTTP-date retry-after" do
    invocation = invocation("retry-http-date")
    error_body = fixture("error.json")
    success_body = fixture("tool_success.json")

    Process.put(:runner_client_results, [
      {:ok, envelope(500, error_body, %{"retry-after" => ["Wed, 29 Jul 2026 12:00:07 GMT"]})},
      {:ok, envelope(200, success_body)},
      {:ok, envelope(200, fixture("structure_success.json"))}
    ])

    sleep = fn milliseconds ->
      [persisted_error] = responses(invocation)
      send(self(), {:http_date_retry_sleep, milliseconds, persisted_error.raw_body})
    end

    assert {:ok, _result} = Runner.run(invocation, options(sleep: sleep))
    assert_received {:http_date_retry_sleep, 7_000, ^error_body}
  end

  test "persists auth and malformed responses and fails closed without retry" do
    for {suffix, status, body, expected_reason} <- [
          {"auth", 401, fixture("error.json"), :provider_auth},
          {"malformed", 200, "{not-json", :malformed_provider_response}
        ] do
      invocation = invocation(suffix)
      Process.put(:runner_client_results, [{:ok, envelope(status, body)}])

      assert {:error, ^expected_reason} = Runner.run(invocation, options())
      assert_received {:anthropic_call, _request, _metadata, false}
      refute_received {:anthropic_call, _request, _metadata, _in_transaction}
      assert [stored] = responses(invocation)
      assert stored.raw_body == body
    end
  end

  test "surfaces an Anthropic 400 error.message instead of a bare provider_response atom" do
    invocation = invocation("inv-22-adaptive-thinking")

    body =
      Jason.encode!(%{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "adaptive thinking is not supported on this model"
        },
        "request_id" => "req_inv22"
      })

    Process.put(:runner_client_results, [{:ok, envelope(400, body)}])

    decoder = fn _raw_body -> flunk("non-2xx response body must not use the success decoder") end

    assert {:error, {:provider_response, "adaptive thinking is not supported on this model"}} =
             Runner.run(invocation, options(decoder: decoder))

    assert_received {:anthropic_call, _request, _metadata, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert [stored] = responses(invocation)
    assert stored.raw_body == body
    assert stored.status == 400
  end

  test "classifies malformed non-retryable HTTP errors without decoding their bodies" do
    for {suffix, status, body, expected_reason} <- [
          {"empty-auth", 401, "", :provider_auth},
          {"html-auth", 403, "<html>forbidden</html>", :provider_auth},
          {"empty-client-error", 400, "", :provider_response},
          {"invalid-client-error", 422, <<255, 0, 254>>, :provider_response}
        ] do
      invocation = invocation(suffix)
      Process.put(:runner_client_results, [{:ok, envelope(status, body)}])

      decoder = fn _raw_body -> flunk("non-2xx response body must not be decoded") end

      assert {:error, ^expected_reason} = Runner.run(invocation, options(decoder: decoder))
      assert_received {:anthropic_call, _request, _metadata, false}
      refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    end
  end

  test "retries malformed 429 and 5xx bodies and still honors Retry-After" do
    for {suffix, status, body} <- [
          {"empty-429", 429, ""},
          {"html-503", 503, "<html>temporarily unavailable</html>"}
        ] do
      invocation = invocation(suffix)

      Process.put(:runner_client_results, [
        {:ok, envelope(status, body, %{"retry-after" => ["7"]})},
        {:ok, envelope(200, fixture("tool_success.json"))},
        {:ok, envelope(200, fixture("structure_success.json"))}
      ])

      sleep = fn milliseconds -> send(self(), {:malformed_retry_sleep, suffix, milliseconds}) end

      assert {:ok, _result} = Runner.run(invocation, options(sleep: sleep))
      assert_received {:malformed_retry_sleep, ^suffix, 7_000}
    end
  end

  test "reuses a reserved but unsent attempt after a crash" do
    invocation = invocation("crash-reserved")
    Process.put(:runner_client_results, two_phase_results())

    crash = crash_once(:after_reservation)

    assert_raise RuntimeError, "injected crash after_reservation", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    [reserved] = Repo.all(BudgetEntry)
    assert reserved.state == :reserved
    assert reserved.attempt_key =~ "-attempt-1-research"
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert {:ok, _result} = Runner.run(invocation, options(crash: crash))

    assert [{:research, :settled, attempt_key}, {:structure, :settled, _structure_key}] =
             Enum.map(
               Repo.all(from entry in BudgetEntry, order_by: entry.id),
               &{&1.kind, &1.state, &1.attempt_key}
             )

    assert attempt_key == reserved.attempt_key
  end

  test "a crash after sent waits out the HTTP timeout without another provider call" do
    invocation = invocation("crash-sent")
    Process.put(:runner_client_results, two_phase_results())

    crash = crash_once(:after_sent)

    assert_raise RuntimeError, "injected crash after_sent", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert [%BudgetEntry{state: :sent, response_recorded_at: nil}] = Repo.all(BudgetEntry)
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert {:wait, 300_000} = Runner.run(invocation, options(crash: crash))
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert [{:research, :sent}] ==
             Enum.map(
               Repo.all(from entry in BudgetEntry, order_by: entry.id),
               &{&1.kind, &1.state}
             )
  end

  test "a crash after sent starts a new attempt once the HTTP timeout has elapsed" do
    invocation = invocation("crash-sent-elapsed")
    Process.put(:runner_client_results, two_phase_results())

    crash = crash_once(:after_sent)

    assert_raise RuntimeError, "injected crash after_sent", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert [%BudgetEntry{state: :sent, response_recorded_at: nil, attempt_key: first_key}] =
             Repo.all(BudgetEntry)

    later = DateTime.add(@now, 300_001, :millisecond)

    assert {:ok, _result} = Runner.run(invocation, options(crash: crash, now: fn -> later end))
    assert_received {:anthropic_call, _request, %{kind: :retry}, false}

    assert [
             {:research, :indeterminate, ^first_key},
             {:retry, :settled, retry_key},
             {:structure, :settled, _structure_key}
           ] =
             Enum.map(
               Repo.all(from entry in BudgetEntry, order_by: entry.id),
               &{&1.kind, &1.state, &1.attempt_key}
             )

    assert retry_key != first_key
  end

  test "an older unrecorded attempt inside the timeout does not send a newer reservation" do
    invocation = invocation("legacy-ambiguous-before-reserved")

    ambiguous = insert_budget_entry(invocation, 1, :research, :sent)
    reserved = insert_budget_entry(invocation, 2, :retry, :reserved)
    Process.put(:runner_client_results, [])

    assert {:wait, 300_000} = Runner.run(invocation, options())
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert Repo.reload!(ambiguous).state == :sent
    assert Repo.reload!(reserved).state == :reserved
  end

  test "an older unrecorded attempt past the timeout lets the reserved retry send once" do
    invocation = invocation("legacy-ambiguous-elapsed")
    ambiguous = insert_budget_entry(invocation, 1, :research, :sent)
    reserved = insert_budget_entry(invocation, 2, :retry, :reserved)
    Process.put(:runner_client_results, two_phase_results())
    later = DateTime.add(@now, 300_001, :millisecond)

    assert {:ok, _result} = Runner.run(invocation, options(now: fn -> later end))
    assert_received {:anthropic_call, _request, %{kind: :retry}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert Repo.reload!(ambiguous).state == :indeterminate
    assert Repo.reload!(reserved).state == :settled
  end

  test "a crash after HTTP return but before persistence never replays" do
    invocation = invocation("crash-http")
    body = fixture("tool_success.json")

    Process.put(:runner_client_results, [
      {:ok, envelope(200, body)},
      {:ok, envelope(200, body)}
    ])

    crash = crash_once(:after_http)

    assert_raise RuntimeError, "injected crash after_http", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert responses(invocation) == []
    assert [%BudgetEntry{state: :sent, response_recorded_at: nil}] = Repo.all(BudgetEntry)
    assert_received {:anthropic_call, _request, %{kind: :research}, false}

    assert {:wait, 300_000} = Runner.run(invocation, options(crash: crash))
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert [{:research, :sent}] ==
             Enum.map(
               Repo.all(from entry in BudgetEntry, order_by: entry.id),
               &{&1.kind, &1.state}
             )
  end

  test "a crash after response persistence resumes decode and settlement without another POST" do
    invocation = invocation("crash-persisted")
    body = fixture("tool_success.json")
    Process.put(:runner_client_results, two_phase_results(body))

    crash = crash_once(:after_persistence)

    assert_raise RuntimeError, "injected crash after_persistence", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert [%BudgetEntry{state: :sent, response_recorded_at: %DateTime{}}] =
             Repo.all(BudgetEntry)

    assert [stored] = responses(invocation)
    assert stored.raw_body == body
    assert_received {:anthropic_call, _request, %{kind: :research}, false}

    assert {:ok, _result} = Runner.run(invocation, options(crash: crash))
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), &{&1.kind, &1.state}) ==
             [
               {:research, :settled},
               {:structure, :settled}
             ]
  end

  test "a retained dynamic-filtering over-limit response resumes into a local split" do
    invocation = invocation("retained-code-execution-split")
    fixture = decoded_fixture("repair_success.json")
    {part1, part2, over_text} = over_limit_split_parts()

    tool_blocks =
      Enum.flat_map(1..6, fn index ->
        id = "srvtoolu_code_#{index}"

        [
          %{
            "type" => "server_tool_use",
            "id" => id,
            "name" => "code_execution",
            "input" => %{"code" => "opaque-#{index}"}
          },
          %{
            "type" => "code_execution_tool_result",
            "tool_use_id" => id,
            "content" => %{"type" => "code_execution_result", "content" => []}
          }
        ]
      end)

    primary =
      put_in(
        fixture,
        ["primary", "content"],
        tool_blocks ++ [writeup_text("Thorough markdown writeup.")]
      )["primary"]

    primary_raw = Jason.encode!(primary)
    structure_raw = Jason.encode!(message_body(structured_json(over_text)))

    Process.put(:runner_client_results, [
      {:ok, envelope(200, primary_raw)},
      {:ok, envelope(200, structure_raw)}
    ])

    crash = crash_once(:after_persistence)

    assert_raise RuntimeError, "injected crash after_persistence", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:attempt_at_send, :sent, %DateTime{}, nil}

    assert {:ok, result} = Runner.run(invocation, options(crash: crash))
    assert result.text == part1
    assert result.text_part2 == part2
    assert result.validation["result"] == "split"
    assert result.validation["repair_used"] == false

    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
    refute_received {:anthropic_call, _request, %{kind: :research}, _in_transaction}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}

    assert Enum.map(responses(invocation), & &1.raw_body) == [primary_raw, structure_raw]

    assert [{:research, :settled}, {:structure, :settled}] ==
             Repo.all(from entry in BudgetEntry, order_by: entry.id)
             |> Enum.map(&{&1.kind, &1.state})
  end

  test "a stale owner cannot send an unexposed reservation after lease takeover" do
    invocation = invocation("stale-reserved")

    assert {:ok, reserved} =
             Budget.reserve_next(
               invocation,
               :research,
               @now,
               1_000_000,
               5_000_000,
               @claim_token
             )

    assert {:ok, _new_owner} = take_over(invocation, "new-owner")
    Process.put(:runner_client_results, two_phase_results())

    assert {:error, :stale_claim} = Runner.run(invocation, options())
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert Repo.reload!(reserved).state == :reserved

    assert {:ok, _result} = Runner.run(invocation, options(claim_token: "new-owner"))
    assert_received {:anthropic_call, _request, %{attempt_key: attempt_key}, false}
    assert attempt_key == reserved.attempt_key
  end

  test "a new owner waits out an exposed attempt instead of replaying it" do
    invocation = invocation("stale-sent")
    Process.put(:runner_client_results, two_phase_results())
    crash = crash_once(:after_sent)

    assert_raise RuntimeError, "injected crash after_sent", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert [%BudgetEntry{state: :sent}] = Repo.all(BudgetEntry)
    assert {:ok, _new_owner} = take_over(invocation, "new-owner")

    assert {:error, :stale_claim} = Runner.run(invocation, options(crash: crash))
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert {:wait, 300_000} =
             Runner.run(invocation, options(claim_token: "new-owner", crash: crash))

    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert Enum.map(Repo.all(BudgetEntry), & &1.state) == [:sent]
  end

  test "a takeover after the sent marker stops the stale owner before POST" do
    invocation = invocation("stale-between-sent-and-post")
    Process.put(:runner_client_results, two_phase_results())

    takeover_after_sent = fn
      :after_sent, _entry ->
        assert {:ok, _new_owner} = take_over(invocation, "new-owner")
        :ok

      _point, _value ->
        :ok
    end

    assert {:error, :stale_claim} =
             Runner.run(invocation, options(crash: takeover_after_sent))

    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert [%BudgetEntry{state: :sent, response_recorded_at: nil}] = Repo.all(BudgetEntry)
  end

  test "a stale owner cannot append an envelope after takeover during its HTTP call" do
    invocation = invocation("stale-after-http")
    Process.put(:runner_client_results, two_phase_results())

    takeover_after_http = fn
      :after_http, _envelope ->
        assert {:ok, _new_owner} = take_over(invocation, "new-owner")
        :ok

      _point, _value ->
        :ok
    end

    assert {:error, :stale_claim} =
             Runner.run(invocation, options(crash: takeover_after_http))

    assert responses(invocation) == []
    assert [%BudgetEntry{state: :sent, response_recorded_at: nil}] = Repo.all(BudgetEntry)
  end

  test "a stale owner cannot settle or checkpoint after persisted response takeover" do
    invocation = invocation("stale-after-persistence")
    Process.put(:runner_client_results, two_phase_results())

    takeover_after_persistence = fn
      :after_persistence, _entry ->
        assert {:ok, _new_owner} = take_over(invocation, "new-owner")
        :ok

      _point, _value ->
        :ok
    end

    assert {:error, :stale_claim} =
             Runner.run(invocation, options(crash: takeover_after_persistence))

    persisted = Repo.reload!(invocation)
    assert persisted.anthropic_usage == nil

    assert [%BudgetEntry{state: :sent, response_recorded_at: %DateTime{}}] =
             Repo.all(BudgetEntry)
  end

  test "a takeover after settlement fences the usage checkpoint" do
    invocation = invocation("stale-usage-checkpoint")
    Process.put(:runner_client_results, two_phase_results())

    takeover_after_settlement = fn
      :after_settlement, _entry ->
        assert {:ok, _new_owner} = take_over(invocation, "new-owner")
        :ok

      _point, _value ->
        :ok
    end

    assert {:error, :stale_claim} =
             Runner.run(invocation, options(crash: takeover_after_settlement))

    assert Repo.reload!(invocation).anthropic_usage == nil
    assert [%BudgetEntry{state: :settled}] = Repo.all(BudgetEntry)
  end

  test "a takeover before a continuation request checkpoint stops without another POST" do
    invocation = invocation("stale-request-checkpoint")
    fixture = decoded_fixture("pause_then_success.json")

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(fixture["pause"]))},
      {:ok, envelope(200, Jason.encode!(fixture["success"]))},
      {:ok, envelope(200, fixture("structure_success.json"))}
    ])

    takeover_before_checkpoint = fn
      :before_request_checkpoint, _request ->
        assert {:ok, _new_owner} = take_over(invocation, "new-owner")
        :ok

      _point, _value ->
        :ok
    end

    assert {:error, :stale_claim} =
             Runner.run(invocation, options(crash: takeover_before_checkpoint))

    assert_received {:anthropic_call, initial_request, %{kind: :research}, false}
    refute_received {:anthropic_call, _request, %{kind: :continuation}, false}
    assert Repo.reload!(invocation).anthropic_messages == initial_request
  end

  test "every transport result after send is terminal and never retried" do
    for reason <- [:timeout, :transport, :response_too_large, :unknown_transport] do
      invocation = invocation("terminal-transport-#{reason}")
      Process.put(:runner_client_results, [{:error, reason}])

      assert {:error, :interrupted_after_send} = Runner.run(invocation, options())
      assert_received {:anthropic_call, _request, %{kind: :research}, false}
      refute_received {:anthropic_call, _request, _metadata, _in_transaction}

      assert [{:research, :indeterminate}] ==
               Enum.map(
                 Repo.all(
                   from entry in BudgetEntry,
                     where: entry.invocation_id == ^invocation.id,
                     order_by: entry.id
                 ),
                 &{&1.kind, &1.state}
               )
    end
  end

  test "continues pause turns with opaque content and aggregates all usage and tool counts" do
    invocation = invocation("pause-success")
    fixture = decoded_fixture("pause_then_success.json")
    pause_raw = Jason.encode!(fixture["pause"])
    success_raw = Jason.encode!(fixture["success"])

    structure_raw = fixture("structure_success.json")

    Process.put(:runner_client_results, [
      {:ok, envelope(200, pause_raw)},
      {:ok, envelope(200, success_raw)},
      {:ok, envelope(200, structure_raw)}
    ])

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == "Useful context from primary sources."

    assert result.full_response ==
             Citations.publishable_writeup(
               "The cited primary source resolves the disputed date.",
               [
                 %{
                   "url" => "https://primary.example/report",
                   "cited_text" => "The cited primary source resolves the disputed date."
                 }
               ]
             )

    assert result.usage["continuations"] == 1
    assert result.usage["tool_uses"] == 1
    assert result.usage["tool_use_counts"] == %{"web_fetch" => 0, "web_search" => 1}
    assert result.usage["totals"]["input_tokens"] == 350
    assert result.usage["totals"]["output_tokens"] == 70
    assert length(result.usage["attempts"]) == 3

    assert_received {:anthropic_call, initial_request, %{kind: :research}, false}
    assert_received {:anthropic_call, continued_request, %{kind: :continuation}, false}
    assert_received {:anthropic_call, structure_request, %{kind: :structure}, false}

    assert continued_request["messages"] ==
             initial_request["messages"] ++
               [%{"role" => "assistant", "content" => fixture["pause"]["content"]}]

    refute Map.has_key?(structure_request, "tools")

    assert Enum.at(fixture["pause"]["content"], 1)["type"] == "future_encrypted_trace"

    assert Enum.map(responses(invocation), & &1.raw_body) == [
             pause_raw,
             success_raw,
             structure_raw
           ]

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), & &1.kind) == [
             :research,
             :continuation,
             :structure
           ]
  end

  test "tracks code execution across a pause-turn continuation" do
    invocation = invocation("code-execution-pause-success")
    fixture = decoded_fixture("pause_then_success.json")

    pause =
      put_in(fixture, ["pause", "content"], [
        %{
          "type" => "server_tool_use",
          "id" => "code-pause-1",
          "name" => "code_execution",
          "input" => %{"code" => "opaque provider program"}
        }
      ])["pause"]

    success =
      put_in(fixture, ["success", "content"], [
        %{
          "type" => "code_execution_tool_result",
          "tool_use_id" => "code-pause-1",
          "content" => %{
            "type" => "code_execution_result",
            "stdout" => "opaque",
            "stderr" => "",
            "return_code" => 0,
            "content" => []
          }
        },
        writeup_text("Final context only.")
      ])["success"]

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(pause))},
      {:ok, envelope(200, Jason.encode!(success))},
      {:ok, envelope(200, Jason.encode!(message_body(structured_json("Final context only."))))}
    ])

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == "Final context only."
    assert result.usage["tool_use_counts"] == %{"web_fetch" => 0, "web_search" => 0}
    assert_received {:anthropic_call, _initial, %{kind: :research}, false}
    assert_received {:anthropic_call, _continued, %{kind: :continuation}, false}
  end

  test "selects model text from a bash_code_execution envelope without publishing stdout" do
    invocation = invocation("bash-code-execution-success")
    fixture = decoded_fixture("tool_success.json")

    body =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_bash_1",
          "name" => "bash_code_execution",
          "input" => %{"command" => "sleep 20 && echo done"}
        },
        %{
          "type" => "bash_code_execution_tool_result",
          "tool_use_id" => "srvtoolu_bash_1",
          "content" => %{
            "type" => "bash_code_execution_result",
            "stdout" => "done\n",
            "stderr" => "",
            "return_code" => 0,
            "content" => []
          }
        },
        writeup_text("Useful context from primary sources.")
      ])

    Process.put(:runner_client_results, two_phase_results(Jason.encode!(body)))

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == "Useful context from primary sources."
    refute result.text =~ "done"
    assert result.usage["tool_use_counts"] == %{"web_fetch" => 0, "web_search" => 0}
  end

  test "does not select a reply from a bash_code_execution envelope with return_code 1" do
    invocation = invocation("bash-code-execution-failed")
    fixture = decoded_fixture("tool_success.json")

    body =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_bash_1",
          "name" => "bash_code_execution",
          "input" => %{"command" => "web_search('Lake America')"}
        },
        %{
          "type" => "bash_code_execution_tool_result",
          "tool_use_id" => "srvtoolu_bash_1",
          "content" => %{
            "type" => "bash_code_execution_result",
            "stdout" => "",
            "stderr" => "encrypted-unreadable",
            "return_code" => 1,
            "content" => []
          }
        },
        %{"type" => "text", "text" => "must not publish"}
      ])

    Process.put(:runner_client_results, [{:ok, envelope(200, Jason.encode!(body))}])

    assert {:error, :code_execution_failed} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert [stored] = responses(invocation)
    assert stored.raw_body == Jason.encode!(body)
  end

  test "fails closed on unexpected_tool_use instead of selecting following model text" do
    invocation = invocation("unexpected-tool-use-fail-closed")
    fixture = decoded_fixture("tool_success.json")

    body =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_unknown_1",
          "name" => "future_server_tool",
          "input" => %{}
        },
        %{"type" => "text", "text" => "must not publish"}
      ])

    Process.put(:runner_client_results, [{:ok, envelope(200, Jason.encode!(body))}])

    assert {:error, :unexpected_tool_use} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "rejects malformed saved tool history before sending a continuation" do
    code_result = %{
      "type" => "code_execution_tool_result",
      "tool_use_id" => "history-call-1",
      "content" => %{"type" => "code_execution_result", "content" => []}
    }

    valid_code_call = %{
      "type" => "server_tool_use",
      "id" => "history-call-1",
      "name" => "code_execution",
      "input" => %{"code" => "opaque"}
    }

    cases = [
      {"malformed-input", [Map.put(valid_code_call, "input", "not-a-map")], [code_result]},
      {"mismatched-result",
       [
         %{
           "type" => "server_tool_use",
           "id" => "history-call-1",
           "name" => "web_search",
           "input" => %{"query" => "claim"}
         },
         code_result
       ], []},
      {"unknown-tool",
       [
         %{
           "type" => "server_tool_use",
           "id" => "history-call-1",
           "name" => "future_server_tool",
           "input" => %{}
         }
       ], []},
      {"reused-id", [valid_code_call, code_result, valid_code_call], [code_result]}
    ]

    Enum.each(cases, fn {suffix, pause_content, final_prefix} ->
      invocation = invocation("invalid-history-#{suffix}")
      fixture = decoded_fixture("pause_then_success.json")
      pause = put_in(fixture, ["pause", "content"], pause_content)["pause"]

      success =
        put_in(
          fixture,
          ["success", "content"],
          final_prefix ++ [%{"type" => "text", "text" => "must not publish"}]
        )["success"]

      Process.put(:runner_client_results, [
        {:ok, envelope(200, Jason.encode!(pause))},
        {:ok, envelope(200, Jason.encode!(success))}
      ])

      assert {:error, _reason} = Runner.run(invocation, options())
      assert_received {:anthropic_call, _request, %{kind: :research}, false}
      refute_received {:anthropic_call, _request, %{kind: :continuation}, false}
    end)
  end

  test "fails silently when the aggregate continuation cap is exceeded" do
    invocation = invocation("continuation-cap")
    fixture = decoded_fixture("pause_then_success.json")
    first_pause = fixture["pause"]

    second_pause =
      fixture["pause"]
      |> put_in(["id"], "msg_pause_2")
      |> put_in(["content"], [
        fixture["success"]["content"] |> hd(),
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_02",
          "name" => "web_fetch",
          "input" => %{"url" => "https://primary.example/report"}
        }
      ])

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(first_pause))},
      {:ok, envelope(200, Jason.encode!(second_pause))}
    ])

    settings = Map.put(settings(), :max_tool_continuations, 1)

    assert {:error, :continuation_limit_exceeded} =
             Runner.run(invocation, options(settings: settings))

    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :continuation}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert length(responses(invocation)) == 2
  end

  test "still selects a reply when web_search hits max_uses_exceeded" do
    invocation = invocation("search-cap-hit")
    fixture = decoded_fixture("tool_success.json")

    body =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_search_1",
          "name" => "web_search",
          "input" => %{"query" => "first source"}
        },
        %{
          "type" => "web_search_tool_result",
          "tool_use_id" => "srvtoolu_search_1",
          "content" => [
            %{
              "type" => "web_search_result",
              "url" => "https://example.test/first",
              "title" => "First",
              "encrypted_content" => "opaque",
              "page_age" => nil
            }
          ]
        },
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_search_2",
          "name" => "web_search",
          "input" => %{"query" => "one more"}
        },
        %{
          "type" => "web_search_tool_result",
          "tool_use_id" => "srvtoolu_search_2",
          "content" => %{
            "type" => "web_search_tool_result_error",
            "error_code" => "max_uses_exceeded"
          }
        },
        writeup_text("Useful context from primary sources.")
      ])

    Process.put(:runner_client_results, two_phase_results(Jason.encode!(body)))
    settings = Map.put(settings(), :max_web_search_uses, 1)

    assert {:ok, result} = Runner.run(invocation, options(settings: settings))
    assert result.text == "Useful context from primary sources."
    assert result.usage["tool_use_counts"] == %{"web_fetch" => 0, "web_search" => 2}
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "still selects a reply when web_fetch hits max_uses_exceeded" do
    invocation = invocation("fetch-cap-hit")
    fixture = decoded_fixture("tool_success.json")

    body =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_fetch_1",
          "name" => "web_fetch",
          "input" => %{"url" => "https://example.test/page"}
        },
        %{
          "type" => "web_fetch_tool_result",
          "tool_use_id" => "srvtoolu_fetch_1",
          "content" => %{
            "type" => "web_fetch_tool_result_error",
            "error_code" => "max_uses_exceeded"
          }
        },
        writeup_text("Useful context from primary sources.")
      ])

    Process.put(:runner_client_results, two_phase_results(Jason.encode!(body)))
    settings = Map.put(settings(), :max_web_fetch_uses, 1)

    assert {:ok, result} = Runner.run(invocation, options(settings: settings))
    assert result.text == "Useful context from primary sources."
    assert result.usage["tool_use_counts"] == %{"web_fetch" => 1, "web_search" => 0}
  end

  test "a stored writeup plus 4xx structure envelope starts a live structure call" do
    writeup = "Stored writeup from research."
    citations = [%{"url" => "https://primary.example/report", "cited_text" => "excerpt"}]

    stale_structure = %{
      "model" => "claude-haiku-4-5",
      "max_tokens" => 1_024,
      "thinking" => %{"type" => "adaptive"},
      "output_config" => %{
        "effort" => "low",
        "format" => %{"type" => "json_schema", "schema" => %{}}
      },
      "messages" => [%{"role" => "user", "content" => "STRUCTURE_OUTPUT\n\nstale"}]
    }

    invocation =
      invocation("structure-4xx-resume", %{
        anthropic_messages: stale_structure,
        anthropic_attempt_sequence: 1,
        full_response: writeup,
        citation_sources: citations
      })

    entry =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: "invocation-#{invocation.id}-attempt-1-structure",
        invocation_id: invocation.id,
        budget_date: DateTime.to_date(@now),
        kind: :structure,
        reserved_microdollars: 100_000,
        state: :sent,
        sent_at: @now,
        response_recorded_at: @now,
        research_claim_token: @claim_token
      })
      |> Repo.insert!()

    prepared =
      ResponseEnvelope.prepare(
        envelope(
          400,
          ~s({"error":{"type":"invalid_request_error","message":"effort is not supported on this model"}})
        ),
        %{attempt_key: entry.attempt_key, kind: :structure}
      )

    %ResponseEnvelope{}
    |> ResponseEnvelope.changeset(Map.put(prepared, :invocation_id, invocation.id))
    |> ResponseEnvelope.changeset(%{budget_entry_id: entry.id})
    |> Repo.insert!()

    Process.put(:runner_client_results, [
      {:ok, envelope(200, fixture("structure_success.json"))}
    ])

    assert {:ok, result} = Runner.run(Repo.reload!(invocation), options())
    assert result.full_response == writeup
    assert_received {:anthropic_call, structure, %{kind: :structure}, false}
    assert Request.structure_request?(structure)
    refute Map.has_key?(structure, "thinking")
    refute Map.has_key?(structure["output_config"], "effort")
    assert structure["output_config"]["format"]["type"] == "json_schema"
    assert structure["messages"] |> hd() |> Map.get("content") =~ writeup
    refute_received {:anthropic_call, _request, %{kind: :research}, _in_transaction}
    assert length(responses(invocation)) == 2
  end

  test "operator force_new_attempt starts a new POST instead of replaying a failed code_execution envelope" do
    invocation = invocation("code-exec-new-attempt")
    fixture = decoded_fixture("tool_success.json")

    failed =
      put_in(fixture, ["content"], [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_code_1",
          "name" => "code_execution",
          "input" => %{"code" => "web_search({'query': 'Yosemite'})"}
        },
        %{
          "type" => "code_execution_tool_result",
          "tool_use_id" => "srvtoolu_code_1",
          "content" => %{
            "type" => "code_execution_result",
            "stdout" => "",
            "stderr" => "TypeError",
            "return_code" => 1,
            "content" => []
          }
        },
        %{"type" => "text", "text" => "must not publish"}
      ])

    Process.put(:runner_client_results, [{:ok, envelope(200, Jason.encode!(failed))}])

    assert {:error, :code_execution_failed} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    success = decoded_fixture("tool_success.json")
    Process.put(:runner_client_results, two_phase_results(Jason.encode!(success)))

    assert {:error, :code_execution_failed} =
             Runner.run(Repo.reload!(invocation), options())

    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    assert {:ok, result} =
             Runner.run(Repo.reload!(invocation), options(force_new_attempt: true))

    assert result.text == "Useful context from primary sources."
    assert_received {:anthropic_call, _request, %{kind: :retry}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert length(responses(invocation)) == 3
  end

  test "force_new_attempt still waits out an in-flight send without a second POST" do
    invocation = invocation("force-new-inflight")
    Process.put(:runner_client_results, two_phase_results())
    crash = crash_once(:after_sent)

    assert_raise RuntimeError, "injected crash after_sent", fn ->
      Runner.run(invocation, options(crash: crash))
    end

    assert {:wait, 300_000} =
             Runner.run(invocation, options(crash: crash, force_new_attempt: true))

    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
    assert Enum.map(Repo.all(BudgetEntry), & &1.state) == [:sent]
  end

  test "a blank structured title is rewritten with the cheap title model then published" do
    invocation =
      invocation("blank-title-rewrite", %{
        invocation_text: "@getcontext.bot what bird is that?"
      })

    compact = "Public reporting describes a planned demolition."
    full = "Thorough markdown writeup with sources."

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(message_body(full)))},
      {:ok,
       envelope(
         200,
         Jason.encode!(message_body(structured_json(compact, title: "", disposition: "reply")))
       )},
      {:ok, envelope(200, Jason.encode!(message_body(title_json("Planned Explosion?"))))}
    ])

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == compact
    assert result.full_response == full
    assert result.document_title == "Planned Explosion?"
    refute Map.has_key?(result, :text_part2)
    assert result.validation["result"] == "valid"
    assert result.validation["repair_used"] == false

    assert_received {:anthropic_call, research_request, %{kind: :research}, false}
    assert research_request["model"] == "claude-sonnet-5"
    refute Map.has_key?(research_request["output_config"], "format")
    assert_received {:anthropic_call, structure_request, %{kind: :structure}, false}
    assert structure_request["model"] == "claude-sonnet-5"
    refute Map.has_key?(structure_request, "tools")
    assert_received {:anthropic_call, title_request, %{kind: :repair}, false}
    assert title_request["model"] == "claude-haiku-4-5"
    refute Map.has_key?(title_request, "tools")
    assert title_request["output_config"]["format"]["schema"]["required"] == ["title"]
    assert title_request["system"] =~ "READER_TITLE_V2"
    assert hd(title_request["messages"])["content"] =~ "@getcontext.bot what bird is that?"
    assert hd(title_request["messages"])["content"] =~ compact
    assert hd(title_request["messages"])["content"] =~ full
    refute hd(title_request["messages"])["content"] =~ "LENGTH_REPAIR"
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}

    kinds = Enum.map(Repo.all(BudgetEntry), & &1.kind)
    assert :research in kinds
    assert :structure in kinds
    assert :repair in kinds
    assert length(responses(invocation)) == 3
  end

  test "a blank title plus over-long compact rewrites the title then pack-first splits" do
    invocation = invocation("blank-title-over-limit")
    {part1, part2, over_text} = over_limit_split_parts()
    full = "Thorough markdown writeup."

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(message_body(full)))},
      {:ok, envelope(200, Jason.encode!(message_body(structured_json(over_text, title: ""))))},
      {:ok, envelope(200, Jason.encode!(message_body(title_json("What Is That Bird?"))))}
    ])

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == part1
    assert result.text_part2 == part2
    assert result.full_response == full
    assert result.document_title == "What Is That Bird?"
    assert result.validation["result"] == "split"
    assert result.validation["repair_used"] == false

    assert_received {:anthropic_call, _research, %{kind: :research}, false}
    assert_received {:anthropic_call, _structure, %{kind: :structure}, false}
    assert_received {:anthropic_call, title_request, %{kind: :repair}, false}
    refute title_request["messages"] |> hd() |> Map.get("content") =~ "LENGTH_REPAIR"
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "a blank title rewrite that returns an empty title fails closed" do
    invocation = invocation("blank-title-failed")

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(message_body("Writeup.")))},
      {:ok,
       envelope(
         200,
         Jason.encode!(message_body(structured_json("Short summary.", title: "")))
       )},
      {:ok, envelope(200, Jason.encode!(message_body(title_json(""))))}
    ])

    assert {:error, :invalid_structured_output} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _research, %{kind: :research}, false}
    assert_received {:anthropic_call, _structure, %{kind: :structure}, false}
    assert_received {:anthropic_call, _title, %{kind: :repair}, false}
    refute_received {:anthropic_call, _request, _metadata, _in_transaction}
  end

  test "an over-limit structured compact splits locally without a length-repair rewrite" do
    invocation = invocation("over-limit-split")
    {part1, part2, over_text} = over_limit_split_parts()
    writeup = "Thorough markdown writeup with sources."

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body(writeup)),
        Jason.encode!(message_body(structured_json(over_text, title: "Context Request")))
      )
    )

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == part1
    assert result.text_part2 == part2
    assert result.compact_source == over_text

    refute String.contains?(result.compact_source, ReplyLimits.continuation_ellipsis())

    assert result.full_response == writeup
    assert result.document_title == "Context Request"

    assert result.validation == %{
             "result" => "split",
             "repair_used" => false,
             "part1_graphemes" => String.length(part1),
             "part2_graphemes" => String.length(part2)
           }

    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, structure, %{kind: :structure}, false}
    refute Map.has_key?(structure, "tools")
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
    assert length(responses(invocation)) == 2

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), & &1.kind) == [
             :research,
             :structure
           ]
  end

  test "a structured over-limit compact splits and keeps the research writeup and title" do
    invocation = invocation("structured-over-limit-split")
    full = "Thorough markdown writeup with sources."
    title = "What Is That Bird?"
    {part1, part2, over_text} = over_limit_split_parts()

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body(full)),
        Jason.encode!(message_body(structured_json(over_text, title: title)))
      )
    )

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == part1
    assert result.text_part2 == part2
    assert result.compact_source == over_text
    assert result.full_response == full
    assert result.document_title == title
    assert result.validation["result"] == "split"
    assert result.validation["repair_used"] == false

    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  test "an under-limit structured reply stays one post without repair or split" do
    invocation = invocation("under-limit-one-post")
    text = String.duplicate("a", 300)
    writeup = "Writeup."

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body(writeup)),
        Jason.encode!(message_body(structured_json(text)))
      )
    )

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == text
    assert result.full_response == writeup
    assert result.document_title == "Context Request"
    refute Map.has_key?(result, :text_part2)

    assert result.validation == %{
             "result" => "valid",
             "repair_used" => false,
             "phase" => "structure"
           }

    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  test "prose on the structure call fails closed without publishing" do
    invocation = invocation("invalid-structured-output")

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body("Completed cited writeup.")),
        Jason.encode!(message_body("Just a regular reply without JSON"))
      )
    )

    assert {:error, :invalid_structured_output} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  test "a no_reply structure object still uses the cheap second call" do
    invocation = invocation("no-reply-structured")

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body("No published reply is needed.")),
        Jason.encode!(message_body(StructuredFixtures.no_reply_json()))
      )
    )

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.disposition == :no_reply
    assert result.text == ""
    refute Map.get(result, :full_response)
    refute Map.get(result, :document_title)

    assert result.validation == %{
             "result" => "no_reply",
             "repair_used" => false,
             "phase" => "structure"
           }

    refute Map.has_key?(result, :text_part2)
    assert_received {:anthropic_call, research, %{kind: :research}, false}
    assert_received {:anthropic_call, structure, %{kind: :structure}, false}
    refute Map.has_key?(structure, "tools")
    assert is_list(research["tools"])
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  test "title and compact come from the structure call and full_response from research" do
    invocation = invocation("two-phase-fields")
    compact = String.duplicate("b", 250)
    full = "Thorough markdown writeup. See https://primary.example/report"
    title = "What Is That Bird?"

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(
          message_body(full, [
            %{
              "type" => "web_search_result_location",
              "url" => "https://primary.example/report",
              "cited_text" => "source excerpt"
            }
          ])
        ),
        Jason.encode!(message_body(structured_json(compact, title: title)))
      )
    )

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == compact
    assert result.full_response == full
    assert result.document_title == title
    refute Map.has_key?(result, :text_part2)

    assert result.validation == %{
             "result" => "valid",
             "repair_used" => false,
             "phase" => "structure"
           }

    assert Repo.reload!(invocation).citation_sources == [
             %{"url" => "https://primary.example/report", "cited_text" => "source excerpt"}
           ]

    assert_received {:anthropic_call, research, %{kind: :research}, false}
    assert_received {:anthropic_call, structure, %{kind: :structure}, false}
    refute Map.has_key?(research["output_config"], "format")
    refute Map.has_key?(structure, "tools")
    assert structure["output_config"]["format"]["schema"] == Request.structure_schema()
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  test "a structure call with a blank title starts the cheap Haiku title rewrite" do
    invocation = invocation("blank-structure-title")

    Process.put(:runner_client_results, [
      {:ok, envelope(200, Jason.encode!(message_body("Cited writeup.")))},
      {:ok,
       envelope(
         200,
         Jason.encode!(
           message_body(
             Jason.encode!(%{
               "disposition" => "reply",
               "title" => "   ",
               "compact_reply" => "A compact answer."
             })
           )
         )
       )},
      {:ok, envelope(200, Jason.encode!(message_body(title_json("Cited Writeup"))))}
    ])

    assert {:ok, result} = Runner.run(invocation, options())
    assert result.text == "A compact answer."
    assert result.document_title == "Cited Writeup"
    assert result.full_response == "Cited writeup."
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, structure_request, %{kind: :structure}, false}
    assert structure_request["model"] == "claude-sonnet-5"
    assert_received {:anthropic_call, title_request, %{kind: :repair}, false}
    assert title_request["model"] == "claude-haiku-4-5"
  end

  test "an unsplittable over-limit compact fails closed without a repair attempt" do
    invocation = invocation("over-limit-unsplittable")
    unsplittable = String.duplicate("a", 301)

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body("Writeup.")),
        Jason.encode!(message_body(structured_json(unsplittable)))
      )
    )

    assert {:error, :invalid_repair} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), & &1.kind) == [
             :research,
             :structure
           ]
  end

  test "an unsplittable structured compact fails closed and does not rewrite" do
    invocation = invocation("structured-unsplittable")
    full = "Thorough markdown writeup."
    title = "What Is That Bird?"

    Process.put(
      :runner_client_results,
      two_phase_results(
        Jason.encode!(message_body(full)),
        Jason.encode!(message_body(structured_json(String.duplicate("c", 328), title: title)))
      )
    )

    assert {:error, :invalid_repair} = Runner.run(invocation, options())
    assert_received {:anthropic_call, _request, %{kind: :research}, false}
    assert_received {:anthropic_call, _request, %{kind: :structure}, false}
    refute_received {:anthropic_call, _request, %{kind: :repair}, _in_transaction}
  end

  defp two_phase_results(writeup_raw \\ nil, structure_raw \\ nil) do
    [
      {:ok, envelope(200, writeup_raw || fixture("tool_success.json"))},
      {:ok, envelope(200, structure_raw || fixture("structure_success.json"))}
    ]
  end

  defp options(overrides \\ []) do
    defaults = [
      client: ContextBot.Research.RunnerTest.Client,
      claim_token: @claim_token,
      decoder: &Jason.decode/1,
      now: fn -> @now end,
      sleep: fn _milliseconds -> :ok end,
      settings: settings()
    ]

    Keyword.merge(defaults, overrides)
  end

  defp settings do
    %{
      anthropic_daily_budget_microdollars: 5_000_000,
      anthropic_research_reservation_microdollars: 1_000_000,
      anthropic_continuation_reservation_microdollars: 1_000_000,
      anthropic_repair_reservation_microdollars: 1_000_000,
      anthropic_structure_reservation_microdollars: 100_000,
      anthropic_retry_reservation_microdollars: 1_000_000,
      anthropic_pricing_version: "sonnet-5-2026-07-28",
      anthropic_model_id: "claude-sonnet-5",
      anthropic_title_model_id: "claude-haiku-4-5",
      anthropic_structure_model_id: "claude-sonnet-5",
      anthropic_effort: :medium,
      anthropic_research_max_tokens: 1_024,
      anthropic_length_repair_max_tokens: 256,
      anthropic_structure_max_tokens: 256,
      max_web_search_uses: 3,
      max_web_fetch_uses: 3,
      max_web_fetch_content_tokens: 10_000,
      max_tool_continuations: 3,
      anthropic_max_http_retries: 2,
      anthropic_retry_base_ms: 10,
      anthropic_retry_max_ms: 10_000,
      anthropic_web_search_tool_type: "web_search_20260318",
      anthropic_web_fetch_tool_type: "web_fetch_20260318",
      max_response_bytes: 8_000,
      max_storage_bytes: 1_000_000,
      anthropic_http_timeout_ms: 300_000
    }
  end

  defp invocation(suffix, extra \\ %{}) do
    uri = "at://did:plc:actor/app.bsky.feed.post/#{suffix}"
    cid = "bafy-#{suffix}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: cid,
          actor_did: "did:plc:actor",
          raw_notification: %{"uri" => uri, "cid" => cid},
          received_at: @now,
          status: :researching,
          stage: :researching,
          research_claim_token: @claim_token,
          research_claimed_at: @now,
          canonical_thread: "ROOT\nClaim needing context.\n\nINVOCATION\nPlease add context.",
          canonical_thread_version: "1",
          root_uri: uri,
          root_cid: cid
        },
        extra
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp envelope(status, raw_body) do
    envelope(status, raw_body, %{})
  end

  defp envelope(status, raw_body, extra_headers) do
    %{
      status: status,
      headers:
        Map.merge(
          %{"content-type" => ["application/json"], "request-id" => ["req-test"]},
          extra_headers
        ),
      raw_body: raw_body,
      received_at: @now,
      duration_ms: 17
    }
  end

  defp crash_once(point) do
    marker = {:runner_crashed, point}

    fn
      ^point, _value ->
        unless Process.get(marker) do
          Process.put(marker, true)
          raise "injected crash #{point}"
        end

        :ok

      _other, _value ->
        :ok
    end
  end

  defp take_over(invocation, token) do
    Store.claim_research(
      invocation,
      token,
      DateTime.add(@now, 2, :second),
      DateTime.add(@now, 1, :second)
    )
  end

  defp fixture(name) do
    "../../fixtures/anthropic/#{name}"
    |> Path.expand(__DIR__)
    |> File.read!()
  end

  defp responses(invocation), do: Store.anthropic_responses(invocation)

  defp seed_provider_storage(invocation) do
    legacy = [%{"raw_body" => String.duplicate("l", 37), "status" => 503}]

    invocation
    |> Invocation.anthropic_responses_changeset(legacy)
    |> Repo.update!()

    prepared = ResponseEnvelope.prepare(envelope(503, "prior-envelope"))

    %ResponseEnvelope{}
    |> ResponseEnvelope.changeset(Map.put(prepared, :invocation_id, invocation.id))
    |> Repo.insert!()

    Repo.reload!(invocation)
  end

  defp actual_provider_storage_bytes(invocation) do
    %{rows: [[bytes]]} =
      SQL.query!(
        Repo,
        """
        SELECT COALESCE(length(i.anthropic_responses), 0) +
               COALESCE((SELECT SUM(e.storage_bytes)
                         FROM anthropic_response_envelopes AS e
                         WHERE e.invocation_id = i.id), 0)
        FROM invocations AS i
        WHERE i.id = ?
        """,
        [invocation.id]
      )

    bytes
  end

  defp insert_budget_entry(invocation, sequence, kind, state) do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "invocation-#{invocation.id}-attempt-#{sequence}-#{kind}",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: kind,
      reserved_microdollars: 1_000_000,
      state: state,
      sent_at: if(state == :sent, do: @now),
      research_claim_token: @claim_token
    })
    |> Repo.insert!()
  end

  defp over_limit_split_parts do
    raw1 = String.duplicate("a", 150)
    raw2 = String.duplicate("b", 160)
    over_text = raw1 <> "\n\n" <> raw2
    ellipsis = ReplyLimits.continuation_ellipsis()
    assert String.length(over_text) == 312
    {raw1 <> ellipsis, ellipsis <> raw2, over_text}
  end

  defp decoded_fixture(name), do: name |> fixture() |> Jason.decode!()

  defp structured_json(compact, opts \\ []), do: StructuredFixtures.structured_json(compact, opts)

  defp title_json(title), do: Jason.encode!(%{"title" => title})

  defp writeup_text(text) when is_binary(text), do: %{"type" => "text", "text" => text}

  defp message_body(text, citations \\ nil) do
    text_block =
      if is_list(citations) do
        %{"type" => "text", "text" => text, "citations" => citations}
      else
        %{"type" => "text", "text" => text}
      end

    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "content" => [text_block],
      "stop_reason" => "end_turn",
      "usage" => usage()
    }
  end

  defp usage do
    %{
      "input_tokens" => 10,
      "cache_creation_input_tokens" => 0,
      "cache_creation" => %{
        "ephemeral_5m_input_tokens" => 0,
        "ephemeral_1h_input_tokens" => 0
      },
      "cache_read_input_tokens" => 0,
      "output_tokens" => 5,
      "server_tool_use" => %{"web_search_requests" => 0}
    }
  end
end
