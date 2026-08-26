defmodule ContextBot.ATProto.Client do
  @moduledoc """
  Boundary for the ATProto reads and repository writes used by the bot workflow.

  Implementations return decoded response bodies with HTTP metadata on success and stable,
  secret-free error categories on failure.
  """

  @type t :: module()
  @type headers :: %{optional(String.t()) => [String.t()]}
  @type success :: {:ok, non_neg_integer(), headers(), term()}

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

  @type result :: success() | {:error, error_reason()}

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
end
