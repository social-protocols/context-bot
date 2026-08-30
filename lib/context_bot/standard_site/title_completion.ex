defmodule ContextBot.StandardSite.TitleCompletion do
  @moduledoc """
  Best-effort paid Reader title completion.

  Uses `READER_TITLE_V1` as a separate Messages call. A failed, empty, or
  unusable title must not block document create or publication.
  """

  alias ContextBot.Research.AnthropicClient
  alias ContextBot.StandardSite.TitlePrompt

  @max_tokens 64

  @type settings :: %{optional(atom()) => term()} | %{optional(String.t()) => term()}
  @type opts :: [
          {:settings, settings()}
          | {:client, module()}
        ]

  @spec max_tokens() :: pos_integer()
  def max_tokens, do: @max_tokens

  @doc "Small tool-free Messages request for one Reader headline."
  @spec request(String.t(), settings()) :: map()
  def request(invocation_text, settings) when is_binary(invocation_text) do
    %{
      "model" => model_id(settings),
      "max_tokens" => @max_tokens,
      "stream" => false,
      "output_config" => %{"effort" => "low"},
      "system" => TitlePrompt.prompt(),
      "messages" => [
        %{"role" => "user", "content" => TitlePrompt.user_message(invocation_text)}
      ]
    }
  end

  @doc """
  Completes one title from the raw invoking-post text.

  Returns `:error` when the text is blank or the provider call cannot yield a
  nonempty headline. Never raises to the caller.
  """
  @spec complete(String.t() | nil, opts()) :: {:ok, String.t()} | :error
  def complete(invocation_text, opts) when is_binary(invocation_text) and is_list(opts) do
    settings = Keyword.fetch!(opts, :settings)
    client = Keyword.get(opts, :client, AnthropicClient)

    with text when text != "" <- String.trim(invocation_text),
         {:ok, envelope} <- send_title(client, request(text, settings)),
         {:ok, title} <- title_from_envelope(envelope) do
      {:ok, title}
    else
      _failed -> :error
    end
  end

  def complete(_invocation_text, opts) when is_list(opts), do: :error

  defp send_title(client, request) do
    client.send_message(request, %{attempt_key: "title", kind: :title})
  rescue
    _exception -> {:error, :title_client}
  end

  defp title_from_envelope(%{status: status, raw_body: raw_body})
       when status in 200..299 and is_binary(raw_body) do
    with {:ok, decoded} <- Jason.decode(raw_body),
         title when title != "" <- text_from_content(decoded) do
      {:ok, title}
    else
      _invalid -> :error
    end
  end

  defp title_from_envelope(_envelope), do: :error

  defp text_from_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join(" ")
    |> String.trim()
    |> strip_wrapping_quotes()
  end

  defp text_from_content(_decoded), do: ""

  defp strip_wrapping_quotes(text) do
    trimmed = String.trim(text)

    cond do
      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") and
          String.length(trimmed) >= 2 ->
        trimmed |> String.slice(1..-2//1) |> String.trim()

      String.starts_with?(trimmed, "'") and String.ends_with?(trimmed, "'") and
          String.length(trimmed) >= 2 ->
        trimmed |> String.slice(1..-2//1) |> String.trim()

      true ->
        trimmed
    end
  end

  defp model_id(%{anthropic_model_id: model_id}) when is_binary(model_id), do: model_id
  defp model_id(%{"anthropic_model_id" => model_id}) when is_binary(model_id), do: model_id
end
