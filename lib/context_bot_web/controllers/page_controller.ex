defmodule ContextBotWeb.PageController do
  use ContextBotWeb, :controller

  @homepage_md File.read!("priv/static/homepage.md")
  @external_resource "priv/static/homepage.md"
  @public_url "https://getcontext.bot/"
  @og_image_url "https://getcontext.bot/images/og.png"
  @og_description "Mention @getcontext.bot on a Bluesky post and ask it a question. It does the research and produces a brief response."

  def home(conn, _params) do
    html_content = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Context Bot</title>
      <meta name="description" content="#{@og_description}">
      <link rel="canonical" href="#{@public_url}">
      <meta property="og:title" content="Context Bot">
      <meta property="og:description" content="#{@og_description}">
      <meta property="og:image" content="#{@og_image_url}">
      <meta property="og:url" content="#{@public_url}">
      <meta property="og:type" content="website">
      <meta property="og:site_name" content="Context Bot">
      <meta name="twitter:card" content="summary_large_image">
      <meta name="twitter:title" content="Context Bot">
      <meta name="twitter:description" content="#{@og_description}">
      <meta name="twitter:image" content="#{@og_image_url}">
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
        blockquote {
          border-left: 3px solid #d0d0d0;
          padding: 0.25rem 0 0.25rem 1rem;
          margin: 0.75rem 0 1.25rem;
          color: #333333;
        }
        blockquote p {
          margin-bottom: 0;
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
    |> Enum.reduce({[], false}, &process_line/2)
    |> finalize_html()
  end

  defp process_line(line, {acc, in_list}) do
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

      String.starts_with?(line, ">") ->
        quote_text = line |> String.replace_prefix(">", "") |> String.trim_leading()
        html = "<blockquote><p>#{process_inline_formatting(quote_text)}</p></blockquote>"
        {acc ++ [close_list_if_needed(in_list), html], false}

      String.starts_with?(line, "---") ->
        {acc ++ [close_list_if_needed(in_list), "<hr>"], false}

      String.trim(line) == "" ->
        {acc ++ [close_list_if_needed(in_list)], false}

      true ->
        html = "<p>#{process_inline_formatting(line)}</p>"
        {acc ++ [close_list_if_needed(in_list), html], false}
    end
  end

  defp finalize_html({acc, in_list}) do
    (acc ++ [close_list_if_needed(in_list)])
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
