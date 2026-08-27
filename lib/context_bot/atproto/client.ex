defmodule ContextBot.ATProto.Client do
  @moduledoc """
  Boundary for the ATProto reads and repository writes used by the bot workflow.

  Implementations return decoded response bodies with HTTP metadata on success and stable,
  secret-free error categories on failure.
  """

  @type t :: module()
  @type headers :: %{optional(String.t()) => [String.t()]}
  @type success :: {:ok, non_neg_integer(), headers(), term()}

  @type error_detail :: %{optional(String.t()) => String.t()}

  @type error_reason ::
          :unauthorized
          | :record_not_found
          | :invalid_swap
          | :timeout
          | :response_too_large
          | :session_unavailable
          | {:rate_limited, String.t() | nil}
          | {:transient, non_neg_integer() | :transport}
          | {:permanent, non_neg_integer()}
          | {:permanent, non_neg_integer(), error_detail()}

  @type error_fields :: %{
          optional(:failure_reason) => String.t(),
          optional(:status_code) => non_neg_integer(),
          optional(:atproto_error) => String.t(),
          optional(:message) => String.t()
        }

  @type result :: success() | {:error, error_reason()}

  @atproto_error_name ~r/\A[A-Za-z][A-Za-z0-9]{0,63}\z/
  @atproto_error_message ~r/\A[A-Za-z0-9][A-Za-z0-9 .,:;\/_-]{0,159}\z/

  @callback list_notifications(cursor :: String.t() | nil) :: result()
  @callback get_post_thread(uri :: String.t(), parent_height :: pos_integer()) :: result()
  @callback get_profile(actor :: String.t(), labeler_did :: String.t()) :: result()
  @callback resolve_handle(handle :: String.t()) :: result()
  @callback resolve_did(did :: String.t()) :: result()

  @callback get_record(repo :: String.t(), collection :: String.t(), rkey :: String.t()) ::
              result()

  @callback put_record(
              repo :: String.t(),
              collection :: String.t(),
              rkey :: String.t(),
              record :: map()
            ) :: result()

  @callback delete_record(
              repo :: String.t(),
              collection :: String.t(),
              rkey :: String.t()
            ) :: result()

  @doc """
  Extracts credential-free ATProto error fields for logs and invocation detail.
  """
  @spec error_fields(term()) :: error_fields()
  def error_fields({:permanent, status, detail})
      when is_integer(status) and status >= 0 and is_map(detail) do
    %{failure_reason: "permanent", status_code: status}
    |> put_atproto_error(detail)
    |> put_atproto_message(detail)
  end

  def error_fields({:permanent, status}) when is_integer(status) and status >= 0 do
    %{failure_reason: "permanent", status_code: status}
  end

  def error_fields({:transient, :transport}), do: %{failure_reason: "transient"}

  def error_fields({:transient, status}) when is_integer(status) and status >= 0 do
    %{failure_reason: "transient", status_code: status}
  end

  def error_fields({:rate_limited, _retry_after}),
    do: %{failure_reason: "rate_limited", status_code: 429}

  def error_fields(reason) when is_atom(reason), do: %{failure_reason: Atom.to_string(reason)}
  def error_fields(_reason), do: %{failure_reason: "provider_failure"}

  @doc "HTTP status for a permanent ATProto error, with or without a detail map."
  @spec permanent_status(term()) :: non_neg_integer() | nil
  def permanent_status({:permanent, status}) when is_integer(status) and status >= 0, do: status

  def permanent_status({:permanent, status, detail})
      when is_integer(status) and status >= 0 and is_map(detail),
      do: status

  def permanent_status(_reason), do: nil

  defp put_atproto_error(fields, detail) do
    case string_field(detail, "error") do
      error when is_binary(error) and byte_size(error) > 0 ->
        if Regex.match?(@atproto_error_name, error),
          do: Map.put(fields, :atproto_error, error),
          else: fields

      _missing ->
        fields
    end
  end

  defp put_atproto_message(fields, detail) do
    case string_field(detail, "message") do
      message when is_binary(message) and byte_size(message) > 0 ->
        if Regex.match?(@atproto_error_message, message),
          do: Map.put(fields, :message, message),
          else: fields

      _missing ->
        fields
    end
  end

  defp string_field(detail, "error") do
    case Map.get(detail, "error") || Map.get(detail, :error) do
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp string_field(detail, "message") do
    case Map.get(detail, "message") || Map.get(detail, :message) do
      value when is_binary(value) -> value
      _missing -> nil
    end
  end
end
