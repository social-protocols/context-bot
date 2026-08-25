defmodule ContextBot.Thread.Media do
  @moduledoc """
  Builds and validates the bounded canonical image descriptors used at capture and recovery.

  Validation is intentionally shared by both paths so a malformed stored checkpoint cannot
  broaden the URLs or media volume that were accepted from the public AppView response.
  """

  alias ContextBot.ATProto.ATURI

  @max_images 4
  @max_image_url_bytes 2_048
  @max_image_alt_bytes 4_096
  @max_canonical_media_bytes 32_768
  @image_cdn_host "cdn.bsky.app"
  @image_path_prefix "/img/feed_fullsize/plain/"

  @type descriptor :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  @spec max_images() :: pos_integer()
  def max_images, do: @max_images

  @spec descriptor(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def descriptor(%{"fullsize" => url, "alt" => alt}, post_uri)
      when is_binary(url) and is_binary(alt) and is_binary(post_uri) do
    with :ok <- valid_post_uri(post_uri),
         :ok <- valid_alt(alt),
         :ok <- valid_image_url(url) do
      {:ok,
       %{
         "type" => "image",
         "post_uri" => post_uri,
         "url" => url,
         "alt" => alt
       }}
    end
  end

  def descriptor(_image, _post_uri), do: {:error, :invalid_image}

  @doc "Validates an exact, numbered canonical-media checkpoint."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(media) when is_list(media) and length(media) <= @max_images do
    with :ok <- validate_descriptors(media),
         {:ok, encoded} <- Jason.encode(media),
         true <- byte_size(encoded) <= @max_canonical_media_bytes do
      :ok
    else
      false -> {:error, :invalid_media}
      {:error, _reason} = error -> error
    end
  end

  def validate(_media), do: {:error, :invalid_media}

  defp validate_descriptors(media) do
    media
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {descriptor, index}, :ok ->
      case valid_descriptor(descriptor, index) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_descriptor(
         %{
           "type" => "image",
           "index" => index,
           "post_uri" => post_uri,
           "url" => url,
           "alt" => alt
         } = descriptor,
         index
       )
       when map_size(descriptor) == 5 and is_binary(post_uri) and is_binary(url) and
              is_binary(alt) do
    with :ok <- valid_post_uri(post_uri),
         :ok <- valid_alt(alt) do
      valid_image_url(url)
    end
  end

  defp valid_descriptor(_descriptor, _index), do: {:error, :invalid_media}

  defp valid_post_uri(post_uri) do
    case ATURI.parse(post_uri) do
      {:ok, _parsed} -> :ok
      :error -> {:error, :invalid_image_post_uri}
    end
  end

  defp valid_alt(alt) do
    if String.valid?(alt) and byte_size(alt) <= @max_image_alt_bytes,
      do: :ok,
      else: {:error, :invalid_image_alt}
  end

  defp valid_image_url(url) when byte_size(url) <= @max_image_url_bytes do
    with {:ok,
          %URI{
            scheme: "https",
            host: @image_cdn_host,
            userinfo: nil,
            fragment: nil,
            port: 443,
            query: nil,
            path: path
          }}
         when is_binary(path) <- URI.new(url),
         true <- String.starts_with?(path, @image_path_prefix),
         true <- byte_size(path) > byte_size(@image_path_prefix) do
      :ok
    else
      _invalid_url -> {:error, :invalid_image_url}
    end
  end

  defp valid_image_url(_url), do: {:error, :invalid_image_url}
end
