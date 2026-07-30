defmodule ContextBot.Mentions.PollerTest.ClientStub do
  @moduledoc false

  def list_notifications(cursor) do
    send(owner(), {:list_notifications, cursor})

    receive do
      {:notification_page, page} -> {:ok, 200, %{}, page}
      {:notification_error, reason} -> {:error, reason}
    end
  end

  defp owner, do: :persistent_term.get({__MODULE__, :owner})
end

defmodule ContextBot.Mentions.PollerTest do
  use ContextBot.DataCase, async: false

  import Ecto.Query

  alias ContextBot.Mentions.Poller
  alias ContextBot.Mentions.PollerTest.ClientStub
  alias ContextBot.Repo
  alias ContextBot.Workflow.{Invocation, Store}
  alias Ecto.Adapters.SQL.Sandbox

  @bot_did "did:plc:contextbot"

  setup do
    :persistent_term.put({ClientStub, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({ClientStub, :owner})
    end)

    :ok
  end

  test "does not overlap a new tick while its current drain is waiting on the provider" do
    poller = start_poller()

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}

    Poller.poll_now(poller)
    refute_receive {:list_notifications, nil}, 50

    send(poller, {:notification_page, empty_page()})
  end

  test "restarts each poll from the newest page" do
    poller = start_poller()

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}
    send(poller, {:notification_page, empty_page()})

    assert_eventually(fn -> Poller.idle?(poller) end)

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}
    send(poller, {:notification_page, empty_page()})
  end

  test "follows an opaque cursor after an empty filtered page" do
    poller = start_poller()

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}
    send(poller, {:notification_page, empty_page("opaque+/cursor==")})

    assert_receive {:list_notifications, "opaque+/cursor=="}
    send(poller, {:notification_page, page([mention("oldest")])})

    assert_eventually(fn -> Store.received?(uri("oldest"), cid("oldest")) end)
  end

  test "stops at an already durable strong reference without reading an older page" do
    known = mention("known")

    assert {:ok, _invocation, :inserted} =
             Store.receive_mention(receipt(known), DateTime.utc_now(), nil)

    poller = start_poller()

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}

    send(
      poller,
      {:notification_page,
       page([mention("newest"), known, mention("older")], "must-not-be-requested")}
    )

    assert_eventually(fn -> Store.received?(uri("newest"), cid("newest")) end)
    refute Store.received?(uri("older"), cid("older"))
    refute_receive {:list_notifications, "must-not-be-requested"}, 50
  end

  test "stops after the configured page cap" do
    poller = start_poller(page_cap: 2)

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}
    send(poller, {:notification_page, empty_page("first-cursor")})

    assert_receive {:list_notifications, "first-cursor"}
    send(poller, {:notification_page, empty_page("second-cursor")})

    assert_eventually(fn -> Poller.idle?(poller) end)
    refute_receive {:list_notifications, "second-cursor"}, 50
  end

  test "receipts newly discovered mentions oldest-first with one future eligibility job each" do
    poller = start_poller(max_pending: 10)

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}

    send(
      poller,
      {:notification_page, page([mention("newest"), mention("middle"), mention("oldest")])}
    )

    assert_eventually(fn -> Repo.aggregate(Invocation, :count) == 3 end)

    job_uris =
      Oban.Job
      |> order_by([job], asc: job.id)
      |> select([job], job.args["uri"])
      |> Repo.all()

    assert job_uris == [uri("oldest"), uri("middle"), uri("newest")]

    assert Repo.all(from(job in Oban.Job, select: job.worker)) == [
             "ContextBot.Workflow.EligibilityWorker",
             "ContextBot.Workflow.EligibilityWorker",
             "ContextBot.Workflow.EligibilityWorker"
           ]
  end

  test "defers a receipt when pending capacity is exhausted" do
    poller = start_poller(max_pending: 1)

    Poller.poll_now(poller)
    assert_receive {:list_notifications, nil}
    send(poller, {:notification_page, page([mention("newest"), mention("oldest")])})

    assert_eventually(fn -> Repo.aggregate(Invocation, :count) == 2 end)

    statuses =
      Invocation
      |> order_by([invocation], asc: invocation.invocation_uri)
      |> select([invocation], {invocation.invocation_uri, invocation.status})
      |> Repo.all()

    assert statuses == [{uri("newest"), :deferred_capacity}, {uri("oldest"), :received}]
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  defp start_poller(overrides \\ []) do
    {:ok, poller} =
      Poller.start_link(
        Keyword.merge(
          [
            client: ClientStub,
            bot_did: @bot_did,
            max_pending: 25,
            page_cap: 5,
            poll_interval_ms: 60_000,
            start_immediately: false
          ],
          overrides
        )
      )

    Sandbox.allow(Repo, self(), poller)
    poller
  end

  defp mention(rkey) do
    %{
      "reason" => "mention",
      "uri" => uri(rkey),
      "cid" => cid(rkey),
      "author" => %{"did" => "did:plc:alice", "handle" => "alice.bsky.social"},
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "text" => "@contextbot please help",
        "facets" => [
          %{
            "index" => %{"byteStart" => 0, "byteEnd" => 11},
            "features" => [
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @bot_did}
            ]
          }
        ]
      }
    }
  end

  defp receipt(notification) do
    %{
      uri: notification["uri"],
      cid: notification["cid"],
      actor_did: notification["author"]["did"],
      actor_handle: notification["author"]["handle"],
      raw: notification
    }
  end

  defp page(notifications, cursor \\ nil) do
    %{"notifications" => notifications} |> maybe_put_cursor(cursor)
  end

  defp empty_page(cursor \\ nil), do: page([], cursor)

  defp maybe_put_cursor(page, nil), do: page
  defp maybe_put_cursor(page, cursor), do: Map.put(page, "cursor", cursor)

  defp uri(rkey), do: "at://did:plc:alice/app.bsky.feed.post/#{rkey}"
  defp cid(rkey), do: "bafyreialice#{rkey}"

  defp assert_eventually(assertion, attempts \\ 20)
  defp assert_eventually(assertion, 0), do: assertion.()

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end
end
