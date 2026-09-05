defmodule ContextBot.StandardSite.ReaderReady do
  @moduledoc """
  Decides whether a Standard.site document is indexed on Standard Reader.

  A latched `reader_ready_at` is authoritative and does not probe. A recent
  `reader_checked_at` inside the negative TTL (the same 60s window Mirror uses
  for `/r/{id}` 302 decisions) stays waiting without calling AppView. Otherwise
  this calls `ReaderIndex.check/1` and persists the result through
  `Store.record_reader_index/3`. `:not_indexed` and `:ambiguous` stay waiting.
  """

  alias ContextBot.StandardSite.ReaderIndex
  alias ContextBot.Workflow.{Invocation, Store}

  @negative_ttl_ms 60_000

  @type wait_reason :: :not_indexed | :ambiguous

  @doc "Negative-cache window shared with Mirror `/r/{id}` 302 decisions."
  @spec negative_ttl_ms() :: pos_integer()
  def negative_ttl_ms, do: @negative_ttl_ms

  @doc """
  True when `reader_checked_at` is still inside the negative TTL.

  `Mirror.serve/2` uses this for 302 decisions so follower-card waits and
  public mirror hits skip `app.standard-reader.getDocument` for one window.
  """
  @spec recently_checked?(DateTime.t() | nil, DateTime.t(), pos_integer()) :: boolean()
  def recently_checked?(checked_at, now, ttl_ms \\ @negative_ttl_ms)

  def recently_checked?(%DateTime{} = checked_at, now, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    DateTime.diff(now, checked_at, :millisecond) < ttl_ms
  end

  def recently_checked?(_checked_at, _now, _ttl_ms), do: false

  @spec ensure(Invocation.t(), keyword()) ::
          {:ready, Invocation.t()} | {:wait, wait_reason(), Invocation.t()}
  def ensure(%Invocation{} = invocation, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_ms = Keyword.get(opts, :ttl_ms, @negative_ttl_ms)

    cond do
      match?(%DateTime{}, invocation.reader_ready_at) ->
        {:ready, invocation}

      missing_document_uri?(invocation) ->
        {:wait, :ambiguous, invocation}

      recently_checked?(invocation.reader_checked_at, now, ttl_ms) ->
        {:wait, :not_indexed, invocation}

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
