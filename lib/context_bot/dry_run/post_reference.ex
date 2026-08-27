defmodule ContextBot.DryRun.PostReference do
  @moduledoc """
  Strictly normalizes public Bluesky post references to DID-based AT URIs.
  """

  alias ContextBot.ATProto.ATURI

  @maximum_input_bytes 4_096
  @post_collection "app.bsky.feed.post"
  @at_post ~r/\Aat:\/\/([^\/]+)\/app\.bsky\.feed\.post\/([^\/?#]+)\z/
  @web_post_path ~r/\A\/profile\/([^\/]+)\/post\/([^\/]+)\z/
  @handle_label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @spec looks_like_post_reference?(String.t()) :: boolean()
  def looks_like_post_reference?(input) when is_binary(input) do
    trimmed = String.trim(input)
    String.starts_with?(trimmed, "at://") or bsky_app_url?(trimmed)
  end

  def looks_like_post_reference?(_input), do: false

  @spec normalize(String.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def normalize(input, resolver) when is_binary(input) and is_atom(resolver) do
    with :ok <- valid_input?(input),
         {:ok, repo, rkey} <- parse(input),
         :ok <- valid_rkey?(rkey),
         {:ok, did} <- resolve_repo(repo, resolver),
         {:ok, uri} <- canonical_uri(did, rkey) do
      {:ok, uri}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize(_input, _resolver), do: {:error, :invalid_post_reference}

  defp valid_input?(input) do
    if input != "" and byte_size(input) <= @maximum_input_bytes and String.valid?(input),
      do: :ok,
      else: {:error, :invalid_post_reference}
  end

  defp parse("https://" <> _rest = input), do: parse_web_url(input)

  defp parse("at://" <> _rest = input) do
    case Regex.run(@at_post, input) do
      [_, repo, rkey] -> {:ok, repo, rkey}
      _invalid -> {:error, :invalid_post_reference}
    end
  end

  defp parse(_input), do: {:error, :invalid_post_reference}

  defp bsky_app_url?(input) do
    case URI.new(input) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        host == "bsky.app"

      _invalid ->
        String.starts_with?(input, "https://bsky.app/") or
          String.starts_with?(input, "http://bsky.app/")
    end
  end

  defp parse_web_url(input) do
    with {:ok,
          %URI{
            scheme: "https",
            host: "bsky.app",
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          }} <- URI.new(input),
         "bsky.app" <- web_authority(input),
         [_, repo, rkey] <- Regex.run(@web_post_path, path) do
      {:ok, repo, rkey}
    else
      _invalid -> {:error, :invalid_post_reference}
    end
  end

  defp web_authority("https://" <> rest), do: rest |> String.split("/", parts: 2) |> hd()

  defp valid_rkey?(rkey) do
    case ATURI.parse("at://did:plc:placeholder/#{@post_collection}/#{rkey}") do
      {:ok, _post} -> :ok
      :error -> {:error, :invalid_post_reference}
    end
  end

  defp resolve_repo("did:" <> _method_specific = did, _resolver), do: {:ok, did}

  defp resolve_repo(handle, resolver) do
    normalized = String.downcase(handle)

    if valid_handle?(normalized) do
      case resolver.resolve_handle(normalized) do
        {:ok, status, _headers, %{"did" => did}} when status in 200..299 and is_binary(did) ->
          {:ok, did}

        {:error, reason} ->
          {:error, reason}

        _invalid ->
          {:error, :invalid_post_reference}
      end
    else
      {:error, :invalid_post_reference}
    end
  end

  defp canonical_uri(did, rkey) do
    uri = "at://#{did}/#{@post_collection}/#{rkey}"

    case ATURI.parse(uri) do
      {:ok, _post} -> {:ok, uri}
      :error -> {:error, :invalid_post_reference}
    end
  end

  defp valid_handle?(handle) do
    labels = String.split(handle, ".", trim: false)
    top_level = List.last(labels)

    byte_size(handle) in 1..253 and length(labels) >= 2 and
      Enum.all?(labels, &valid_handle_label?/1) and is_binary(top_level) and
      Regex.match?(~r/[a-z]/, top_level)
  end

  defp valid_handle_label?(label),
    do: byte_size(label) in 1..63 and Regex.match?(@handle_label, label)
end
