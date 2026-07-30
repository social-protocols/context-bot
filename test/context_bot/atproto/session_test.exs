defmodule ContextBot.ATProto.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContextBot.ATProto.Session

  @bot_did "did:plc:contextbot123"
  @bot_handle "contextbot.test"
  @password "test-app-password-secret"

  setup {Req.Test, :verify_on_exit!}

  test "one createSession authenticates concurrent callers without exposing session state" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()

    logs =
      capture_log(fn ->
        callers = for _ <- 1..8, do: Task.async(fn -> Session.access_token(pid) end)

        assert callers
               |> Task.await_many()
               |> Enum.uniq() == [{:ok, "test-access-jwt-one"}]

        assert Session.status(pid) ==
                 {:ok, %{authenticated?: true, did: @bot_did}}
      end)

    refute logs =~ "test-access-jwt-one"
    refute logs =~ "test-refresh-jwt-one"
    refute logs =~ @password

    public_status = inspect(Session.status(pid))
    refute public_status =~ "test-access-jwt-one"
    refute public_status =~ "test-refresh-jwt-one"
    refute public_status =~ @password
  end

  test "serializes refresh so concurrent stale-token callers issue one refreshSession" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}

    Req.Test.expect(Session, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/xrpc/com.atproto.server.refreshSession"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-refresh-jwt-one"]
      assert Req.Test.raw_body(conn) == ""
      Req.Test.json(conn, session["refresh"])
    end)

    callers =
      for _ <- 1..8,
          do: Task.async(fn -> Session.refresh("test-access-jwt-one", pid) end)

    assert callers
           |> Task.await_many()
           |> Enum.uniq() == [{:ok, "test-access-jwt-two"}]

    assert Session.access_token(pid) == {:ok, "test-access-jwt-two"}
  end

  test "an invalid refresh falls back once to createSession and rate-limits another fallback" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}

    Req.Test.expect(Session, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-refresh-jwt-one"]

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "ExpiredToken", "message" => "Refresh token expired"})
    end)

    expect_create_session(session["reauthenticated"])

    assert Session.refresh("test-access-jwt-one", pid) ==
             {:ok, "test-access-jwt-three"}

    Req.Test.expect(Session, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-refresh-jwt-three"]

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "ExpiredToken"})
    end)

    assert Session.refresh("test-access-jwt-three", pid) ==
             {:error, :reauthentication_rate_limited}

    assert Session.status(pid) == {:ok, %{authenticated?: true, did: @bot_did}}
  end

  test "a failed invalid-refresh fallback also rate-limits tokenless lazy authentication" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}

    Req.Test.expect(Session, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "InvalidToken"})
    end)

    Req.Test.expect(Session, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "UpstreamFailure"})
    end)

    assert Session.refresh("test-access-jwt-one", pid) ==
             {:error, :authentication_failed}

    assert Session.access_token(pid) == {:error, :reauthentication_rate_limited}
    assert Session.status(pid) == {:ok, %{authenticated?: false, did: @bot_did}}
  end

  test "refresh preserves rate-limit classification and does not create a new session" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}

    Req.Test.expect(Session, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "23")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => "RateLimitExceeded"})
    end)

    assert Session.refresh("test-access-jwt-one", pid) ==
             {:error, {:rate_limited, "23"}}

    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}
  end

  test "refresh preserves transient classification and does not create a new session" do
    session = fixture()
    expect_create_session(session["create"])
    pid = start_session()
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}

    Req.Test.expect(Session, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "UpstreamFailure"})
    end)

    assert Session.refresh("test-access-jwt-one", pid) ==
             {:error, {:transient, 503}}

    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}
  end

  @tag timeout: 7_000
  test "public calls wait beyond GenServer's five-second default for a valid HTTP result" do
    session = fixture()

    Req.Test.expect(Session, fn conn ->
      Process.sleep(5_100)
      Req.Test.json(conn, session["create"])
    end)

    pid = start_session(timeout: 6_000)
    assert Session.access_token(pid) == {:ok, "test-access-jwt-one"}
  end

  test "a mismatched DID rejects the call and stops the session without leaking credentials" do
    response = Map.put(fixture()["create"], "did", "did:plc:attacker123")
    expect_create_session(response)
    pid = start_session()
    monitor = Process.monitor(pid)

    logs =
      capture_log(fn ->
        assert Session.access_token(pid) == {:error, :did_mismatch}
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute logs =~ response["accessJwt"]
    refute logs =~ response["refreshJwt"]
    refute logs =~ @password
  end

  test "active false rejects the call and stops the session" do
    response = Map.put(fixture()["create"], "active", false)
    expect_create_session(response)
    pid = start_session()
    monitor = Process.monitor(pid)

    assert Session.access_token(pid) == {:error, :inactive_session}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "authentication errors expose only a stable category" do
    Req.Test.expect(Session, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => "AuthenticationRequired",
        "message" => "echo #{@password} test-access-jwt-one test-refresh-jwt-one"
      })
    end)

    pid = start_session()

    logs =
      capture_log(fn ->
        assert Session.access_token(pid) == {:error, :authentication_failed}
      end)

    refute logs =~ @password
    refute logs =~ "test-access-jwt-one"
    refute logs =~ "test-refresh-jwt-one"
  end

  defp start_session(options \\ []) do
    pid =
      start_supervised!(
        {Session,
         Keyword.merge(
           [
             name: nil,
             bot_did: @bot_did,
             identifier: @bot_handle,
             password: @password,
             pds_url: "https://pds.test"
           ],
           options
         )}
      )

    Req.Test.allow(Session, self(), pid)
    pid
  end

  defp expect_create_session(response) do
    Req.Test.expect(Session, fn conn ->
      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "pds.test"
      assert conn.request_path == "/xrpc/com.atproto.server.createSession"

      assert conn.body_params == %{
               "identifier" => @bot_handle,
               "password" => @password
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, response)
    end)
  end

  defp fixture do
    __DIR__
    |> Path.join("../../fixtures/atproto/session.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
