defmodule ContextBot.Reply.Intent do
  @moduledoc """
  Builds the exact repository, record key, and ATProto reply record frozen before publication.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Workflow.Invocation

  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

  @type t :: %{
          reply_repo: String.t(),
          reply_rkey: String.t(),
          reply_record: map()
        }

  @spec build(Invocation.t(), term(), term(), term(), (integer() -> term())) ::
          {:ok, t()} | {:error, atom()}
  def build(%Invocation{} = invocation, text, bot_did, created_at, tid_generator)
      when is_function(tid_generator, 1) do
    parent = %{"uri" => invocation.invocation_uri, "cid" => invocation.current_cid}

    with {:ok, reply_repo} <- publication_repo(bot_did),
         {:ok, root} <- root_ref(invocation),
         {:ok, record} <- Post.build(text, parent, root, created_at),
         {:ok, rkey} <- generate_rkey(created_at, tid_generator) do
      {:ok,
       %{
         reply_repo: reply_repo,
         reply_rkey: rkey,
         reply_record: record
       }}
    end
  end

  defp publication_repo(repo) when is_binary(repo) and repo != "" do
    if Regex.match?(@did_regex, repo), do: {:ok, repo}, else: {:error, :invalid_publication_repo}
  end

  defp publication_repo(_repo), do: {:error, :invalid_publication_repo}

  defp root_ref(%Invocation{root_uri: nil, root_cid: nil}), do: {:ok, nil}

  defp root_ref(%Invocation{root_uri: root_uri, root_cid: root_cid})
       when is_binary(root_uri) and is_binary(root_cid),
       do: {:ok, %{"uri" => root_uri, "cid" => root_cid}}

  defp root_ref(_invocation), do: {:error, :invalid_root}

  defp generate_rkey(%DateTime{} = created_at, tid_generator) do
    case tid_generator.(DateTime.to_unix(created_at, :microsecond)) do
      rkey when is_binary(rkey) and rkey != "" -> {:ok, rkey}
      _invalid_rkey -> {:error, :invalid_reply_rkey}
    end
  end
end
