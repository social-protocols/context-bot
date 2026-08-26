defmodule ContextBotWeb.InternalControllerTest do
  use ContextBotWeb.ConnCase, async: true

  @endpoint ContextBotWeb.InternalEndpoint

  alias ContextBot.Repo
  alias ContextBot.Workflow.Invocation

  describe "GET /invocations" do
    test "lists invocations in reverse chronological order", %{conn: conn} do
      # Create test invocations
      {:ok, _inv1} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test1/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test1",
          actor_handle: "test1.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      {:ok, _inv2} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: true,
          target_uri: "at://did:plc:test2/app.bsky.feed.post/xyz789",
          invocation_text: "Test question",
          invocation_uri: "at://did:plc:test2/app.bsky.feed.post/def456",
          notification_cid: "cid2",
          current_cid: "cid2",
          actor_did: "did:plc:test2",
          actor_handle: "test2.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 11:00:00Z],
          status: :researching,
          stage: :researching
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")

      assert html_response(conn, 200) =~ "Context Bot Invocations"
      body = html_response(conn, 200)

      # Check that newer invocation appears first
      inv1_pos = :binary.match(body, "test1.bsky.social") |> elem(0)
      inv2_pos = :binary.match(body, "test2.bsky.social") |> elem(0)
      assert inv2_pos < inv1_pos

      # Check status and stage are displayed
      assert body =~ "complete"
      assert body =~ "researching"

      # Check actor handles are displayed
      assert body =~ "test1.bsky.social"
      assert body =~ "test2.bsky.social"

      # Check dry_run flag
      assert body =~ "yes"
    end

    test "displays invocation links when URIs exist", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      assert body =~ "https://bsky.app/profile/did:plc:test/post/abc123"
    end

    test "displays reply links when reply URIs exist", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          reply_uri: "at://did:plc:bot/app.bsky.feed.post/reply1",
          reply_part2_uri: "at://did:plc:bot/app.bsky.feed.post/reply2"
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      assert body =~ "https://bsky.app/profile/did:plc:bot/post/reply1"
      assert body =~ "https://bsky.app/profile/did:plc:bot/post/reply2"
    end

    test "omits reply links when reply URIs are null", %{conn: conn} do
      {:ok, inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :researching,
          stage: :researching
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      # Should not have reply links, but verify the row exists
      assert body =~ Integer.to_string(inv.id)
      refute body =~ "https://bsky.app/profile/did:plc:bot/"
    end

    test "displays attempt count from anthropic_attempt_sequence", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          anthropic_attempt_sequence: 3
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      assert body =~ ">3<"
    end

    test "displays failure category and detail", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :failed,
          stage: :failed,
          failure_category: :provider_auth,
          failure_detail: %{"reason" => "API key invalid"}
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      assert body =~ "provider_auth"
      assert body =~ "API key invalid"
    end

    test "displays timestamps", %{conn: conn} do
      {:ok, _inv} =
        %Invocation{}
        |> Invocation.changeset(%{
          dry_run: false,
          invocation_uri: "at://did:plc:test/app.bsky.feed.post/abc123",
          notification_cid: "cid1",
          current_cid: "cid1",
          actor_did: "did:plc:test",
          actor_handle: "test.bsky.social",
          raw_notification: %{},
          received_at: ~U[2026-08-26 10:00:00Z],
          status: :complete,
          stage: :complete,
          completed_at: ~U[2026-08-26 10:05:00Z]
        })
        |> Repo.insert()

      conn = get(conn, "/invocations")
      body = html_response(conn, 200)

      assert body =~ "2026-08-26"
      assert body =~ "10:05:00"
    end
  end
end
