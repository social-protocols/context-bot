defmodule ContextBot.Research.StructuredFixtures do
  @moduledoc false

  @default_title "Context Request"
  @default_full "Writeup."

  @spec structured_json(String.t(), keyword()) :: String.t()
  def structured_json(compact, opts \\ []) when is_binary(compact) do
    Jason.encode!(%{
      "title" => Keyword.get(opts, :title, @default_title),
      "compact_reply" => compact,
      "full_response" => Keyword.get(opts, :full, @default_full)
    })
  end

  @spec selected(String.t(), keyword()) ::
          {:ok,
           %{
             text: String.t(),
             full_response: String.t(),
             document_title: String.t()
           }}
  def selected(compact, opts \\ []) when is_binary(compact) do
    {:ok,
     %{
       text: compact,
       full_response: Keyword.get(opts, :full, @default_full),
       document_title: Keyword.get(opts, :title, @default_title)
     }}
  end
end
