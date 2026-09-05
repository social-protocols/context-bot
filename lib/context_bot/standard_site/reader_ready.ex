defmodule ContextBot.StandardSite.ReaderReady do
  @moduledoc """
  Decides whether a Standard.site document is indexed on Standard Reader.

  A latched `reader_ready_at` is authoritative and does not probe. Otherwise this
  calls `ReaderIndex.check/1` and persists the result through
  `Store.record_reader_index/3`. `:not_indexed` and `:ambiguous` stay waiting.
  """

  alias ContextBot.StandardSite.ReaderIndex
  alias ContextBot.Workflow.{Invocation, Store}

  @type wait_reason :: :not_indexed | :ambiguous

  @spec ensure(Invocation.t(), keyword()) ::
          {:ready, Invocation.t()} | {:wait, wait_reason(), Invocation.t()}
  def ensure(%Invocation{} = invocation, opts \\ []) do
    cond do
      match?(%DateTime{}, invocation.reader_ready_at) ->
        {:ready, invocation}

      missing_document_uri?(invocation) ->
        {:wait, :ambiguous, invocation}

      true ->
        probe(invocation, opts)
    end
  end

  defp probe(invocation, opts) do
    check = Keyword.get(opts, :check, &ReaderIndex.check/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    result = probe_result(check, invocation.standard_site_document_uri)

    case Store.record_reader_index(invocation, result, now) do
      {:ok, updated} when result == :indexed ->
        {:ready, updated}

      {:ok, updated} when result in [:not_indexed, :ambiguous] ->
        {:wait, result, updated}

      {:ok, updated} ->
        {:wait, :ambiguous, updated}

      {:error, _changeset} ->
        {:wait, :ambiguous, invocation}
    end
  end

  defp probe_result(check, uri) do
    check.(uri)
  rescue
    _exception -> :ambiguous
  end

  defp missing_document_uri?(%Invocation{standard_site_document_uri: uri})
       when is_binary(uri) and uri != "",
       do: false

  defp missing_document_uri?(_invocation), do: true
end
