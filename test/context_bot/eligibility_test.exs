defmodule ContextBot.EligibilityTest.ClientStub do
  @moduledoc false

  def get_profile(actor_did, labeler_did) do
    send(self(), {:get_profile, actor_did, labeler_did})
    Process.get({__MODULE__, :profile}, {:error, :timeout})
  end

  def resolve_handle(handle) do
    send(self(), {:resolve_handle, handle})
    Process.get({__MODULE__, :handle}, {:error, :timeout})
  end

  def resolve_did(did) do
    send(self(), {:resolve_did, did})
    Process.get({__MODULE__, :did}, {:error, :timeout})
  end
end

defmodule ContextBot.EligibilityTest do
  use ExUnit.Case, async: true

  alias ContextBot.Eligibility
  alias ContextBot.EligibilityTest.ClientStub
  alias ContextBot.Settings

  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  @skywatch_did "did:plc:e4elbtctnfqocyfcml6h2lf7"
  @now ~U[2026-07-30 12:00:00Z]

  setup do
    on_exit(fn ->
      Process.delete({ClientStub, :profile})
      Process.delete({ClientStub, :handle})
      Process.delete({ClientStub, :did})
    end)

    :ok
  end

  test "operator DID allowlist is the first eligibility rule" do
    settings = settings(operator_allowed_dids: [@actor_did])

    assert {:eligible, :operator_allowlist,
            %{"actor_did" => @actor_did, "source" => "operator_allowlist"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings, ClientStub)

    refute_received {:get_profile, _, _}
  end

  test "accepts an active exact Skywatch Bluesky Elder account label" do
    expires_at = DateTime.add(@now, 1, :second)

    put_profile(
      confirmed_headers(),
      profile([
        elder_label(%{
          "neg" => false,
          "exp" => DateTime.to_iso8601(expires_at),
          "cts" => "2025-01-01T00:00:00Z"
        })
      ])
    )

    assert {:eligible, :bluesky_elder,
            %{
              "actor_did" => @actor_did,
              "label" => "bluesky-elder",
              "labeler_did" => @skywatch_did
            }} = Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)

    assert_received {:get_profile, @actor_did, @skywatch_did}
  end

  test "requires the exact Elder label source, actor URI, value, negation, and expiry semantics" do
    invalid_labels = [
      elder_label(%{"src" => "did:plc:other"}),
      elder_label(%{"uri" => "did:plc:someoneelse"}),
      elder_label(%{"val" => "Bluesky Elder"}),
      elder_label(%{"neg" => true}),
      elder_label(%{"exp" => DateTime.to_iso8601(@now)}),
      elder_label(%{"exp" => "not-a-date"})
    ]

    Enum.each(invalid_labels, fn label ->
      put_profile(confirmed_headers(), profile([label]))

      assert {:eligible, :public, %{"source" => "public"}} =
               Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)
    end)

    put_profile(confirmed_headers(), profile([elder_label()]))

    assert {:eligible, :bluesky_elder, _evidence} =
             Eligibility.check(@actor_did, nil, @now, settings(), ClientStub)
  end

  test "treats confirmed authoritative absence as public" do
    put_profile(confirmed_headers(), profile([]))

    assert {:eligible, :public, %{"actor_did" => @actor_did, "source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)
  end

  test "treats a missing or non-confirming labeler response header as public" do
    put_profile(%{}, profile([]))

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)

    put_profile(%{"atproto-content-labelers" => ["did:plc:not-skywatch"]}, profile([]))

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)
  end

  test "treats profile lookup failures and malformed profile responses as public" do
    Process.put({ClientStub, :profile}, {:error, :timeout})

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)

    put_profile(confirmed_headers(), %{"labels" => "not-a-list"})

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)
  end

  test "accepts a lowercase-normalized bsky.team handle with bidirectional DID agreement" do
    put_profile(confirmed_headers(), profile([]))

    Process.put(
      {ClientStub, :handle},
      {:ok, 200, %{}, %{"did" => @actor_did}}
    )

    Process.put(
      {ClientStub, :did},
      {:ok, 200, %{},
       %{
         "id" => @actor_did,
         "alsoKnownAs" => ["https://example.com/alice", "at://alice.bsky.team"]
       }}
    )

    assert {:eligible, :bsky_team,
            %{
              "actor_did" => @actor_did,
              "handle" => "alice.bsky.team",
              "verification" => "bidirectional"
            }} = Eligibility.check(@actor_did, "Alice.BSKY.Team", @now, settings(), ClientStub)

    assert_received {:resolve_handle, "alice.bsky.team"}
    assert_received {:resolve_did, @actor_did}
  end

  test "accepts the exact bsky.team handle" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})

    Process.put(
      {ClientStub, :did},
      {:ok, 200, %{}, %{"id" => @actor_did, "alsoKnownAs" => ["at://bsky.team"]}}
    )

    assert {:eligible, :bsky_team, %{"handle" => "bsky.team"}} =
             Eligibility.check(@actor_did, "BSKY.TEAM", @now, settings(), ClientStub)
  end

  test "classifies handles without the exact bsky.team suffix boundary as public" do
    put_profile(confirmed_headers(), profile([]))

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "notbsky.team", @now, settings(), ClientStub)

    refute_received {:resolve_handle, _handle}
  end

  test "classifies forward-only and unsupported DID identities as public" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => "did:plc:someoneelse"}})

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)

    refute_received {:resolve_did, _did}

    unsupported_did = "did:key:z6MkUnsupported"

    Process.put(
      {ClientStub, :handle},
      {:ok, 200, %{}, %{"did" => unsupported_did}}
    )

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(
               unsupported_did,
               "alice.bsky.team",
               @now,
               settings(),
               ClientStub
             )

    refute_received {:resolve_did, ^unsupported_did}
  end

  test "requires a matching DID document id and its first valid at handle claim" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})

    invalid_documents = [
      %{"id" => "did:plc:someoneelse", "alsoKnownAs" => ["at://alice.bsky.team"]},
      %{"id" => @actor_did, "alsoKnownAs" => ["at://old.example"]},
      %{
        "id" => @actor_did,
        "alsoKnownAs" => ["at://old.example", "at://alice.bsky.team"]
      },
      %{"id" => @actor_did, "alsoKnownAs" => []}
    ]

    Enum.each(invalid_documents, fn document ->
      Process.put({ClientStub, :did}, {:ok, 200, %{}, document})

      assert {:eligible, :public, %{"source" => "public"}} =
               Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
    end)
  end

  test "skips malformed aliases before the first valid at handle claim" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})

    Process.put(
      {ClientStub, :did},
      {:ok, 200, %{},
       %{
         "id" => @actor_did,
         "alsoKnownAs" => ["at://", "at://did:plc:not-a-handle", "at://alice.bsky.team"]
       }}
    )

    assert {:eligible, :bsky_team, _evidence} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
  end

  test "treats handle and DID document lookup failures as public" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:error, :timeout})

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)

    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})
    Process.put({ClientStub, :did}, {:error, {:transient, 503}})

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
  end

  test "accepts independently verified team eligibility during a Skywatch outage" do
    Process.put({ClientStub, :profile}, {:error, :timeout})
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})

    Process.put(
      {ClientStub, :did},
      {:ok, 200, %{}, %{"id" => @actor_did, "alsoKnownAs" => ["at://alice.bsky.team"]}}
    )

    assert {:eligible, :bsky_team, %{"handle" => "alice.bsky.team"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
  end

  test "never grants Elder from a non-2xx profile response and degrades to public" do
    Process.put(
      {ClientStub, :profile},
      {:ok, 503, confirmed_headers(), profile([elder_label()])}
    )

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.example", @now, settings(), ClientStub)
  end

  test "never authorizes a valid handle body from a non-2xx resolution response" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 503, %{}, %{"did" => @actor_did}})

    Process.put(
      {ClientStub, :did},
      {:ok, 200, %{}, %{"id" => @actor_did, "alsoKnownAs" => ["at://alice.bsky.team"]}}
    )

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
  end

  test "never authorizes a valid DID document body from a non-2xx resolution response" do
    put_profile(confirmed_headers(), profile([]))
    Process.put({ClientStub, :handle}, {:ok, 200, %{}, %{"did" => @actor_did}})

    Process.put(
      {ClientStub, :did},
      {:ok, 503, %{}, %{"id" => @actor_did, "alsoKnownAs" => ["at://alice.bsky.team"]}}
    )

    assert {:eligible, :public, %{"source" => "public"}} =
             Eligibility.check(@actor_did, "alice.bsky.team", @now, settings(), ClientStub)
  end

  defp settings(overrides \\ []) do
    []
    |> Settings.load()
    |> then(&struct!(&1, overrides))
  end

  defp put_profile(headers, body) do
    Process.put({ClientStub, :profile}, {:ok, 200, headers, body})
  end

  defp confirmed_headers do
    %{
      "atproto-content-labelers" => [
        "did:plc:defaultlabeler, #{@skywatch_did}; redact"
      ]
    }
  end

  defp profile(labels), do: %{"did" => @actor_did, "labels" => labels}

  defp elder_label(overrides \\ %{}) do
    Map.merge(
      %{
        "src" => @skywatch_did,
        "uri" => @actor_did,
        "val" => "bluesky-elder",
        "cts" => "2025-01-01T00:00:00Z"
      },
      overrides
    )
  end
end
