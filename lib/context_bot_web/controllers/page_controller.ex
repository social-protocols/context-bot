defmodule ContextBotWeb.PageController do
  use ContextBotWeb, :controller

  @homepage_md File.read!("priv/static/homepage.md")
  @external_resource "priv/static/homepage.md"

  def home(conn, _params) do
    html_content = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Context Bot</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          line-height: 1.6;
          color: #1a1a1a;
          background: #ffffff;
          padding: 2rem 1rem;
          max-width: 42rem;
          margin: 0 auto;
        }
        h1 {
          font-size: 2.5rem;
          font-weight: 700;
          margin-bottom: 1rem;
          color: #000000;
        }
        h2 {
          font-size: 1.5rem;
          font-weight: 600;
          margin-top: 2rem;
          margin-bottom: 0.75rem;
          color: #000000;
        }
        p {
          margin-bottom: 1rem;
        }
        ul {
          margin-left: 1.5rem;
          margin-bottom: 1rem;
        }
        li {
          margin-bottom: 0.5rem;
        }
        strong {
          font-weight: 600;
          color: #000000;
        }
        a {
          color: #0066cc;
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
        hr {
          border: none;
          border-top: 1px solid #e0e0e0;
          margin: 2rem 0;
        }
        @media (max-width: 640px) {
          body { padding: 1rem 0.75rem; }
          h1 { font-size: 2rem; }
          h2 { font-size: 1.25rem; }
        }
      </style>
    </head>
    <body>
    #{markdown_to_html(@homepage_md)}
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html_content)
  end

  defp markdown_to_html(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_list} ->
      cond do
        String.starts_with?(line, "# ") ->
          html = "<h1>#{escape_html(String.slice(line, 2..-1//1))}</h1>"
          {acc ++ [close_list_if_needed(in_list), html], false}

        String.starts_with?(line, "## ") ->
          html = "<h2>#{escape_html(String.slice(line, 3..-1//1))}</h2>"
          {acc ++ [close_list_if_needed(in_list), html], false}

        String.starts_with?(line, "- ") ->
          item_html = process_inline_formatting(String.slice(line, 2..-1//1))
          html = if in_list, do: "<li>#{item_html}</li>", else: "<ul><li>#{item_html}</li>"
          {acc ++ [html], true}

        String.starts_with?(line, "---") ->
          {acc ++ [close_list_if_needed(in_list), "<hr>"], false}

        String.trim(line) == "" ->
          {acc ++ [close_list_if_needed(in_list)], false}

        true ->
          html = "<p>#{process_inline_formatting(line)}</p>"
          {acc ++ [close_list_if_needed(in_list), html], false}
      end
    end)
    |> then(fn {acc, in_list} -> acc ++ [close_list_if_needed(in_list)] end)
    |> Enum.join("\n")
  end

  defp close_list_if_needed(true), do: "</ul>"
  defp close_list_if_needed(false), do: ""

  defp process_inline_formatting(text) do
    text
    |> String.replace(~r/\*\*(.*?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\[(.*?)\]\((.*?)\)/, "<a href=\"\\2\">\\1</a>")
    |> escape_html_except_tags()
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html_except_tags(text) do
    # Already has <strong> and <a> tags from process_inline_formatting
    # Split on tags, escape the text parts, reassemble
    parts = Regex.split(~r/(<\/?(?:strong|a)[^>]*>)/, text, include_captures: true)

    Enum.map_join(parts, fn part ->
      if String.starts_with?(part, "<") and String.ends_with?(part, ">") do
        part
      else
        escape_html(part)
      end
    end)
  end
end
