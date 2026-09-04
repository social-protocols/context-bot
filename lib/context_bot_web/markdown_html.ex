defmodule ContextBotWeb.MarkdownHTML do
  @moduledoc """
  Small HTML renderer for Standard.site full-response markdown.

  This is display-only. Content still comes from `Document.format_markdown/1`.
  Link targets are restricted to `http` and `https`.
  """

  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> render_lines([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  def to_html(_markdown), do: ""

  defp render_lines([], acc), do: acc

  defp render_lines(["```" <> _info | rest], acc) do
    {code_lines, remaining} = take_fence(rest, [])
    html = "<pre><code>#{escape_html(Enum.join(code_lines, "\n"))}</code></pre>"
    render_lines(remaining, [html | acc])
  end

  defp render_lines([line | rest], acc) do
    case line_kind(line) do
      {:heading, tag, text} ->
        render_lines(rest, [heading(tag, text) | acc])

      :hr ->
        render_lines(rest, ["<hr>" | acc])

      :list_item ->
        {items, remaining} = take_list([line | rest], [])
        render_lines(remaining, [list_html(items) | acc])

      :blank ->
        render_lines(rest, acc)

      :paragraph ->
        render_lines(rest, ["<p>#{inline(line)}</p>" | acc])
    end
  end

  defp line_kind("#### " <> text), do: {:heading, "h4", text}
  defp line_kind("### " <> text), do: {:heading, "h3", text}
  defp line_kind("## " <> text), do: {:heading, "h2", text}
  defp line_kind("# " <> text), do: {:heading, "h1", text}
  defp line_kind("- " <> _text), do: :list_item

  defp line_kind(line) do
    cond do
      String.starts_with?(line, "---") and String.trim(line, "-") == "" -> :hr
      String.trim(line) == "" -> :blank
      true -> :paragraph
    end
  end

  defp take_fence(["```" <> _info | rest], acc), do: {Enum.reverse(acc), rest}
  defp take_fence([line | rest], acc), do: take_fence(rest, [line | acc])
  defp take_fence([], acc), do: {Enum.reverse(acc), []}

  defp take_list([line | rest], acc) do
    if String.starts_with?(line, "- ") do
      take_list(rest, [String.slice(line, 2..-1//1) | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp take_list([], acc), do: {Enum.reverse(acc), []}

  defp list_html(items) do
    rows = Enum.map_join(items, "\n", fn item -> "<li>#{inline(item)}</li>" end)
    "<ul>\n#{rows}\n</ul>"
  end

  defp heading(tag, text), do: "<#{tag}>#{inline(text)}</#{tag}>"

  defp inline(text) do
    text
    |> replace_code()
    |> replace_links()
    |> replace_bold()
    |> unescape_placeholders()
  end

  defp replace_code(text) do
    Regex.replace(~r/`([^`]+)`/u, text, fn _, code ->
      "\u0001CODE\u0001#{Base.encode64(escape_html(code))}\u0001"
    end)
  end

  defp replace_links(text) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/u, text, fn _, label, href ->
      case safe_href(href) do
        nil ->
          escape_html(label)

        url ->
          "\u0001LINK\u0001#{Base.encode64(escape_html(url))}\u0001#{Base.encode64(escape_html(label))}\u0001"
      end
    end)
  end

  defp replace_bold(text) do
    text
    |> escape_html()
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/u, &1, "<strong>\\1</strong>"))
  end

  defp unescape_placeholders(text) do
    text
    |> String.replace(~r/\x{0001}CODE\x{0001}([A-Za-z0-9+\/=]+)\x{0001}/u, fn match ->
      [_, encoded] = Regex.run(~r/\x{0001}CODE\x{0001}([A-Za-z0-9+\/=]+)\x{0001}/u, match)
      "<code>#{Base.decode64!(encoded)}</code>"
    end)
    |> String.replace(
      ~r/\x{0001}LINK\x{0001}([A-Za-z0-9+\/=]+)\x{0001}([A-Za-z0-9+\/=]+)\x{0001}/u,
      fn match ->
        [_, href, label] =
          Regex.run(
            ~r/\x{0001}LINK\x{0001}([A-Za-z0-9+\/=]+)\x{0001}([A-Za-z0-9+\/=]+)\x{0001}/u,
            match
          )

        # href was escape_html/1-encoded so quotes cannot break the attribute.
        ~s(<a href="#{Base.decode64!(href)}">#{Base.decode64!(label)}</a>)
      end
    )
  end

  defp safe_href(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      String.trim(url)
    end
  end

  defp safe_href(_url), do: nil

  def escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def escape_html(_text), do: ""
end
