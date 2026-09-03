defmodule ContextBotWeb.ResponseEnvelopesController do
  @moduledoc """
  Public GET-only JSON for `anthropic_response_envelopes`.
  """

  use ContextBotWeb, :controller

  alias ContextBotWeb.PublicData

  def index(conn, _params) do
    json(conn, %{anthropic_response_envelopes: PublicData.list_response_envelopes()})
  end

  def show(conn, %{"id" => id}) do
    case PublicData.get_response_envelope(id) do
      nil -> not_found(conn)
      envelope -> json(conn, envelope)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end
end
