defmodule ContextBot.Workflow.Failure do
  @moduledoc """
  Converts failure classifications to the finite, credential-safe set stored in SQLite.
  """

  @categories [
    :invalid_input,
    :identity_unavailable,
    :rate_limited,
    :thread_unavailable,
    :provider_auth,
    :provider_budget,
    :provider_response,
    :publication_auth,
    :publication_conflict
  ]

  @type category ::
          :invalid_input
          | :identity_unavailable
          | :rate_limited
          | :thread_unavailable
          | :provider_auth
          | :provider_budget
          | :provider_response
          | :publication_auth
          | :publication_conflict

  @spec category(term()) :: category()
  def category(value) when value in @categories, do: value
  def category(_value), do: :invalid_input
end
