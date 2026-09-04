defmodule ContextBotWeb.InvocationsController do
  @moduledoc """
  Public GET-only invocations dashboard.
  """

  use ContextBotWeb, :controller

  import Ecto.Query
  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.StandardSite.Document
  alias ContextBot.Workflow.Invocation
  alias ContextBotWeb.PublicData

  defmacrop billed_microdollars_sum(entry) do
    quote do
      fragment(
        "COALESCE(SUM(CASE WHEN ? = 'settled' THEN COALESCE(?, ?) ELSE ? END), 0)",
        unquote(entry).state,
        unquote(entry).settled_microdollars,
        unquote(entry).reserved_microdollars,
        unquote(entry).reserved_microdollars
      )
    end
  end

  def index(conn, _params) do
    now = DateTime.utc_now()

    stats = %{
      day: calculate_period_stats(now, days: -1),
      week: calculate_period_stats(now, days: -7),
      month: calculate_period_stats(now, days: -30)
    }

    spend_by_invocation = invocation_spend_microdollars()

    invocations =
      Invocation
      |> order_by([i], desc: i.id)
      |> select([i], %{
        id: i.id,
        status: i.status,
        stage: i.stage,
        actor_handle: i.actor_handle,
        invocation_uri: i.invocation_uri,
        reply_uri: i.reply_uri,
        reply_part2_uri: i.reply_part2_uri,
        reply_part3_uri: i.reply_part3_uri,
        standard_site_document_uri: i.standard_site_document_uri,
        anthropic_attempt_sequence: i.anthropic_attempt_sequence,
        failure_category: i.failure_category,
        failure_detail: i.failure_detail,
        no_reply: i.no_reply,
        inserted_at: i.inserted_at,
        completed_at: i.completed_at
      })
      |> Repo.all()
      |> Enum.map(fn inv ->
        Map.put(inv, :cost_microdollars, Map.get(spend_by_invocation, inv.id, 0))
      end)

    html_content = render_dashboard(stats, invocations, now)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html_content)
  end

  def index_json(conn, _params) do
    json(conn, %{invocations: PublicData.list_invocations()})
  end

  def show(conn, %{"id" => id}) do
    case PublicData.invocation_document(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      document ->
        json(conn, document)
    end
  end

  defp calculate_period_stats(now, days: days_ago) do
    cutoff = DateTime.add(now, days_ago, :day)

    invocation_count =
      Invocation
      |> where([i], i.inserted_at >= ^cutoff)
      |> select([i], count(i.id))
      |> Repo.one()

    error_count =
      Invocation
      |> where(
        [i],
        i.inserted_at >= ^cutoff and
          (i.status == :failed or not is_nil(i.failure_category))
      )
      |> select([i], count(i.id))
      |> Repo.one()

    budget_stats =
      BudgetEntry
      |> where([e], e.inserted_at >= ^cutoff)
      |> select([e], %{
        total_microdollars: billed_microdollars_sum(e),
        total_input_tokens:
          fragment(
            "COALESCE(SUM(CAST(json_extract(?, '$.input_tokens') AS INTEGER)), 0)",
            e.usage
          ),
        total_output_tokens:
          fragment(
            "COALESCE(SUM(CAST(json_extract(?, '$.output_tokens') AS INTEGER)), 0)",
            e.usage
          )
      })
      |> Repo.one()

    %{
      invocation_count: invocation_count,
      error_count: error_count,
      total_microdollars: budget_stats.total_microdollars,
      total_input_tokens: budget_stats.total_input_tokens,
      total_output_tokens: budget_stats.total_output_tokens
    }
  end

  defp invocation_spend_microdollars do
    BudgetEntry
    |> group_by([e], e.invocation_id)
    |> select([e], {e.invocation_id, billed_microdollars_sum(e)})
    |> Repo.all()
    |> Map.new()
  end

  defp render_dashboard(stats, invocations, now) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Context Bot Invocations</title>
      <style>
        body {
          font-family: system-ui, -apple-system, sans-serif;
          margin: 20px;
          background: #f5f5f5;
        }
        h1 {
          color: #333;
          margin-bottom: 20px;
        }
        .summary {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 15px;
          margin-bottom: 20px;
        }
        .summary-card {
          background: white;
          padding: 15px;
          border-radius: 4px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .summary-card h2 {
          font-size: 14px;
          font-weight: 600;
          color: #666;
          margin: 0 0 10px 0;
          text-transform: uppercase;
          letter-spacing: 0.5px;
        }
        .summary-stats {
          display: flex;
          flex-direction: column;
          gap: 8px;
        }
        .summary-stat {
          display: flex;
          justify-content: space-between;
          font-size: 13px;
        }
        .summary-stat-label {
          color: #666;
        }
        .summary-stat-value {
          font-weight: 600;
          color: #333;
        }
        .stat-error {
          color: #c00;
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
        .no-reply { color: #666; }
      </style>
    </head>
    <body>
      <h1>Context Bot Invocations</h1>
      <p><a href="/">Rate and funding limits</a></p>
      #{render_summary(stats)}
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Status</th>
            <th>Stage</th>
            <th>Actor</th>
            <th>Cost</th>
            <th>Calls</th>
            <th>Error</th>
            <th>Invocation</th>
            <th>Reply</th>
            <th>Full Response</th>
            <th>Inserted</th>
            <th>Completed</th>
          </tr>
        </thead>
        <tbody>
    #{Enum.map_join(invocations, "\n", &render_row(&1, now))}
        </tbody>
      </table>
    </body>
    </html>
    """
  end

  defp render_row(inv, now) do
    error = escape_html(error_summary(inv.failure_detail, inv.failure_category))

    """
          <tr>
            <td><a href="/invocations/#{inv.id}.json">#{inv.id}</a></td>
            <td class="status-#{inv.status}">#{inv.status}</td>
            <td>#{inv.stage}</td>
            <td>#{escape_html(inv.actor_handle || "")}</td>
            <td>#{format_dollars(inv.cost_microdollars)}</td>
            <td>#{inv.anthropic_attempt_sequence}</td>
            <td class="error-cell" title="#{error}">
              #{error}
            </td>
            <td>
              #{invocation_link(inv.invocation_uri)}
            </td>
            <td>
              #{reply_cell(inv)}
            </td>
            <td>
              #{full_response_link(inv.standard_site_document_uri)}
            </td>
            <td>#{format_relative_datetime(inv.inserted_at, now)}</td>
            <td>#{format_relative_datetime(inv.completed_at, now)}</td>
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

  defp reply_cell(%{no_reply: true}), do: ~s(<span class="no-reply">no reply</span>)

  defp reply_cell(inv) do
    """
              #{reply_link(inv.reply_uri, "1")}
              #{reply_link(inv.reply_part2_uri, "2")}
              #{reply_link(inv.reply_part3_uri, "3")}
    """
  end

  defp reply_link(nil, _label), do: ""

  defp reply_link(uri, label) do
    case bluesky_post_url(uri) do
      nil -> ""
      url -> ~s(<a href="#{url}" target="_blank">#{label}</a>)
    end
  end

  defp full_response_link(uri) do
    case Document.reader_url_from_uri(uri) do
      nil -> "&mdash;"
      url -> ~s(<a href="#{url}" target="_blank">full response</a>)
    end
  end

  defp error_summary(nil, _category), do: ""

  defp error_summary(detail, category) when is_map(detail) do
    reason = Map.get(detail, "reason") || Map.get(detail, :reason) || ""
    category_text = category_text(category)

    message =
      cond do
        category_text == "" -> reason
        reason == "" -> category_text
        reason == category_text -> reason
        true -> "#{category_text}: #{reason}"
      end

    truncate(message, 100)
  end

  defp category_text(nil), do: ""
  defp category_text(category), do: to_string(category)

  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length) <> "..."
  end

  defp format_relative_datetime(nil, _now), do: "&mdash;"

  defp format_relative_datetime(%DateTime{} = dt, now) do
    absolute = Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
    relative = relative_time(dt, now)
    ~s(<span title="#{escape_html(absolute)}">#{escape_html(relative)}</span>)
  end

  defp relative_time(%DateTime{} = dt, now) do
    seconds = max(DateTime.diff(now, dt, :second), 0)
    relative_from_seconds(seconds)
  end

  defp relative_from_seconds(seconds) when seconds < 36 * 60 * 60 do
    relative_hours(seconds)
  end

  defp relative_from_seconds(seconds), do: relative_days(seconds)

  defp relative_hours(seconds) when seconds < 45, do: "just now"
  defp relative_hours(seconds) when seconds < 90, do: ago(1, "minute")
  defp relative_hours(seconds) when seconds < 45 * 60, do: ago(div(seconds, 60), "minute")
  defp relative_hours(seconds) when seconds < 90 * 60, do: ago(1, "hour")
  defp relative_hours(seconds) when seconds < 22 * 60 * 60, do: ago(div(seconds, 60 * 60), "hour")
  defp relative_hours(_seconds), do: "yesterday"

  defp relative_days(seconds) when seconds < 26 * 24 * 60 * 60 do
    ago(div(seconds, 24 * 60 * 60), "day")
  end

  defp relative_days(seconds) when seconds < 45 * 24 * 60 * 60, do: ago(1, "month")

  defp relative_days(seconds) when seconds < 320 * 24 * 60 * 60 do
    ago(div(seconds, 30 * 24 * 60 * 60), "month")
  end

  defp relative_days(seconds) when seconds < 548 * 24 * 60 * 60, do: ago(1, "year")
  defp relative_days(seconds), do: ago(div(seconds, 365 * 24 * 60 * 60), "year")

  defp ago(1, unit), do: "1 #{unit} ago"
  defp ago(count, unit), do: "#{count} #{unit}s ago"

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(_), do: ""

  defp render_summary(stats) do
    """
    <div class="summary">
      #{render_period_card("Last 24 Hours", stats.day)}
      #{render_period_card("Last 7 Days", stats.week)}
      #{render_period_card("Last 30 Days", stats.month)}
    </div>
    """
  end

  defp render_period_card(title, period_stats) do
    dollars = format_dollars(period_stats.total_microdollars)
    total_tokens = period_stats.total_input_tokens + period_stats.total_output_tokens
    tokens_formatted = format_number(total_tokens)

    """
    <div class="summary-card">
      <h2>#{title}</h2>
      <div class="summary-stats">
        <div class="summary-stat">
          <span class="summary-stat-label">Invocations</span>
          <span class="summary-stat-value">#{period_stats.invocation_count}</span>
        </div>
        <div class="summary-stat">
          <span class="summary-stat-label">API Cost</span>
          <span class="summary-stat-value">#{dollars}</span>
        </div>
        <div class="summary-stat">
          <span class="summary-stat-label">Tokens</span>
          <span class="summary-stat-value">#{tokens_formatted}</span>
        </div>
        <div class="summary-stat">
          <span class="summary-stat-label">Errors</span>
          <span class="summary-stat-value stat-error">#{period_stats.error_count}</span>
        </div>
      </div>
    </div>
    """
  end

  defp format_dollars(microdollars) when is_integer(microdollars) do
    dollars = microdollars / 1_000_000
    "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  defp format_number(num) when is_integer(num) and num >= 1_000_000 do
    rounded = Float.round(num / 1_000_000, 1)
    "#{:erlang.float_to_binary(rounded, decimals: 1)}M"
  end

  defp format_number(num) when is_integer(num) and num >= 1_000 do
    rounded = Float.round(num / 1_000, 1)
    "#{:erlang.float_to_binary(rounded, decimals: 1)}K"
  end

  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
end
