defmodule ContextBot.ATProto.ReqClientTest.RequestCapture do
  @moduledoc false

  def attach(request) do
    Req.Request.prepend_request_steps(request,
      capture_test_options: fn request ->
        if pid = Process.get(:req_client_capture_pid) do
          send(pid, {:req_client_options, request.options})
        end

        request
      end
    )
  end
end

defmodule ContextBot.ATProto.ReqClientTest do
  use ExUnit.Case, async: false

  alias ContextBot.ATProto.{ReqClient, Session}

  @bot_did "did:plc:contextbot123"
  @bot_handle "contextbot.test"
  @password "test-app-password-secret"
  @post_uri "at://did:plc:alice123/app.bsky.feed.post/3m1234567892a"
  @collection "app.bsky.feed.post"
  @rkey "3mreplyrecord2a"
  @labeler "did:plc:e4elbtctnfqocyfcml6h2lf7"

  setup {Req.Test, :verify_on_exit!}

  test "listNotifications sends the exact authenticated query and preserves an opaque cursor" do
    start_authenticated_session()
    notification = fixture("notifications.json")
    cursor = "previous+/opaque=="

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "pds.test", "/xrpc/app.bsky.notification.listNotifications")

      assert query_pairs(conn) ==
               Enum.sort([
                 {"cursor", cursor},
                 {"limit", "100"},
                 {"priority", "false"},
                 {"reasons", "mention"}
               ])

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-jwt-one"]
      Req.Test.json(conn, notification)
    end)

    assert {:ok, 200, headers, ^notification} = ReqClient.list_notifications(cursor)
    assert headers["content-type"] == ["application/json; charset=utf-8"]
  end

  test "listNotifications preserves an empty filtered page with its cursor" do
    start_authenticated_session()
    empty_page = %{"cursor" => "keep-following-this-cursor", "notifications" => []}

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "pds.test", "/xrpc/app.bsky.notification.listNotifications")
      Req.Test.json(conn, empty_page)
    end)

    assert {:ok, 200, _headers, ^empty_page} = ReqClient.list_notifications(nil)
  end

  test "getPostThread suppresses descendants and sends the configured parent height" do
    thread = fixture("thread.json")

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "api.bsky.app", "/xrpc/app.bsky.feed.getPostThread")

      assert query_pairs(conn) ==
               Enum.sort([{"depth", "0"}, {"parentHeight", "37"}, {"uri", @post_uri}])

      Req.Test.json(conn, thread)
    end)

    assert {:ok, 200, _headers, ^thread} = ReqClient.get_post_thread(@post_uri, 37)
  end

  test "getProfile reads direct from api.bsky.app with the requested labeler" do
    profile = fixture("profile.json")

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "api.bsky.app", "/xrpc/app.bsky.actor.getProfile")
      assert query_pairs(conn) == [{"actor", "did:plc:alice123"}]
      assert Plug.Conn.get_req_header(conn, "atproto-accept-labelers") == [@labeler]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, profile)
    end)

    assert {:ok, 200, _headers, ^profile} =
             ReqClient.get_profile("did:plc:alice123", @labeler)
  end

  test "resolveHandle uses the exact AppView identity request" do
    identity = fixture("identity.json")
    response = identity["resolveHandle"]

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "api.bsky.app", "/xrpc/com.atproto.identity.resolveHandle")
      assert query_pairs(conn) == [{"handle", "bsky.team"}]
      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} = ReqClient.resolve_handle("bsky.team")
  end

  test "resolveDid uses the exact did:plc directory request" do
    identity = fixture("identity.json")
    response = identity["didDocument"]

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "plc.directory", "/did:plc:bskyteam123")
      assert conn.query_string == ""
      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} =
             ReqClient.resolve_did("did:plc:bskyteam123")
  end

  test "resolveDid uses the exact did:web well-known request" do
    response = %{"id" => "did:web:bsky.team", "alsoKnownAs" => ["at://bsky.team"]}

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "bsky.team", "/.well-known/did.json")
      assert conn.query_string == ""
      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} = ReqClient.resolve_did("did:web:bsky.team")
  end

  test "getRecord uses the persisted repo, collection, and rkey" do
    start_authenticated_session()
    record = fixture("record.json")["get"]

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :get, "pds.test", "/xrpc/com.atproto.repo.getRecord")

      assert query_pairs(conn) ==
               Enum.sort([
                 {"collection", @collection},
                 {"repo", @bot_did},
                 {"rkey", @rkey}
               ])

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-jwt-one"]
      Req.Test.json(conn, record)
    end)

    assert {:ok, 200, _headers, ^record} =
             ReqClient.get_record(@bot_did, @collection, @rkey)
  end

  test "putRecord sends create-only validation with the frozen record" do
    start_authenticated_session()
    fixture = fixture("record.json")
    frozen_record = fixture["get"]["value"]
    response = fixture["put"]

    Req.Test.expect(ReqClient, fn conn ->
      assert_request(conn, :post, "pds.test", "/xrpc/com.atproto.repo.putRecord")
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-jwt-one"]

      assert conn.body_params == %{
               "collection" => @collection,
               "record" => frozen_record,
               "repo" => @bot_did,
               "rkey" => @rkey,
               "swapRecord" => nil,
               "validate" => true
             }

      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} =
             ReqClient.put_record(@bot_did, @collection, @rkey, frozen_record)
  end

  test "an access-token 401 refreshes and retries exactly once" do
    start_authenticated_session(refresh?: true)
    response = fixture("notifications.json")

    Req.Test.expect(ReqClient, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-jwt-one"]
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "ExpiredToken"})
    end)

    Req.Test.expect(ReqClient, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-access-jwt-two"]
      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} = ReqClient.list_notifications(nil)
  end

  test "an access-token 401 is retried only once when authorization still fails" do
    start_authenticated_session(refresh?: true)

    Req.Test.expect(ReqClient, 2, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "ExpiredToken"})
    end)

    assert {:error, :unauthorized} = ReqClient.list_notifications(nil)
  end

  test "classifies provider and transport failures without automatic Req retries" do
    responses = [
      {401, [], %{"error" => "AuthRequired"}, {:error, :unauthorized}},
      {429, [{"retry-after", "17"}], %{"error" => "RateLimitExceeded"},
       {:error, {:rate_limited, "17"}}},
      {503, [], %{"error" => "UpstreamFailure"}, {:error, {:transient, 503}}},
      {400, [], %{"error" => "RecordNotFound"}, {:error, :record_not_found}},
      {409, [], %{"error" => "InvalidSwap"}, {:error, :invalid_swap}},
      {422, [], %{"error" => "InvalidRequest"}, {:error, {:permanent, 422}}}
    ]

    Enum.each(responses, fn {status, headers, body, expected} ->
      Req.Test.expect(ReqClient, fn conn ->
        conn
        |> Plug.Conn.merge_resp_headers(headers)
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(body)
      end)

      assert ReqClient.resolve_handle("bsky.team") == expected
    end)

    Req.Test.expect(ReqClient, &Req.Test.transport_error(&1, :timeout))
    assert ReqClient.resolve_handle("bsky.team") == {:error, :timeout}
  end

  test "uses nested named-Finch timeouts and disables Req retry" do
    original_config = Application.fetch_env!(:context_bot, ReqClient)

    permissive_req_options =
      original_config
      |> Keyword.fetch!(:req_options)
      |> Keyword.merge(
        finch: [name: Req.Finch, receive_timeout: :infinity],
        retry: true
      )

    Application.put_env(
      :context_bot,
      ReqClient,
      Keyword.put(original_config, :req_options, permissive_req_options)
    )

    Process.put(:req_client_capture_pid, self())

    on_exit(fn ->
      Application.put_env(:context_bot, ReqClient, original_config)
      Process.delete(:req_client_capture_pid)
    end)

    Req.Test.expect(ReqClient, fn conn -> Req.Test.json(conn, %{"did" => "did:plc:test123"}) end)
    assert {:ok, 200, _headers, _body} = ReqClient.resolve_handle("example.test")

    assert_receive {:req_client_options, options}

    assert options.finch == [
             name: ContextBot.Finch,
             pool_timeout: 5_000,
             receive_timeout: 1_000,
             request_timeout: 6_000
           ]

    assert options.retry == false
    refute Map.has_key?(options, :pool_timeout)
    refute Map.has_key?(options, :receive_timeout)
    refute Map.has_key?(options, :request_timeout)
  end

  defp start_authenticated_session(options \\ []) do
    session = fixture("session.json")

    Req.Test.expect(Session, fn conn ->
      assert_request(conn, :post, "pds.test", "/xrpc/com.atproto.server.createSession")

      assert conn.body_params == %{
               "identifier" => @bot_handle,
               "password" => @password
             }

      Req.Test.json(conn, session["create"])
    end)

    if options[:refresh?] do
      Req.Test.expect(Session, fn conn ->
        assert_request(conn, :post, "pds.test", "/xrpc/com.atproto.server.refreshSession")
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-refresh-jwt-one"]
        assert Req.Test.raw_body(conn) == ""
        Req.Test.json(conn, session["refresh"])
      end)
    end

    pid =
      start_supervised!(
        {Session,
         name: Session,
         bot_did: @bot_did,
         identifier: @bot_handle,
         password: @password,
         pds_url: "https://pds.test"}
      )

    Req.Test.allow(Session, self(), pid)
    pid
  end

  defp assert_request(conn, method, host, path) do
    assert conn.method == method |> Atom.to_string() |> String.upcase()
    assert conn.scheme == :https
    assert conn.host == host
    assert conn.request_path == path
    conn
  end

  defp query_pairs(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.to_list()
    |> Enum.sort()
  end

  defp fixture(name) do
    __DIR__
    |> Path.join("../../fixtures/atproto/#{name}")
    |> File.read!()
    |> Jason.decode!()
  end
end
