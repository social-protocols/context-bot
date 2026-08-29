defmodule ContextBot.FundingTest.ClientStub do
  @moduledoc false

  def get_profile(actor_did, labeler_did) do
    send(self(), {:get_profile, actor_did, labeler_did})

    Process.get(
      {__MODULE__, {:profile, actor_did}},
      Process.get({__MODULE__, :profile}, {:error, :timeout})
    )
  end
end

defmodule ContextBot.FundingTest do
  use ExUnit.Case, async: true

  alias ContextBot.Funding
  alias ContextBot.FundingTest.ClientStub

  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  @parent_did "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"
  @root_did "did:plc:cccccccccccccccccccccccc"
  @skywatch_did "did:plc:e4elbtctnfqocyfcml6h2lf7"

  test "matches an exact handle case-insensitively" do
    key = fund("jw", ["jonathanwarden.com"])
    account = %{did: @parent_did, handle: "JonathanWarden.com"}

    assert Funding.matching_keys([key], [account]) == [key]
    assert {:ok, %{id: "jw", handle: "jonathanwarden.com"}} = Funding.select([account], [key])
  end

  test "matches *.bsky.team against one or more labels before the suffix" do
    key = fund("team", ["*.bsky.team"])

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "foo.bsky.team"}]) == [key]

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "bar.foo.bsky.team"}]) == [
             key
           ]

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "bsky.team"}]) == []
    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "notbsky.team"}]) == []
  end

  test "matches * against any handle and not an unknown handle" do
    key = fund("all", ["*"])

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "anyone.example"}]) == [key]
    assert Funding.matching_keys([key], [%{did: @parent_did, handle: nil}]) == []
  end

  test "ORs several patterns on one key" do
    key = fund("jw", ["jonathanwarden.com", "moultano.bsky.social", "did:plc:other"])

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "moultano.bsky.social"}]) ==
             [key]

    assert Funding.matching_keys([key], [%{did: "did:plc:other", handle: "x.example"}]) == [key]
    assert Funding.matching_keys([key], [%{did: @parent_did, handle: "stranger.example"}]) == []
  end

  test "accepts an exact DID pattern without a handle" do
    key = fund("plc", [@parent_did])

    assert Funding.matching_keys([key], [%{did: @parent_did, handle: nil}]) == [key]
  end

  test "chooses only among the keys that match" do
    keys = [fund("a", ["*"]), fund("b", ["foo.example"]), fund("c", ["nomatch.example"])]
    account = %{did: @parent_did, handle: "foo.example"}

    chooser = fn candidates ->
      assert Enum.map(candidates, & &1.id) |> Enum.sort() == ["a", "b"]
      Enum.find(candidates, &(&1.id == "b"))
    end

    assert {:ok, %{id: "b", handle: "foo.example"}} = Funding.select([account], keys, chooser)
  end

  test "returns none when no key matches" do
    assert Funding.select(
             [%{did: @parent_did, handle: "stranger.example"}],
             [fund("jw", ["jonathanwarden.com"])]
           ) == :none
  end

  test "reads parent then root authors from the notification and does not guess" do
    notification = reply_notification(@parent_did, @root_did)

    assert Funding.thread_accounts(notification, @actor_did, "stranger.example") == [
             %{did: @parent_did, handle: nil},
             %{did: @root_did, handle: nil}
           ]

    assert Funding.thread_accounts(top_level_notification(), @actor_did, "Alice.Example") == [
             %{did: @actor_did, handle: "alice.example"}
           ]

    broken = %{
      "record" => %{
        "reply" => %{
          "parent" => %{"uri" => "not-an-at-uri"},
          "root" => %{"uri" => "also-bad"}
        }
      }
    }

    assert Funding.thread_accounts(broken, @actor_did, "alice.example") == []
  end

  test "resolves a missing subject handle from the profile and treats lookup failure as retryable" do
    Process.put(
      {ClientStub, {:profile, @parent_did}},
      {:ok, 200, %{}, %{"did" => @parent_did, "handle" => "JonathanWarden.com"}}
    )

    assert {:ok, [%{did: @parent_did, handle: "jonathanwarden.com"}]} =
             Funding.resolve_handles(
               [%{did: @parent_did, handle: nil}],
               @skywatch_did,
               ClientStub
             )

    assert_received {:get_profile, @parent_did, @skywatch_did}

    Process.put({ClientStub, {:profile, @parent_did}}, {:error, :timeout})

    assert {:error, :identity_unavailable} =
             Funding.resolve_handles(
               [%{did: @parent_did, handle: nil}],
               @skywatch_did,
               ClientStub
             )
  end

  test "falls back to the operator Anthropic key when a fund has no credential" do
    previous = Application.get_env(:context_bot, :funding_api_keys)

    on_exit(fn ->
      if previous do
        Application.put_env(:context_bot, :funding_api_keys, previous)
      else
        Application.delete_env(:context_bot, :funding_api_keys)
      end
    end)

    Application.put_env(:context_bot, :funding_api_keys, %{
      "jw" => "funding-test-key-never-expose"
    })

    assert Funding.credential("jw") == "funding-test-key-never-expose"
    assert Funding.credential("missing") == "anthropic-test-key-never-expose"
    assert Funding.fund_secret("jw") == "funding-test-key-never-expose"
    assert Funding.fund_secret("missing") == nil
    assert Funding.env_secret_name("my-fund") == "FUNDING_KEY_MY_FUND_ANTHROPIC_API_KEY"
  end

  test "payer attrs store the opaque fund id and matched handle" do
    assert Funding.payer_attrs(%{id: "jw", handle: "foo.bsky.team", did: @parent_did}) == %{
             payer_kind: "funded_handle",
             payer_fund_id: "jw",
             payer_handle: "foo.bsky.team"
           }

    assert Funding.community_payer() == %{
             payer_kind: "community_pot",
             payer_fund_id: nil,
             payer_handle: nil
           }
  end

  defp fund(id, patterns), do: %{id: id, patterns: patterns}

  defp reply_notification(parent_did, root_did) do
    %{
      "reason" => "mention",
      "author" => %{"did" => @actor_did, "handle" => "stranger.example"},
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "reply" => %{
          "parent" => %{"uri" => "at://#{parent_did}/app.bsky.feed.post/3kparent"},
          "root" => %{"uri" => "at://#{root_did}/app.bsky.feed.post/3kroot"}
        }
      }
    }
  end

  defp top_level_notification do
    %{
      "reason" => "mention",
      "author" => %{"did" => @actor_did, "handle" => "alice.example"},
      "record" => %{"$type" => "app.bsky.feed.post", "text" => "please add context"}
    }
  end
end
