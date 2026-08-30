defmodule ContextBot.Reply.Intent do
  @moduledoc """
  Builds the exact repository, record key, and ATProto reply record frozen before publication.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Reply.PublicationPlan
  alias ContextBot.Workflow.Invocation

  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

  @type t :: %{
          required(:reply_repo) => String.t(),
          required(:reply_rkey) => String.t(),
          required(:reply_record) => map(),
          optional(:reply_part2_rkey) => String.t(),
          optional(:reply_part2_record) => map(),
          optional(:reply_part3_rkey) => String.t(),
          optional(:reply_part3_record) => map()
        }

  @spec build(Invocation.t(), term(), term(), term(), (integer() -> term()), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def build(
        %Invocation{} = invocation,
        text,
        bot_did,
        created_at,
        tid_generator,
        opts \\ []
      )
      when is_function(tid_generator, 1) do
    place(
      invocation,
      text,
      nil,
      bot_did,
      created_at,
      tid_generator,
      Keyword.get(opts, :reader_url)
    )
  end

  @doc """
  Builds an intent with a second part for split replies.

  When a remainder exists, part 2 keeps that leftover compact body. If a Standard Reader URL
  is present and remainder plus ` (full response)` still fits, part 2 carries both. If the
  pair does not fit, part 2 is the remainder and part 3 is the link-only label. Part 2
  replies to part 1. At freeze time, later parts are incomplete because earlier posts have
  not been published yet; ReplyWorker rebuilds them with the published parent URI and CID.
  """
  @spec build_with_part2(
          Invocation.t(),
          String.t(),
          String.t(),
          term(),
          term(),
          (integer() -> term()),
          keyword()
        ) :: {:ok, t()} | {:error, atom()}
  def build_with_part2(
        %Invocation{} = invocation,
        text_part1,
        text_part2,
        bot_did,
        created_at,
        tid_generator,
        opts \\ []
      )
      when is_function(tid_generator, 1) do
    place(
      invocation,
      text_part1,
      text_part2,
      bot_did,
      created_at,
      tid_generator,
      Keyword.get(opts, :reader_url)
    )
  end

  defp place(invocation, text, remainder, bot_did, created_at, tid_generator, reader_url)
       when is_binary(text) do
    parent = %{"uri" => invocation.invocation_uri, "cid" => invocation.current_cid}

    with {:ok, reply_repo} <- publication_repo(bot_did),
         {:ok, root} <- root_ref(invocation) do
      case PublicationPlan.decide(text, remainder, reader_url) do
        {:single_with_link, compact} ->
          freeze_single(compact, reader_url, parent, root, created_at, tid_generator, reply_repo)

        {:link_only_part2, compact} ->
          freeze_with_link_part2(
            compact,
            reader_url,
            parent,
            root,
            created_at,
            tid_generator,
            reply_repo
          )

        {:post_2_remainder_and_link, compact, rest} ->
          freeze_body_split(
            compact,
            rest,
            reader_url,
            parent,
            root,
            created_at,
            tid_generator,
            reply_repo
          )

        {:body_split_with_link_post3, compact, rest} ->
          freeze_body_split_with_link_post3(
            compact,
            rest,
            reader_url,
            parent,
            root,
            created_at,
            tid_generator,
            reply_repo
          )

        {:body_split, compact, rest} ->
          freeze_body_split(
            compact,
            rest,
            nil,
            parent,
            root,
            created_at,
            tid_generator,
            reply_repo
          )

        {:single, compact} ->
          freeze_single(compact, nil, parent, root, created_at, tid_generator, reply_repo)
      end
    end
  end

  defp freeze_single(text, reader_url, parent, root, created_at, tid_generator, reply_repo) do
    with {:ok, record} <- Post.build(text, reader_url, parent, root, created_at),
         {:ok, rkey} <- generate_rkey(created_at, tid_generator) do
      {:ok, %{reply_repo: reply_repo, reply_rkey: rkey, reply_record: record}}
    end
  end

  defp freeze_with_link_part2(
         text,
         reader_url,
         parent,
         root,
         created_at,
         tid_generator,
         reply_repo
       ) do
    with {:ok, record} <- Post.build(text, nil, parent, root, created_at),
         {:ok, rkey} <- generate_rkey(created_at, tid_generator),
         {:ok, part2_data, rkey2} <- prepare_link_part2(reader_url, parent, root, tid_generator) do
      {:ok,
       %{
         reply_repo: reply_repo,
         reply_rkey: rkey,
         reply_record: record,
         reply_part2_rkey: rkey2,
         reply_part2_record: part2_data
       }}
    end
  end

  defp freeze_body_split(
         text,
         remainder,
         reader_url,
         parent,
         root,
         created_at,
         tid_generator,
         reply_repo
       ) do
    with {:ok, record} <- Post.build(text, nil, parent, root, created_at),
         {:ok, rkey} <- generate_rkey(created_at, tid_generator),
         {:ok, part2_data, rkey2} <-
           prepare_remainder_part2(remainder, reader_url, parent, root, tid_generator) do
      {:ok,
       %{
         reply_repo: reply_repo,
         reply_rkey: rkey,
         reply_record: record,
         reply_part2_rkey: rkey2,
         reply_part2_record: part2_data
       }}
    end
  end

  defp freeze_body_split_with_link_post3(
         text,
         remainder,
         reader_url,
         parent,
         root,
         created_at,
         tid_generator,
         reply_repo
       ) do
    with {:ok, record} <- Post.build(text, nil, parent, root, created_at),
         {:ok, rkey} <- generate_rkey(created_at, tid_generator),
         {:ok, part2_data, rkey2} <- prepare_part2(remainder, parent, root, tid_generator, 9),
         {:ok, part3_data, rkey3} <-
           prepare_link_part(reader_url, parent, root, tid_generator, 10) do
      {:ok,
       %{
         reply_repo: reply_repo,
         reply_rkey: rkey,
         reply_record: record,
         reply_part2_rkey: rkey2,
         reply_part2_record: part2_data,
         reply_part3_rkey: rkey3,
         reply_part3_record: part3_data
       }}
    end
  end

  defp prepare_remainder_part2(remainder, reader_url, parent, root, tid_generator)
       when is_binary(reader_url) do
    with {:ok, part2_data, rkey} <- prepare_part2(remainder, parent, root, tid_generator, 9) do
      {:ok, Map.put(part2_data, "readerUrl", reader_url), rkey}
    end
  end

  defp prepare_remainder_part2(remainder, _reader_url, parent, root, tid_generator) do
    prepare_part2(remainder, parent, root, tid_generator, 9)
  end

  defp prepare_link_part2(reader_url, parent, root, tid_generator) do
    prepare_link_part(reader_url, parent, root, tid_generator, 9)
  end

  defp prepare_link_part(reader_url, parent, root, tid_generator, placeholder_timestamp_us) do
    with {:ok, part_data, rkey} <-
           prepare_part2(Post.link_label(), parent, root, tid_generator, placeholder_timestamp_us) do
      {:ok, Map.put(part_data, "readerUrl", reader_url), rkey}
    end
  end

  defp prepare_part2(text_part, parent, root, tid_generator, placeholder_timestamp_us)
       when is_binary(text_part) do
    # Generate a placeholder TID at freeze time. This will be replaced at publish time.
    # Use a sentinel timestamp to mark this as needing regeneration.
    placeholder_created_at = DateTime.from_unix!(placeholder_timestamp_us, :microsecond)

    # Later parts share part1's root. When root is nil, part1 uses parent as root.
    part_root = root || parent

    with {:ok, part_rkey} <- generate_rkey(placeholder_created_at, tid_generator) do
      part_data = %{
        "text" => text_part,
        "createdAt" => DateTime.to_iso8601(placeholder_created_at),
        "reply" => %{"root" => part_root}
      }

      {:ok, part_data, part_rkey}
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
