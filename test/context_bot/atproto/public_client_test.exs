defmodule ContextBot.ATProto.PublicClientTest.RequestCapture do
  @moduledoc false

  def attach(request) do
    Req.Request.prepend_request_steps(request,
      capture_test_options: fn request ->
        if pid = Process.get(:public_client_capture_pid) do
          send(pid, {:public_client_options, request.options})
        end

        request
      end
    )
  end
end

defmodule ContextBot.ATProto.PublicClientTest do
  use ExUnit.Case, async: false

  alias ContextBot.ATProto.PublicClient

  @post_uri "at://did:plc:alice/app.bsky.feed.post/3abc"

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_config = Application.get_env(:context_bot, PublicClient)

    Application.put_env(:context_bot, PublicClient,
      appview_url: "https://public-appview.test",
      timeout: 1_234,
      req_options: [
        plug: {Req.Test, PublicClient},
        plugins: [ContextBot.ATProto.PublicClientTest.RequestCapture]
      ]
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:context_bot, PublicClient, original_config)
      else
        Application.delete_env(:context_bot, PublicClient)
      end
    end)
  end

  test "resolves handles directly through public AppView without authentication" do
    Req.Test.expect(PublicClient, fn conn ->
      assert_public_request(conn, "/xrpc/com.atproto.identity.resolveHandle")
      assert query_pairs(conn) == [{"handle", "alice.example"}]
      Req.Test.json(conn, %{"did" => "did:plc:alice"})
    end)

    assert {:ok, 200, _headers, %{"did" => "did:plc:alice"}} =
             PublicClient.resolve_handle("alice.example")
  end

  test "fetches ancestors with depth zero and bounded parent height" do
    response = %{"thread" => %{"$type" => "app.bsky.feed.defs#threadViewPost"}}

    Req.Test.expect(PublicClient, fn conn ->
      assert_public_request(conn, "/xrpc/app.bsky.feed.getPostThread")

      assert query_pairs(conn) ==
               Enum.sort([{"depth", "0"}, {"parentHeight", "37"}, {"uri", @post_uri}])

      Req.Test.json(conn, response)
    end)

    assert {:ok, 200, _headers, ^response} = PublicClient.get_post_thread(@post_uri, 37)
  end

  test "enforces the raw response limit before JSON decoding" do
    put_max_response_bytes(4)

    Req.Test.expect(PublicClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, "xxxxx")
    end)

    assert PublicClient.resolve_handle("alice.example") == {:error, :response_too_large}
  end

  test "classifies malformed bounded JSON as transport failure" do
    Req.Test.expect(PublicClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, "{")
    end)

    assert PublicClient.resolve_handle("alice.example") ==
             {:error, {:transient, :transport}}
  end

  test "classifies provider and timeout failures without retries" do
    cases = [
      {429, [{"retry-after", "17"}], {:error, {:rate_limited, "17"}}},
      {503, [], {:error, {:transient, 503}}},
      {404, [], {:error, {:permanent, 404}}}
    ]

    Enum.each(cases, fn {status, headers, expected} ->
      Req.Test.expect(PublicClient, fn conn ->
        conn
        |> Plug.Conn.merge_resp_headers(headers)
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => "ProviderError"})
      end)

      assert PublicClient.resolve_handle("alice.example") == expected
    end)

    Req.Test.expect(PublicClient, &Req.Test.transport_error(&1, :timeout))
    assert PublicClient.resolve_handle("alice.example") == {:error, :timeout}
  end

  test "uses nested Finch timeouts and disables Req retries" do
    Process.put(:public_client_capture_pid, self())
    on_exit(fn -> Process.delete(:public_client_capture_pid) end)

    Req.Test.expect(PublicClient, fn conn -> Req.Test.json(conn, %{"did" => "did:plc:alice"}) end)

    assert {:ok, 200, _headers, _body} = PublicClient.resolve_handle("alice.example")
    assert_receive {:public_client_options, options}

    assert options.finch == [
             name: ContextBot.Finch,
             pool_timeout: 5_000,
             receive_timeout: 1_234,
             request_timeout: 6_234
           ]

    assert options.retry == false
  end

  defp assert_public_request(conn, path) do
    assert conn.method == "GET"
    assert conn.host == "public-appview.test"
    assert conn.request_path == path
    assert Plug.Conn.get_req_header(conn, "authorization") == []
    assert Plug.Conn.get_req_header(conn, "atproto-proxy") == []
  end

  defp query_pairs(conn), do: conn.query_string |> URI.decode_query() |> Enum.sort()

  defp put_max_response_bytes(maximum) do
    original = Application.fetch_env!(:context_bot, :settings)
    Application.put_env(:context_bot, :settings, %{original | max_response_bytes: maximum})
    on_exit(fn -> Application.put_env(:context_bot, :settings, original) end)
  end
end
