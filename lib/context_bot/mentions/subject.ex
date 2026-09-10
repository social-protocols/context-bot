defmodule ContextBot.Mentions.Subject do
  @moduledoc """
  Reads reply parent and thread-root coordinates from an invocation receipt.

  Admission uses these to skip actor windows for bot follow-ups and to count
  research admissions per thread root. Prefer a persisted `root_uri` when the
  thread has already been captured.
  """

  alias ContextBot.ATProto.ATURI
  alias ContextBot.Workflow.Invocation

  @spec parent_uri(Invocation.t()) :: String.t() | nil
  def parent_uri(%Invocation{raw_notification: notification}),
    do: reply_ref_uri(notification, :parent)

  @spec parent_by_bot?(Invocation.t(), String.t() | nil) :: boolean()
  def parent_by_bot?(%Invocation{} = invocation, bot_did)
      when is_binary(bot_did) and bot_did != "" do
    case parent_uri(invocation) do
      uri when is_binary(uri) ->
        case ATURI.parse(uri) do
          {:ok, %{repo: ^bot_did}} -> true
          _other -> false
        end

      _missing ->
        false
    end
  end

  def parent_by_bot?(_invocation, _bot_did), do: false

  @spec thread_root_uri(Invocation.t()) :: String.t()
  def thread_root_uri(%Invocation{root_uri: root_uri})
      when is_binary(root_uri) and root_uri != "",
      do: root_uri

  def thread_root_uri(%Invocation{} = invocation) do
    reply_ref_uri(invocation.raw_notification, :root) || invocation.invocation_uri
  end

  defp reply_ref_uri(notification, ref) when is_map(notification) do
    notification
    |> field("record")
    |> field("reply")
    |> field(ref_key(ref))
    |> uri_field()
  end

  defp reply_ref_uri(_notification, _ref), do: nil

  defp ref_key(:parent), do: "parent"
  defp ref_key(:root), do: "root"

  defp field(map, "record") when is_map(map), do: Map.get(map, "record") || Map.get(map, :record)
  defp field(map, "reply") when is_map(map), do: Map.get(map, "reply") || Map.get(map, :reply)
  defp field(map, "parent") when is_map(map), do: Map.get(map, "parent") || Map.get(map, :parent)
  defp field(map, "root") when is_map(map), do: Map.get(map, "root") || Map.get(map, :root)

  defp field(_map, _key), do: nil

  defp uri_field(ref) when is_map(ref) do
    case Map.get(ref, "uri") || Map.get(ref, :uri) do
      uri when is_binary(uri) and uri != "" -> uri
      _missing -> nil
    end
  end

  defp uri_field(_ref), do: nil
end
