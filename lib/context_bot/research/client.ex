defmodule ContextBot.Research.Client do
  @moduledoc """
  Transport boundary for a raw Anthropic Messages response.
  """

  @type response_envelope :: %{
          status: pos_integer(),
          headers: %{optional(String.t()) => [String.t()]},
          raw_body: binary(),
          received_at: DateTime.t(),
          duration_ms: non_neg_integer()
        }

  @callback send_message(request_map :: map(), attempt_metadata :: map()) ::
              {:ok, response_envelope()}
              | {:error, :response_too_large | :timeout | :transport}
end
