defmodule ContextBotWeb.BudgetEntriesController do
  @moduledoc """
  Public GET-only JSON for `api_budget_entries`.
  """

  use ContextBotWeb, :controller

  alias ContextBotWeb.PublicData

  def index(conn, _params) do
    json(conn, %{api_budget_entries: PublicData.list_budget_entries()})
  end

  def show(conn, %{"id" => id}) do
    case PublicData.get_budget_entry(id) do
      nil -> not_found(conn)
      entry -> json(conn, entry)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end
end
