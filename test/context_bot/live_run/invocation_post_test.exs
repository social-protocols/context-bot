defmodule ContextBot.LiveRun.InvocationPostTest do
  use ExUnit.Case, async: false

  alias ContextBot.LiveRun.InvocationPost
  alias ContextBot.Settings

  @bot_did "did:plc:contextbot"
  @actor_did "did:plc:actor"
  @invocation_uri "at://did:plc:actor/app.bsky.feed.post/3demo"

  defmodule StubClient do
    def get_post_thread(uri, parent_height) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:get_post_thread, uri, parent_height})
      config[:response]
    end
  end

  defmodule StubResolver do
    def resolve_handle(handle) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:resolve_handle, handle})
      config[:response]
    end
  end

  setup do
    original_client = Application.get_env(:context_bot, StubClient, :missing)
    original_resolver = Application.get_env(:context_bot, StubResolver, :missing)

    on_exit(fn ->
      restore_env(StubClient, original_client)
      restore_env(StubResolver, original_resolver)
    end)

    :ok
  end

  test "resolves a Bluesky invocation URL to its DID-based AT URI" do
    Application.put_env(:context_bot, StubResolver,
      test_pid: self(),
      response: {:ok, 200, %{}, %{"did" => @actor_did}}
    )

    assert {:ok, @invocation_uri} =
             InvocationPost.resolve(
               "https://bsky.app/profile/actor.test/post/3demo",
               StubResolver
             )

    assert_receive {:resolve_handle, "actor.test"}
  end

  test "returns a bounded operator receipt for a real direct mention" do
    settings = settings()
    body = invocation_thread("@getcontext.bot ¿Qué falta?", mention_range(0, 15, @bot_did))
    configure_client({:ok, 200, %{}, body})

    assert {:ok, receipt} =
             InvocationPost.fetch(@invocation_uri, settings, client: StubClient)

    assert receipt.uri == @invocation_uri
    assert receipt.cid == "bafy-invocation"
    assert receipt.actor_did == @actor_did
    assert receipt.actor_handle == "actor.test"
    assert receipt.invocation_text == "¿Qué falta?"
    assert receipt.raw["source"] == "local_live_demo"
    assert receipt.raw["post"] == body["thread"]["post"]
    assert_receive {:get_post_thread, @invocation_uri, 80}
  end

  test "removes every bot mention by UTF-8 byte offsets without changing other text" do
    text = "¿Por qué? @getcontext.bot y @getcontext.bot"
    first_start = byte_size("¿Por qué? ")
    first_end = first_start + byte_size("@getcontext.bot")
    second_start = first_end + byte_size(" y ")
    second_end = second_start + byte_size("@getcontext.bot")

    body =
      invocation_thread(text, [
        mention_range(first_start, first_end, @bot_did),
        mention_range(second_start, second_end, @bot_did)
      ])

    configure_client({:ok, 200, %{}, body})

    assert {:ok, receipt} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)

    assert receipt.invocation_text == "¿Por qué? y"
  end

  test "rejects a post whose only text is the bot mention" do
    body = invocation_thread("@getcontext.bot", mention_range(0, 15, @bot_did))
    configure_client({:ok, 200, %{}, body})

    assert {:error, :missing_question} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
  end

  test "rejects malformed mention byte ranges before creating a receipt" do
    for facet <- [
          mention_range(-1, 15, @bot_did),
          mention_range(0, 99, @bot_did),
          mention_range(15, 15, @bot_did),
          mention_range(1, 15, @bot_did)
        ] do
      body = invocation_thread("@getcontext.bot question", facet)
      configure_client({:ok, 200, %{}, body})

      assert {:error, :invalid_mention_range} =
               InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
    end
  end

  test "rejects overlapping bot mention ranges without raising" do
    body =
      invocation_thread("@abc@getcontext.bot question", [
        mention_range(0, 19, @bot_did),
        mention_range(4, 19, @bot_did)
      ])

    configure_client({:ok, 200, %{}, body})

    assert {:error, :invalid_mention_range} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
  end

  test "rejects a selected post that is not the requested invocation" do
    body =
      "@getcontext.bot question"
      |> invocation_thread(mention_range(0, 15, @bot_did))
      |> put_in(
        ["thread", "post", "uri"],
        "at://did:plc:actor/app.bsky.feed.post/different"
      )

    configure_client({:ok, 200, %{}, body})

    assert {:error, :invalid_post} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
  end

  test "rejects self-authorship and posts that do not directly mention the bot" do
    self_post =
      "@getcontext.bot question"
      |> invocation_thread(mention_range(0, 15, @bot_did))
      |> put_in(["thread", "post", "author", "did"], @bot_did)
      |> put_in(
        ["thread", "post", "uri"],
        "at://did:plc:contextbot/app.bsky.feed.post/3demo"
      )

    configure_client({:ok, 200, %{}, self_post})

    assert {:error, :invalid_author} =
             InvocationPost.fetch(
               "at://did:plc:contextbot/app.bsky.feed.post/3demo",
               settings(),
               client: StubClient
             )

    missing_mention = invocation_thread("question", [])
    configure_client({:ok, 200, %{}, missing_mention})

    assert {:error, :missing_mention_facet} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
  end

  test "rejects unavailable and malformed thread responses and preserves finite client errors" do
    for type <- ["app.bsky.feed.defs#blockedPost", "app.bsky.feed.defs#notFoundPost"] do
      configure_client({:ok, 200, %{}, %{"thread" => %{"$type" => type}}})

      assert {:error, :target_unavailable} =
               InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
    end

    configure_client({:ok, 200, %{}, %{"thread" => %{}}})

    assert {:error, :invalid_post} =
             InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)

    for error <- [:timeout, :response_too_large, {:rate_limited, "2"}, {:transient, 503}] do
      configure_client({:error, error})

      assert {:error, ^error} =
               InvocationPost.fetch(@invocation_uri, settings(), client: StubClient)
    end
  end

  defp settings do
    Settings.load(bot_did: @bot_did, thread_parent_height: 80)
  end

  defp configure_client(response) do
    Application.put_env(:context_bot, StubClient, test_pid: self(), response: response)
  end

  defp mention_range(first, last, did) do
    %{
      "index" => %{"byteStart" => first, "byteEnd" => last},
      "features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}]
    }
  end

  defp invocation_thread(text, facets) when not is_list(facets),
    do: invocation_thread(text, [facets])

  defp invocation_thread(text, facets) do
    %{
      "thread" => %{
        "$type" => "app.bsky.feed.defs#threadViewPost",
        "post" => %{
          "uri" => @invocation_uri,
          "cid" => "bafy-invocation",
          "author" => %{"did" => @actor_did, "handle" => "actor.test"},
          "record" => %{
            "$type" => "app.bsky.feed.post",
            "text" => text,
            "facets" => facets,
            "createdAt" => "2026-08-11T12:00:00.000Z"
          }
        }
      }
    }
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
