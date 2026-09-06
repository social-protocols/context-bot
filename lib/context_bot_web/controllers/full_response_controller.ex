defmodule ContextBotWeb.FullResponseController do
  @moduledoc """
  Legacy `GET /r/:id` redirect for already-published Bluesky links.

  New posts link to Standard Reader directly. This route only 302s to
  `Document.reader_url_from_uri/1` when the invocation has a stored
  `standard_site_document_uri`. It does not serve writeups from sqlite.
  """

  use ContextBotWeb, :controller

  alias ContextBot.Repo
  alias ContextBot.StandardSite.Document
  alias ContextBot.Workflow.Invocation

  def show(conn, %{"id" => id}) do
    case reader_url(id) do
      {:ok, url} ->
        redirect(conn, external: url)

      :error ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(404, not_found_html())
    end
  end

  defp reader_url(id) do
    case fetch(id) do
      %Invocation{} = invocation ->
        case Document.reader_url_from_uri(invocation.standard_site_document_uri) do
          url when is_binary(url) -> {:ok, url}
          _missing -> :error
        end

      nil ->
        :error
    end
  end

  defp fetch(id) when is_binary(id) do
    trimmed = String.trim(id)

    case Integer.parse(trimmed) do
      {int, ""} when int > 0 ->
        Repo.get(Invocation, int)

      _other ->
        Repo.get_by(Invocation, standard_site_document_rkey: trimmed)
    end
  end

  defp fetch(_id), do: nil

  defp not_found_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Not found</title>
    </head>
    <body>
      <p>No published full response at this URL.</p>
      <p><a href="/">Context Bot</a></p>
    </body>
    </html>
    """
  end
end
