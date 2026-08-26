defmodule Mix.Tasks.ContextBot.DeletePosts do
  @moduledoc "Delete specific Bluesky posts by rkey."

  use Mix.Task

  alias ContextBot.ATProto.ReqClient
  alias ContextBot.ATProto.Session

  @requirements ["app.config"]
  @shortdoc "Delete specific Bluesky posts"
  @collection "app.bsky.feed.post"

  @impl Mix.Task
  def run(args) do
    case args do
      [repo, rkey1, rkey2] ->
        delete_posts(repo, [rkey1, rkey2])

      _ ->
        Mix.raise("Usage: mix context_bot.delete_posts <repo_did> <rkey1> <rkey2>")
    end
  end

  defp delete_posts(repo, rkeys) do
    validate_environment!()
    start_session!()

    Mix.shell().info("Starting deletion of posts from repo: #{repo}")
    Mix.shell().info("Collection: #{@collection}")

    Enum.each(rkeys, fn rkey ->
      Mix.shell().info("\nDeleting rkey: #{rkey}")
      delete_record(repo, rkey)
    end)

    Mix.shell().info("\nDeletion complete. Verifying...")

    Enum.each(rkeys, fn rkey ->
      verify_deleted(repo, rkey)
    end)

    Mix.shell().info("\nAll done!")
  end

  defp delete_record(repo, rkey) do
    case ReqClient.delete_record(repo, @collection, rkey) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        Mix.shell().info("✓ Successfully deleted #{rkey} (status: #{status})")

      {:error, :record_not_found} ->
        Mix.shell().info("✓ Record #{rkey} not found (already deleted)")

      {:error, reason} ->
        Mix.shell().error("✗ Failed to delete #{rkey}: #{inspect(reason)}")
        Mix.raise("Deletion failed")

      other ->
        Mix.shell().error("✗ Unexpected response for #{rkey}: #{inspect(other)}")
        Mix.raise("Deletion failed")
    end
  end

  defp verify_deleted(repo, rkey) do
    Mix.shell().info("\nVerifying #{rkey} is deleted...")

    # Use public API to verify
    public_url =
      "https://public.api.bsky.app/xrpc/com.atproto.repo.getRecord" <>
        "?repo=#{URI.encode_www_form(repo)}" <>
        "&collection=#{URI.encode_www_form(@collection)}" <>
        "&rkey=#{URI.encode_www_form(rkey)}"

    case Req.get(public_url) do
      {:ok, %{status: 404}} ->
        Mix.shell().info("✓ Confirmed: #{rkey} is not accessible (404)")

      {:ok, %{status: 400, body: %{"error" => "RecordNotFound"}}} ->
        Mix.shell().info("✓ Confirmed: #{rkey} is not found")

      {:ok, %{status: status, body: body}} ->
        Mix.shell().error("✗ Record #{rkey} still exists (status: #{status})")
        Mix.shell().error("   Body: #{inspect(body)}")

      {:error, reason} ->
        Mix.shell().error("✗ Verification failed for #{rkey}: #{inspect(reason)}")
    end
  end

  defp validate_environment! do
    password = System.get_env("BOT_APP_PASSWORD")

    unless password && String.trim(password) != "" do
      Mix.raise("BOT_APP_PASSWORD environment variable is required")
    end

    settings = Application.fetch_env!(:context_bot, :settings)

    unless settings.bot_did && String.trim(settings.bot_did) != "" do
      Mix.raise("BOT_DID is required (configure in config/runtime.exs or environment)")
    end

    unless settings.bot_pds_url && String.trim(settings.bot_pds_url) != "" do
      Mix.raise("BOT_PDS_URL is required (configure in config/runtime.exs or environment)")
    end
  end

  defp start_session! do
    # Session is started by the application, just verify it can authenticate
    case Session.status() do
      {:ok, %{authenticated?: false}} ->
        # Try to authenticate
        case Session.access_token() do
          {:ok, _token} ->
            Mix.shell().info("✓ Authenticated with ATProto")

          {:error, reason} ->
            Mix.raise("Authentication failed: #{inspect(reason)}")
        end

      {:ok, %{authenticated?: true}} ->
        Mix.shell().info("✓ Already authenticated")

      {:error, reason} ->
        Mix.raise("Session unavailable: #{inspect(reason)}")
    end
  end
end
