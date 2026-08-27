defmodule ContextBot.DryRun.PostReferenceTest.Resolver do
  @moduledoc false

  def resolve_handle(handle) do
    send(self(), {:resolve_handle, handle})
    Process.get(:post_reference_resolver_result)
  end
end

defmodule ContextBot.DryRun.PostReferenceTest do
  use ExUnit.Case, async: true

  alias ContextBot.DryRun.PostReference
  alias ContextBot.DryRun.PostReferenceTest.Resolver

  setup do
    Process.put(
      :post_reference_resolver_result,
      {:ok, 200, %{}, %{"did" => "did:plc:alice"}}
    )

    on_exit(fn -> Process.delete(:post_reference_resolver_result) end)
  end

  test "normalizes a bsky.app handle URL through public resolution" do
    assert {:ok, "at://did:plc:alice/app.bsky.feed.post/3abc"} =
             PostReference.normalize(
               "https://bsky.app/profile/Alice.Example/post/3abc",
               Resolver
             )

    assert_received {:resolve_handle, "alice.example"}
  end

  test "accepts DID URLs and AT URIs without resolution" do
    for input <- [
          "https://bsky.app/profile/did:plc:alice/post/3abc",
          "at://did:plc:alice/app.bsky.feed.post/3abc"
        ] do
      assert {:ok, "at://did:plc:alice/app.bsky.feed.post/3abc"} =
               PostReference.normalize(input, Resolver)
    end

    refute_received {:resolve_handle, _handle}
  end

  test "normalizes a handle-bearing AT URI" do
    assert {:ok, "at://did:plc:alice/app.bsky.feed.post/3abc"} =
             PostReference.normalize(
               "at://Alice.Example/app.bsky.feed.post/3abc",
               Resolver
             )

    assert_received {:resolve_handle, "alice.example"}
  end

  test "detects post-like single arguments without contacting a resolver" do
    assert PostReference.looks_like_post_reference?("at://did:plc:alice/app.bsky.feed.post/3abc")
    assert PostReference.looks_like_post_reference?("at://Alice.Example/app.bsky.feed.post/3abc")
    assert PostReference.looks_like_post_reference?("at://not-even-valid")

    assert PostReference.looks_like_post_reference?(
             "https://bsky.app/profile/alice.example/post/3abc"
           )

    assert PostReference.looks_like_post_reference?(
             "http://bsky.app/profile/alice.example/post/3abc"
           )

    refute PostReference.looks_like_post_reference?("What's missing?")
    refute PostReference.looks_like_post_reference?("Explain at:// versus https.")
    refute PostReference.looks_like_post_reference?("https://example.com/post/3abc")
    refute_received {:resolve_handle, _handle}
  end

  test "rejects malformed and ambiguous post references before resolution" do
    invalid = [
      "http://bsky.app/profile/alice.example/post/3abc",
      "https://bsky.app.evil/profile/alice.example/post/3abc",
      "https://user@bsky.app/profile/alice.example/post/3abc",
      "https://bsky.app:443/profile/alice.example/post/3abc",
      "https://bsky.app/profile/alice.example/post/3abc?view=1",
      "https://bsky.app/profile/alice.example/post/3abc#fragment",
      "https://bsky.app/profile/alice.example/post/3abc/extra",
      "https://bsky.app//profile/alice.example/post/3abc",
      "https://bsky.app/profile//alice.example/post/3abc",
      "https://bsky.app/profile/alice.example//post/3abc",
      "https://bsky.app/profile/alice.example/post//3abc",
      "https://bsky.app/profile/alice.example/post/3abc/",
      "https://bsky.app/profile/-alice.example/post/3abc",
      "https://bsky.app/profile/singlelabel/post/3abc",
      "at://alice.example/app.bsky.feed.like/3abc",
      "at://alice.example/app.bsky.feed.post/.",
      "at://alice.example/app.bsky.feed.post/contains space",
      "not a post",
      String.duplicate("x", 4_097)
    ]

    Enum.each(invalid, fn input ->
      assert {:error, :invalid_post_reference} = PostReference.normalize(input, Resolver)
    end)

    refute_received {:resolve_handle, _handle}
  end

  test "returns finite errors for unavailable or malformed handle resolution" do
    cases = [
      {{:error, :timeout}, {:error, :timeout}},
      {{:ok, 404, %{}, %{"error" => "NotFound"}}, {:error, :invalid_post_reference}},
      {{:ok, 200, %{}, %{}}, {:error, :invalid_post_reference}},
      {{:ok, 200, %{}, %{"did" => "not-a-did"}}, {:error, :invalid_post_reference}}
    ]

    Enum.each(cases, fn {provider_result, expected} ->
      Process.put(:post_reference_resolver_result, provider_result)

      assert ^expected =
               PostReference.normalize(
                 "https://bsky.app/profile/alice.example/post/3abc",
                 Resolver
               )

      assert_received {:resolve_handle, "alice.example"}
    end)
  end
end
