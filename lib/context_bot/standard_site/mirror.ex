defmodule ContextBot.StandardSite.Mirror do
  @moduledoc """
  Public getcontext.bot mirror of a published Standard.site full-response document.

  URL shape: `https://getcontext.bot/r/{invocation_id}` is the stable published
  link written into new Bluesky `(full response)` facets. `GET /r/{document_rkey}`
  is an alias so already-published Reader URLs and the homepage example resolve
  without rewriting old posts.

  Redirect policy: **302 Found**, never 301. The mirror URL is the durable
  user-facing identifier in Bluesky posts. Reader readiness is eventual and
  can theoretically regress; a 301 would pin browsers and CDNs to Reader even
  when a later probe is ambiguous. After `reader_ready_at` latches we still
  302 so a future outage can fail open to this page.

  Indexed detection: `ReaderIndex.check/1` (`app.standard-reader.getDocument`).
  A confirmed ready result latches `reader_ready_at`. A miss or ambiguous
  probe only stores `reader_checked_at` (default negative TTL 60s) so we do
  not hammer Reader on every hit. Ambiguity stays on the mirror.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.Request
  alias ContextBot.StandardSite.{Document, PageCopy, PromptDocument, ReaderIndex}
  alias ContextBot.Workflow.{Invocation, Store}

  @public_base_url "https://getcontext.bot"
  @negative_ttl_ms 60_000

  @type serve_result ::
          {:redirect, String.t()}
          | {:mirror, Invocation.t(), String.t()}
          | :not_found

  @doc "Stable public mirror URL for a persisted invocation, or nil."
  @spec public_url(Invocation.t() | map() | pos_integer() | nil) :: String.t() | nil
  def public_url(%{id: id}) when is_integer(id) and id > 0, do: public_url(id)
  def public_url(id) when is_integer(id) and id > 0, do: "#{@public_base_url}/r/#{id}"
  def public_url(_id), do: nil

  @doc "Looks up a publishable invocation by integer id or document rkey."
  @spec fetch(String.t() | integer()) :: Invocation.t() | nil
  def fetch(id_or_rkey) do
    cond do
      is_integer(id_or_rkey) and id_or_rkey > 0 ->
        id_or_rkey |> invocation_query() |> Repo.one() |> publishable()

      is_binary(id_or_rkey) ->
        fetch_binary(id_or_rkey)

      true ->
        nil
    end
  end

  @doc """
  Decides whether to 302 to Standard Reader or render the sqlite-backed mirror.

  `opts`:

  * `:check` — `(document_uri -> :indexed | :not_indexed | :ambiguous)`
  * `:now` — `DateTime` for TTL and cache writes
  * `:ttl_ms` — negative-cache window (default 60_000)
  """
  @spec serve(String.t() | integer(), keyword()) :: serve_result()
  def serve(id_or_rkey, opts \\ []) do
    case fetch(id_or_rkey) do
      nil ->
        :not_found

      invocation ->
        decide(invocation, opts)
    end
  end

  @doc "Markdown published on Standard Reader, rebuilt from stored invocation fields."
  @spec format_markdown(Invocation.t()) :: String.t()
  def format_markdown(%Invocation{} = invocation) do
    content = document_content(invocation)

    try do
      Document.format_markdown(content)
    rescue
      MatchError -> fallback_markdown(content)
      FunctionClauseError -> fallback_markdown(content)
    end
  end

  @doc "Title/description/prompt inputs reused by `Document.format_markdown/1`."
  @spec document_content(Invocation.t()) :: Document.document_content()
  def document_content(%Invocation{} = invocation) do
    settings = Application.fetch_env!(:context_bot, :settings)
    repo = document_repo(invocation) || settings.bot_did || "did:plc:missing"
    subject = PageCopy.subject(invocation, settings)
    request = invocation.anthropic_messages || %{}

    projection =
      Request.public_projection(request, %{
        anthropic_api_version: settings.anthropic_api_version,
        research_max_tokens: settings.anthropic_research_max_tokens
      })

    %{
      full_response: invocation.full_response || "",
      selected_reply: invocation.selected_reply || "",
      invocation_uri: invocation.invocation_uri,
      asked_text: subject.asked_text,
      parent_uri: subject.parent_uri,
      invoker_handle: subject.invoker_handle,
      parent_handle: subject.parent_handle,
      document_title: stored_document_title(invocation),
      document_reader_url: public_url(invocation),
      prompt: PromptDocument.research_ref(repo),
      structure_prompt: PromptDocument.structure_ref(repo),
      parameters: projection.parameters
    }
  end

  defp decide(invocation, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_ms = Keyword.get(opts, :ttl_ms, @negative_ttl_ms)
    check = Keyword.get(opts, :check) || index_check()
    reader_url = Document.reader_url_from_uri(invocation.standard_site_document_uri)

    cond do
      is_nil(reader_url) ->
        {:mirror, invocation, format_markdown(invocation)}

      match?(%DateTime{}, invocation.reader_ready_at) ->
        {:redirect, reader_url}

      recently_checked?(invocation.reader_checked_at, now, ttl_ms) ->
        {:mirror, invocation, format_markdown(invocation)}

      true ->
        follow_up(invocation, reader_url, check, now)
    end
  end

  defp follow_up(invocation, reader_url, check, now) do
    result = check.(invocation.standard_site_document_uri)

    case Store.record_reader_index(invocation, result, now) do
      {:ok, updated} ->
        if result == :indexed do
          {:redirect, reader_url}
        else
          {:mirror, updated, format_markdown(updated)}
        end

      {:error, _changeset} ->
        {:mirror, invocation, format_markdown(invocation)}
    end
  end

  defp fetch_binary(id_or_rkey) do
    trimmed = String.trim(id_or_rkey)

    case Integer.parse(trimmed) do
      {id, ""} when id > 0 ->
        fetch(id)

      _other ->
        Invocation
        |> where([i], i.standard_site_document_rkey == ^trimmed)
        |> invocation_query()
        |> Repo.one()
        |> publishable()
    end
  end

  defp invocation_query(id) when is_integer(id) do
    Invocation
    |> where([i], i.id == ^id)
  end

  defp invocation_query(queryable) do
    from(i in queryable)
  end

  defp publishable(%Invocation{dry_run: false, full_response: full} = invocation)
       when is_binary(full) and full != "" do
    if Document.reader_url_from_uri(invocation.standard_site_document_uri) do
      invocation
    end
  end

  defp publishable(_invocation), do: nil

  defp recently_checked?(%DateTime{} = checked_at, now, ttl_ms)
       when is_integer(ttl_ms) and ttl_ms > 0 do
    DateTime.diff(now, checked_at, :millisecond) < ttl_ms
  end

  defp recently_checked?(_checked_at, _now, _ttl_ms), do: false

  defp document_repo(%Invocation{} = invocation) do
    case Document.parse_document_uri(invocation.standard_site_document_uri) do
      {:ok, %{did: did}} -> did
      :error -> invocation.reply_repo
    end
  end

  defp stored_document_title(%Invocation{reply_validation: %{"document_title" => title}})
       when is_binary(title),
       do: title

  defp stored_document_title(_invocation), do: nil

  defp fallback_markdown(content) do
    """
    ## Summary

    #{content.selected_reply}

    ---

    #{PageCopy.asked_markdown(content)}

    # Research Analysis

    #{content.full_response}
    """
  end

  defp index_check do
    :context_bot
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:index_check, &ReaderIndex.check/1)
  end
end
