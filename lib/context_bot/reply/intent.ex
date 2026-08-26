defmodule ContextBot.Reply.Intent do
  @moduledoc """
  Builds the exact repository, record key, and ATProto reply record frozen before publication.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Workflow.Invocation

  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

  @type t :: %{
          required(:reply_repo) => String.t(),
          required(:reply_rkey) => String.t(),
          required(:reply_record) => map(),
          optional(:reply_part2_rkey) => String.t(),
          optional(:reply_part2_record) => map()
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

  @doc """
  Builds an intent with a second part for split replies.

  Part 2 will reply to part 1 (not to the invocation). At freeze time, part2's record
  contains only text and createdAt because part1 has not been published yet. ReplyWorker
  rebuilds the full part2 record with part1's published URI and CID before publishing.
  """
  @spec build_with_part2(
          Invocation.t(),
          String.t(),
          String.t(),
          term(),
          term(),
          (integer() -> term())
        ) :: {:ok, t()} | {:error, atom()}
  def build_with_part2(
        %Invocation{} = invocation,
        text_part1,
        text_part2,
        bot_did,
        created_at,
        tid_generator
      )
      when is_function(tid_generator, 1) do
    parent = %{"uri" => invocation.invocation_uri, "cid" => invocation.current_cid}

    with {:ok, reply_repo} <- publication_repo(bot_did),
         {:ok, root} <- root_ref(invocation),
         {:ok, record1} <- Post.build(text_part1, parent, root, created_at),
         {:ok, rkey1} <- generate_rkey(created_at, tid_generator),
         {:ok, part2_data, rkey2} <- prepare_part2(text_part2, tid_generator) do
      {:ok,
       %{
         reply_repo: reply_repo,
         reply_rkey: rkey1,
         reply_record: record1,
         reply_part2_rkey: rkey2,
         reply_part2_record: part2_data
       }}
    end
  end

  defp prepare_part2(text_part2, tid_generator) when is_binary(text_part2) do
    part2_created_at = DateTime.utc_now()

    with {:ok, part2_rkey} <- generate_rkey(part2_created_at, tid_generator) do
      part2_data = %{
        "text" => text_part2,
        "createdAt" => DateTime.to_iso8601(part2_created_at)
      }

      {:ok, part2_data, part2_rkey}
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
