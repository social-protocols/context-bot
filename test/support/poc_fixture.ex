defmodule ContextBot.POCFixture do
  @moduledoc false

  import Ecto.Query

  alias ContextBot.ATProto.{ReqClient, Session}
  alias ContextBot.FakeClock
  alias ContextBot.Mentions.Poller
  alias ContextBot.Repo
  alias ContextBot.Research.{AnthropicClient, Runner}
  alias ContextBot.Settings
  alias ContextBot.Workers.{EligibilityWorker, ReplyWorker, ResearchWorker, ThreadWorker}
  alias ContextBot.Workflow.Invocation
  alias Ecto.Adapters.SQL.Sandbox

  @bot_did "did:plc:tv2jgk63n4q5y6vsdvx4kjqp"
  @bot_handle "contextbot.test"
  @actor_did "did:plc:kde4jlvubnnsa23ntd2rn6fy"
  @actor_handle "alice.test"
  @notification_cid "bafyreicaje76m44252abt7gqyiwipnmbcjk6jlc6bh5ysuizytpesurgva"
  @now ~U[2026-07-29 12:00:00.123456Z]

  @fixture_dids %{
    "did:plc:alice" => @actor_did,
    "did:plc:contextbot" => @bot_did,
    "did:plc:bob" => "did:plc:4ryslfulhnyqjh54jabndzak",
    "did:plc:root" => "did:plc:jajustitpylddo5dahk2zk3o",
    "did:plc:quoted" => "did:plc:worl2rymwlcpthreehm7u6j2",
    "did:plc:tempting" => "did:plc:657ms7wcw4bo2lu5kbzhyxiz"
  }

  @fixture_cids %{
    "bafy-invocation-v1" => @notification_cid,
    "bafy-root" => "bafyreicicneu2e36cyy3xiyb2wwkw3t3w6vhjtqrqxkfmvs66uoxg5txwi",
    "bafy-parent" => "bafyreiheoeszncz3oecj7pciali6ictr5ijvtxwpvowpoczulcadpvh7bq",
    "bafy-quoted" => "bafyreiftuk6uodfsyt4z4jbb3h5hsouj6g2tpnvcir4bbrbrwwqe4favfe",
    "bafy-root-reply" => "bafyreidg4ylhlzhetj5dnxhpzqnmo5uyztno3k2sbc6t23cxs6jsqjd3nq",
    "bafy-parent-reply" => "bafyreif4jv5nweskzldgjmoeazkeql5d6wmxghnbobi537dl6jrbr6kosu",
    "bafy-invocation-reply" => "bafyreiaklmbwivq3yxivxxlnyq4w5ec6ki553yqceoibund7hios2nmpv4"
  }

  defstruct [:clock, :owner, :settings, :state]

  def start!(options \\ []) do
    owner = self()
    now = Keyword.get(options, :now, @now)
    actor_did = Keyword.get(options, :actor_did, @actor_did)
    actor_handle = Keyword.get(options, :actor_handle, @actor_handle)
    eligibility = Keyword.get(options, :eligibility, :allowlist)
    notification = Keyword.get(options, :notification, notification(actor_did, actor_handle))
    settings = settings(options, eligibility, actor_did)

    {:ok, clock} = FakeClock.start_link(now)

    initial_state = %{
      actor_did: actor_did,
      actor_handle: actor_handle,
      anthropic_requests: [],
      anthropic_results:
        Keyword.get(options, :anthropic_results, [
          {:response, 200, anthropic_fixture("tool_success.json"), %{}},
          {:response, 200, anthropic_fixture("structure_success.json"), %{}}
        ]),
      calls: [],
      created_reply_count: 0,
      eligibility: eligibility,
      notification_page: %{"notifications" => [notification]},
      observer: Keyword.get(options, :observer, fn _endpoint -> :ok end),
      pds_mode: Keyword.get(options, :pds_mode, :normal),
      pds_visible: Keyword.get(options, :pds_visible),
      thread_result: Keyword.get(options, :thread_result, {:json, 200, thread_fixture()})
    }

    {:ok, state} = Agent.start_link(fn -> initial_state end)
    fixture = %__MODULE__{clock: clock, owner: owner, settings: settings, state: state}

    previous = configure_application(fixture)
    install_http_stubs(fixture)
    start_session!(fixture)

    ExUnit.Callbacks.on_exit(fn ->
      stop_session()
      restore_application(previous)
      if Process.alive?(clock), do: Agent.stop(clock)
      if Process.alive?(state), do: Agent.stop(state)
    end)

    fixture
  end

  def poll_once!(%__MODULE__{} = fixture) do
    {:ok, poller} =
      Poller.start_link(
        client: ReqClient,
        bot_did: fixture.settings.bot_did,
        max_pending: fixture.settings.max_pending,
        page_cap: 1,
        poll_interval_ms: 60_000,
        start_immediately: false
      )

    Sandbox.allow(Repo, fixture.owner, poller)
    Req.Test.allow(ReqClient, fixture.owner, poller)
    Poller.poll_now(poller)
    wait_until(fn -> Poller.idle?(poller) end)
    GenServer.stop(poller)
    :ok
  end

  def restart_session!(%__MODULE__{} = fixture) do
    stop_session()
    start_session!(fixture)
  end

  def drain_successfully!(fixture, queues) do
    Enum.each(queues, fn queue ->
      job = job!(queue)
      result = perform_job(fixture, job)

      unless result == :ok or match?({:ok, _value}, result) do
        raise "expected #{queue} job to succeed, got: #{inspect(result)}"
      end

      Repo.delete!(job)
    end)

    :ok
  end

  def perform_next(fixture, queue, options \\ []) do
    job = job!(queue)
    job = struct!(job, Keyword.take(options, [:attempt, :max_attempts]))
    result = perform_job(fixture, job)

    if Keyword.get(options, :ack, false) and
         (result == :ok or match?({:ok, _value}, result)) do
      Repo.delete!(Repo.get!(Oban.Job, job.id))
    end

    {result, job}
  end

  def perform_job(_fixture, %Oban.Job{} = job) do
    job = %{
      job
      | attempt: max(job.attempt, 1),
        attempted_at: job.attempted_at || DateTime.utc_now()
    }

    Oban.Testing.perform_job(job,
      repo: Repo,
      engine: Oban.Engines.Lite,
      testing: :manual
    )
  end

  def job!(queue) do
    Oban.Job
    |> where([job], job.queue == ^to_string(queue))
    |> order_by([job], asc: job.id)
    |> Repo.one!()
  end

  def invocation! do
    Invocation
    |> order_by([invocation], desc: invocation.id)
    |> limit(1)
    |> Repo.one!()
  end

  def invocation(uri, cid) do
    Repo.get_by(Invocation, invocation_uri: uri, notification_cid: cid)
  end

  def calls(%__MODULE__{state: state}) do
    Agent.get(state, &Enum.reverse(&1.calls))
  end

  def call_count(fixture, endpoint) do
    Enum.count(calls(fixture), &(&1.endpoint == endpoint))
  end

  def anthropic_requests(%__MODULE__{state: state}) do
    Agent.get(state, &Enum.reverse(&1.anthropic_requests))
  end

  def visible_reply(%__MODULE__{state: state}), do: Agent.get(state, & &1.pds_visible)

  def created_reply_count(%__MODULE__{state: state}),
    do: Agent.get(state, & &1.created_reply_count)

  def put_anthropic_results(%__MODULE__{state: state}, results) do
    Agent.update(state, &%{&1 | anthropic_results: results})
  end

  def set_thread_result(%__MODULE__{state: state}, result) do
    Agent.update(state, &%{&1 | thread_result: result})
  end

  def set_pds_mode(%__MODULE__{state: state}, mode) do
    Agent.update(state, &%{&1 | pds_mode: mode})
  end

  def set_research_response(%__MODULE__{state: state}, response_content) do
    Agent.update(state, fn state ->
      # Ensure response has all required Anthropic fields
      full_response =
        Map.merge(
          %{
            "id" => "msg_test",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-sonnet-5",
            "usage" => %{
              "input_tokens" => 100,
              "cache_creation_input_tokens" => 100,
              "cache_creation" => %{
                "ephemeral_5m_input_tokens" => 100,
                "ephemeral_1h_input_tokens" => 0
              },
              "cache_read_input_tokens" => 0,
              "output_tokens" => 20,
              "server_tool_use" => %{
                "web_search_requests" => 0
              }
            },
            "stop_sequence" => nil
          },
          response_content
        )

      json_content = Jason.encode!(full_response)

      %{
        state
        | anthropic_results: [
            {:response, 200, json_content, %{}},
            {:response, 200, anthropic_fixture("structure_success.json"), %{}}
          ]
      }
    end)
  end

  def notification(actor_did \\ @actor_did, actor_handle \\ @actor_handle) do
    uri = "at://#{actor_did}/app.bsky.feed.post/invocation"

    %{
      "uri" => uri,
      "cid" => @notification_cid,
      "author" => %{"did" => actor_did, "handle" => actor_handle},
      "reason" => "mention",
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "createdAt" => "2026-07-29T12:00:00.000Z",
        "text" => "@contextbot.test please add context.",
        "facets" => [
          %{
            "index" => %{"byteStart" => 0, "byteEnd" => 16},
            "features" => [
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @bot_did}
            ]
          }
        ]
      }
    }
  end

  def thread_fixture do
    fixture_path("atproto", "thread_ancestors.json")
    |> File.read!()
    |> Jason.decode!()
    |> replace_fixture_identifiers()
  end

  def anthropic_fixture(name), do: File.read!(fixture_path("anthropic", name))

  def fixture_cid(label) when is_binary(label) do
    bytes = <<1, 0x71, 0x12, 0x20>> <> :crypto.hash(:sha256, label)
    "b" <> Base.encode32(bytes, case: :lower, padding: false)
  end

  defp settings(options, eligibility, actor_did) do
    allowlist = if eligibility == :allowlist, do: [actor_did], else: []

    defaults = [
      bot_did: @bot_did,
      bot_handle: @bot_handle,
      bot_pds_url: "https://pds.test",
      anthropic_daily_budget_usd: "20.000000",
      operator_allowed_dids: allowlist
    ]

    Settings.load(Keyword.merge(defaults, Keyword.get(options, :settings, [])))
  end

  defp configure_application(fixture) do
    keys = [
      :settings,
      :bot_app_password,
      ReqClient,
      Session,
      AnthropicClient,
      EligibilityWorker,
      ThreadWorker,
      ResearchWorker,
      ReplyWorker
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:context_bot, &1, :missing)})
    now = fn -> FakeClock.now(fixture.clock) end

    Application.put_env(:context_bot, :settings, fixture.settings)
    Application.put_env(:context_bot, :bot_app_password, "app-password-test-only")

    Application.put_env(:context_bot, ReqClient,
      pds_url: "https://pds.test",
      session: Session,
      timeout: 1_000,
      req_options: [plug: {Req.Test, ReqClient}, plugins: []]
    )

    Application.put_env(:context_bot, Session,
      bot_did: @bot_did,
      identifier: @bot_handle,
      password: "app-password-test-only",
      pds_url: "https://pds.test",
      timeout: 1_000,
      req_options: [plug: {Req.Test, Session}, plugins: []]
    )

    Application.put_env(:context_bot, AnthropicClient,
      base_url: "https://api.anthropic.test",
      timeout: 1_000,
      req_options: [plug: {Req.Test, AnthropicClient}, plugins: []]
    )

    Application.put_env(:context_bot, EligibilityWorker,
      client: ReqClient,
      now: FakeClock.now(fixture.clock),
      settings: fixture.settings
    )

    Application.put_env(:context_bot, ThreadWorker,
      client: ReqClient,
      fetch_timeout_ms: 1_000,
      settings: fixture.settings
    )

    Application.put_env(:context_bot, ResearchWorker,
      now: now,
      runner: Runner,
      runner_options: [
        client: AnthropicClient,
        decoder: &Jason.decode/1,
        now: now,
        sleep: fn _milliseconds -> :ok end
      ],
      settings: fixture.settings
    )

    Application.put_env(:context_bot, ReplyWorker,
      client: ReqClient,
      now: now,
      reader_check: fn _uri -> :not_indexed end,
      enqueue_follower: fn _invocation -> :ok end
    )

    previous
  end

  defp restore_application(previous) do
    Enum.each(previous, fn
      {key, :missing} -> Application.delete_env(:context_bot, key)
      {key, value} -> Application.put_env(:context_bot, key, value)
    end)
  end

  defp install_http_stubs(fixture) do
    Req.Test.stub(ReqClient, &route_atproto(&1, fixture))
    Req.Test.stub(Session, &route_session(&1, fixture))
    Req.Test.stub(AnthropicClient, &route_anthropic(&1, fixture))
  end

  defp start_session!(fixture) do
    {:ok, pid} = Session.start_link()
    Req.Test.allow(Session, fixture.owner, pid)
    pid
  end

  defp stop_session do
    case Process.whereis(Session) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
    end
  end

  defp route_session(conn, fixture) do
    observe(fixture, :session_create)
    record_call(fixture, :session_create, conn)

    Req.Test.json(conn, %{
      "did" => @bot_did,
      "handle" => @bot_handle,
      "accessJwt" => "access-token-test-only",
      "refreshJwt" => "refresh-token-test-only",
      "active" => true
    })
  end

  defp route_atproto(conn, fixture) do
    case conn.request_path do
      "/xrpc/app.bsky.notification.listNotifications" ->
        observe(fixture, :notifications)
        state = record_call(fixture, :notifications, conn)
        Req.Test.json(conn, state.notification_page)

      "/xrpc/app.bsky.actor.getProfile" ->
        observe(fixture, :profile)
        state = record_call(fixture, :profile, conn)
        validate_profile_request!(conn, state)
        profile_response(conn, state)

      "/xrpc/com.atproto.identity.resolveHandle" ->
        observe(fixture, :resolve_handle)
        state = record_call(fixture, :resolve_handle, conn)
        resolve_handle_response(conn, state)

      "/xrpc/app.bsky.feed.getPostThread" ->
        observe(fixture, :thread)
        state = record_call(fixture, :thread, conn)
        provider_response(conn, state.thread_result)

      "/xrpc/com.atproto.repo.getRecord" ->
        endpoint = repo_endpoint(:get, query_params(conn)["collection"])
        observe(fixture, endpoint)
        state = record_call(fixture, endpoint, conn)
        get_record_response(conn, state)

      "/xrpc/com.atproto.repo.putRecord" ->
        put_record_response(conn, fixture)

      path ->
        state = Agent.get(fixture.state, & &1)

        if path == "/#{state.actor_did}" do
          observe(fixture, :resolve_did)
          state = record_call(fixture, :resolve_did, conn)
          resolve_did_response(conn, state)
        else
          raise "unexpected ATProto request: #{conn.method} #{path}"
        end
    end
  end

  defp route_anthropic(conn, fixture) do
    observe(fixture, :anthropic_post)
    body = request_body!(conn)

    result =
      Agent.get_and_update(fixture.state, fn state ->
        case state.anthropic_results do
          [result | rest] ->
            updated = %{
              state
              | anthropic_results: rest,
                anthropic_requests: [body | state.anthropic_requests],
                calls: [%{endpoint: :anthropic_post, request: body} | state.calls]
            }

            {result, updated}

          [] ->
            raise "unexpected extra Anthropic request"
        end
      end)

    provider_response(conn, result)
  end

  defp profile_response(conn, %{eligibility: :elder, actor_did: actor_did}) do
    conn
    |> Plug.Conn.put_resp_header("atproto-content-labelers", elder_labeler())
    |> Req.Test.json(%{"labels" => [elder_label(actor_did)]})
  end

  defp profile_response(conn, %{eligibility: :invalid_elder_header, actor_did: actor_did}) do
    Req.Test.json(conn, %{"labels" => [elder_label(actor_did)]})
  end

  defp profile_response(conn, %{eligibility: :labeler_outage}) do
    conn
    |> Plug.Conn.put_status(503)
    |> Req.Test.json(%{"error" => "Unavailable"})
  end

  defp profile_response(conn, state)
       when state.eligibility in [:team, :stale_team, :ineligible] do
    conn
    |> Plug.Conn.put_resp_header("atproto-content-labelers", elder_labeler())
    |> Req.Test.json(%{"labels" => []})
  end

  defp resolve_handle_response(conn, %{eligibility: :team, actor_did: actor_did}),
    do: Req.Test.json(conn, %{"did" => actor_did})

  defp resolve_handle_response(conn, %{eligibility: :stale_team}),
    do: Req.Test.json(conn, %{"did" => "did:plc:ua7shbvoa2zbcckxoaqiitpt"})

  defp resolve_handle_response(conn, _state),
    do: Req.Test.json(conn, %{"did" => "did:plc:3euyuegrwbzvqn64jpmf3lde"})

  defp resolve_did_response(conn, %{
         eligibility: :team,
         actor_did: actor_did,
         actor_handle: handle
       }) do
    Req.Test.json(conn, %{"id" => actor_did, "alsoKnownAs" => ["at://#{handle}"]})
  end

  defp resolve_did_response(conn, state),
    do: Req.Test.json(conn, %{"id" => state.actor_did, "alsoKnownAs" => ["at://old.bsky.team"]})

  defp repo_endpoint(_kind, collection)
       when collection in ["site.standard.publication", "site.standard.document"],
       do: :standard_site

  defp repo_endpoint(:get, _collection), do: :pds_get
  defp repo_endpoint(:put, _collection), do: :pds_put

  defp site_collection?(collection)
       when collection in ["site.standard.publication", "site.standard.document"],
       do: true

  defp site_collection?(_collection), do: false

  defp get_record_response(conn, state) do
    if site_collection?(query_params(conn)["collection"]) do
      record_not_found(conn)
    else
      get_feed_record_response(conn, state)
    end
  end

  defp get_feed_record_response(conn, %{pds_mode: :conflict}) do
    query = query_params(conn)
    uri = "at://#{query["repo"]}/#{query["collection"]}/#{query["rkey"]}"

    Req.Test.json(conn, %{
      "uri" => uri,
      "cid" => fixture_cid("conflict"),
      "value" => %{"text" => "other"}
    })
  end

  defp get_feed_record_response(conn, %{pds_visible: nil}), do: record_not_found(conn)

  defp get_feed_record_response(conn, %{pds_visible: visible}), do: Req.Test.json(conn, visible)

  defp record_not_found(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => "RecordNotFound", "message" => "record not found"})
  end

  defp put_record_response(conn, fixture) do
    request = request_body!(conn)
    endpoint = repo_endpoint(:put, request["collection"])
    observe(fixture, endpoint)
    record_call(fixture, endpoint, conn)

    outcome =
      Agent.get_and_update(fixture.state, fn state ->
        next_put_outcome(state, request)
      end)

    case outcome do
      {:ok, visible} -> Req.Test.json(conn, Map.take(visible, ["uri", "cid"]))
      :timeout -> Req.Test.transport_error(conn, :timeout)
      :conflict -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "InvalidSwap"})
    end
  end

  defp next_put_outcome(state, %{"collection" => collection} = request)
       when collection in ["site.standard.publication", "site.standard.document"] do
    uri = "at://#{request["repo"]}/#{collection}/#{request["rkey"]}"

    visible = %{
      "uri" => uri,
      "cid" => fixture_cid("created-site"),
      "value" => request["record"]
    }

    {{:ok, visible}, state}
  end

  defp next_put_outcome(%{pds_visible: visible} = state, _request) when not is_nil(visible),
    do: {:conflict, state}

  defp next_put_outcome(%{pds_mode: :always_timeout} = state, _request),
    do: {:timeout, state}

  defp next_put_outcome(state, request) do
    uri = "at://#{request["repo"]}/#{request["collection"]}/#{request["rkey"]}"

    visible = %{
      "uri" => uri,
      "cid" => fixture_cid("created-reply"),
      "value" => request["record"]
    }

    outcome = if state.pds_mode == :ambiguous_once, do: :timeout, else: {:ok, visible}

    {outcome,
     %{
       state
       | pds_visible: visible,
         created_reply_count: state.created_reply_count + 1,
         pds_mode: :normal
     }}
  end

  defp provider_response(conn, {:response, status, body}),
    do: provider_response(conn, {:response, status, body, %{}})

  defp provider_response(conn, {:response, status, body, headers}) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp provider_response(conn, {:json, status, body}) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp provider_response(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)

  defp record_call(fixture, endpoint, conn) do
    Agent.get_and_update(fixture.state, fn state ->
      call = %{
        endpoint: endpoint,
        method: conn.method,
        path: conn.request_path,
        query: query_params(conn),
        headers: Map.new(conn.req_headers)
      }

      updated = %{state | calls: [call | state.calls]}
      {updated, updated}
    end)
  end

  defp observe(fixture, endpoint) do
    fixture.state
    |> Agent.get(& &1.observer)
    |> then(& &1.(endpoint))
  end

  defp request_body!(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)
        Jason.decode!(raw)

      body when is_map(body) ->
        body
    end
  end

  defp query_params(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Map.new()
  end

  defp elder_label(actor_did) do
    %{"src" => elder_labeler(), "uri" => actor_did, "val" => "bluesky-elder", "neg" => false}
  end

  defp elder_labeler, do: "did:plc:e4elbtctnfqocyfcml6h2lf7"

  defp validate_profile_request!(conn, state) do
    expected_query = %{"actor" => state.actor_did}
    expected_header = [elder_labeler()]

    if query_params(conn) != expected_query or
         Plug.Conn.get_req_header(conn, "atproto-accept-labelers") != expected_header do
      raise "profile request omitted the authoritative actor or Skywatch labeler"
    end
  end

  defp replace_fixture_identifiers(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, replace_fixture_identifiers(child)} end)
  end

  defp replace_fixture_identifiers(value) when is_list(value),
    do: Enum.map(value, &replace_fixture_identifiers/1)

  defp replace_fixture_identifiers(value) when is_binary(value) do
    case Map.fetch(@fixture_cids, value) do
      {:ok, replacement} ->
        replacement

      :error ->
        Enum.reduce(@fixture_dids, value, fn {old, new}, text ->
          String.replace(text, old, new)
        end)
    end
  end

  defp replace_fixture_identifiers(value), do: value

  defp fixture_path(group, name) do
    Path.expand("../fixtures/#{group}/#{name}", __DIR__)
  end

  defp wait_until(assertion, attempts \\ 100)
  defp wait_until(assertion, 0), do: assertion.() || raise("condition did not become true")

  defp wait_until(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      wait_until(assertion, attempts - 1)
    end
  end
end
