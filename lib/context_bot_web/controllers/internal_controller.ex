defmodule ContextBotWeb.InternalController do
  @moduledoc """
  Internal operator dashboard controller.
  """

  use ContextBotWeb, :controller

  import Ecto.Query
  alias ContextBot.Repo
  alias ContextBot.Workflow.Invocation

  def index(conn, _params) do
    invocations =
      Invocation
      |> order_by([i], desc: i.id)
      |> select([i], %{
        id: i.id,
        status: i.status,
        stage: i.stage,
        actor_handle: i.actor_handle,
        dry_run: i.dry_run,
        invocation_uri: i.invocation_uri,
        reply_uri: i.reply_uri,
        reply_part2_uri: i.reply_part2_uri,
        anthropic_attempt_sequence: i.anthropic_attempt_sequence,
        failure_category: i.failure_category,
        failure_detail: i.failure_detail,
        inserted_at: i.inserted_at,
        completed_at: i.completed_at
      })
      |> Repo.all()

    html_content = render_dashboard(invocations)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html_content)
  end

  defp render_dashboard(invocations) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Context Bot - Internal Dashboard</title>
      <style>
        body {
          font-family: system-ui, -apple-system, sans-serif;
          margin: 20px;
          background: #f5f5f5;
        }
        h1 {
          color: #333;
        }
        table {
          width: 100%;
          border-collapse: collapse;
          background: white;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        th, td {
          padding: 8px 12px;
          text-align: left;
          border-bottom: 1px solid #ddd;
          font-size: 13px;
        }
        th {
          background: #f8f9fa;
          font-weight: 600;
          position: sticky;
          top: 0;
        }
        tr:hover {
          background: #f8f9fa;
        }
        a {
          color: #0066cc;
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
        .status-complete { color: #0a0; }
        .status-failed { color: #c00; }
        .status-researching { color: #06c; }
        .error-cell {
          max-width: 300px;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .dry-run { color: #666; font-style: italic; }
      </style>
    </head>
    <body>
      <h1>Context Bot Invocations</h1>
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Status</th>
            <th>Stage</th>
            <th>Actor</th>
            <th>Dry Run</th>
            <th>Attempts</th>
            <th>Error</th>
            <th>Invocation</th>
            <th>Reply</th>
            <th>Inserted</th>
            <th>Completed</th>
          </tr>
        </thead>
        <tbody>
    #{Enum.map_join(invocations, "\n", &render_row/1)}
        </tbody>
      </table>
    </body>
    </html>
    """
  end

  defp render_row(inv) do
    """
          <tr>
            <td>#{inv.id}</td>
            <td class="status-#{inv.status}">#{inv.status}</td>
            <td>#{inv.stage}</td>
            <td>#{escape_html(inv.actor_handle || "")}</td>
            <td>#{if inv.dry_run, do: "yes", else: ""}</td>
            <td>#{inv.anthropic_attempt_sequence}</td>
            <td class="error-cell" title="#{escape_html(full_error_detail(inv.failure_detail))}">
              #{escape_html(error_summary(inv.failure_detail, inv.failure_category))}
            </td>
            <td>
              #{invocation_link(inv.invocation_uri)}
            </td>
            <td>
              #{reply_link(inv.reply_uri, "1")}
              #{reply_link(inv.reply_part2_uri, "2")}
            </td>
            <td>#{format_datetime(inv.inserted_at)}</td>
            <td>#{format_datetime(inv.completed_at)}</td>
          </tr>
    """
  end

  defp bluesky_post_url(uri) do
    case parse_at_uri(uri) do
      {:ok, did, rkey} -> "https://bsky.app/profile/#{did}/post/#{rkey}"
      :error -> nil
    end
  end

  defp parse_at_uri("at://" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [did, "app.bsky.feed.post", rkey] -> {:ok, did, rkey}
      _ -> :error
    end
  end

  defp parse_at_uri(_), do: :error

  defp invocation_link(nil), do: ""

  defp invocation_link(uri) do
    case bluesky_post_url(uri) do
      nil -> ""
      url -> ~s(<a href="#{url}" target="_blank">view</a>)
    end
  end

  defp reply_link(nil, _label), do: ""

  defp reply_link(uri, label) do
    case bluesky_post_url(uri) do
      nil -> ""
      url -> ~s(<a href="#{url}" target="_blank">#{label}</a>)
    end
  end

  defp error_summary(nil, _category), do: ""

  defp error_summary(detail, category) when is_map(detail) do
    reason = Map.get(detail, "reason") || Map.get(detail, :reason) || ""

    message =
      case category do
        nil -> reason
        cat -> "#{cat}: #{reason}"
      end

    truncate(message, 100)
  end

  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length) <> "..."
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp full_error_detail(nil), do: ""

  defp full_error_detail(detail) when is_map(detail) do
    Jason.encode!(detail)
  end

  defp full_error_detail(detail), do: to_string(detail)

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(_), do: ""
end
