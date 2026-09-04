defmodule ContextBotWeb.FullResponseController do
  @moduledoc """
  Public HTML mirror of a published full-response document.

  Serves the sqlite-backed writeup immediately. When Standard Reader has
  indexed the `site.standard.document`, responds with 302 to the Reader URL.
  """

  use ContextBotWeb, :controller

  alias ContextBot.StandardSite.{Document, Mirror, PageCopy}
  alias ContextBotWeb.MarkdownHTML

  @cache_control "private, max-age=60"

  def show(conn, %{"id" => id}) do
    opts = Application.get_env(:context_bot, Mirror, [])

    case Mirror.serve(id, opts) do
      {:redirect, url} ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> redirect(external: url)

      {:mirror, invocation, markdown} ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_content_type("text/html")
        |> send_resp(200, render_page(invocation, markdown))

      :not_found ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(404, render_not_found())
    end
  end

  defp render_page(invocation, markdown) do
    content = Mirror.document_content(invocation)
    title = PageCopy.title(content)
    description = PageCopy.description(content) || title
    mirror_url = Mirror.public_url(invocation)
    reader_url = Document.reader_url_from_uri(invocation.standard_site_document_uri)
    body = MarkdownHTML.to_html(markdown)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{MarkdownHTML.escape_html(title)}</title>
      <meta name="description" content="#{MarkdownHTML.escape_html(description)}">
      <link rel="canonical" href="#{MarkdownHTML.escape_html(mirror_url)}">
      <link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">
      <link rel="icon" type="image/png" sizes="32x32" href="/images/favicon-32x32.png">
      <link rel="icon" type="image/png" sizes="16x16" href="/images/favicon-16x16.png">
      <link rel="apple-touch-icon" sizes="180x180" href="/images/apple-touch-icon.png">
      <meta property="og:title" content="#{MarkdownHTML.escape_html(title)}">
      <meta property="og:description" content="#{MarkdownHTML.escape_html(description)}">
      <meta property="og:url" content="#{MarkdownHTML.escape_html(mirror_url)}">
      <meta property="og:type" content="article">
      <meta property="og:site_name" content="Context Bot">
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
        h1 { font-size: 2rem; font-weight: 700; margin-bottom: 1rem; }
        h2 { font-size: 1.5rem; font-weight: 600; margin-top: 2rem; margin-bottom: 0.75rem; }
        h3 { font-size: 1.15rem; font-weight: 600; margin-top: 1.5rem; margin-bottom: 0.5rem; }
        h4 { font-size: 1rem; font-weight: 600; margin-top: 1.25rem; margin-bottom: 0.5rem; }
        p { margin-bottom: 1rem; }
        ul { margin-left: 1.5rem; margin-bottom: 1rem; }
        li { margin-bottom: 0.5rem; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr { border: none; border-top: 1px solid #e0e0e0; margin: 2rem 0; }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
          font-size: 0.9em;
          background: #f4f4f4;
          padding: 0.1em 0.3em;
          border-radius: 3px;
        }
        pre {
          background: #f4f4f4;
          padding: 0.75rem 1rem;
          overflow-x: auto;
          margin-bottom: 1rem;
          border-radius: 4px;
        }
        pre code { background: transparent; padding: 0; }
        .banner {
          background: #f8f9fa;
          border: 1px solid #e0e0e0;
          border-radius: 4px;
          padding: 0.75rem 1rem;
          margin-bottom: 1.5rem;
          font-size: 0.95rem;
          color: #333333;
        }
        .site { margin-bottom: 1.5rem; font-size: 0.95rem; }
        @media (max-width: 640px) {
          body { padding: 1rem 0.75rem; }
          h1 { font-size: 1.6rem; }
          h2 { font-size: 1.25rem; }
        }
      </style>
    </head>
    <body>
      <p class="site"><a href="/">Context Bot</a></p>
      <div class="banner">#{banner_html(reader_url)}</div>
      #{body}
    </body>
    </html>
    """
  end

  defp banner_html(reader_url) when is_binary(reader_url) do
    "This getcontext.bot page is a temporary mirror while Standard Reader indexes the document. Canonical copy: <a href=\"#{MarkdownHTML.escape_html(reader_url)}\">Standard Reader</a>."
  end

  defp banner_html(_reader_url), do: "Context Bot full response."

  defp render_not_found do
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
