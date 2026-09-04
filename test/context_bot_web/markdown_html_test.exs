defmodule ContextBotWeb.MarkdownHTMLTest do
  use ExUnit.Case, async: true

  alias ContextBotWeb.MarkdownHTML

  test "escapes quotes in href so onmouseover cannot break out of the attribute" do
    markdown = ~S|[x](https://example.com/" onmouseover="alert(1))|
    html = MarkdownHTML.to_html(markdown)

    refute html =~ ~S|onmouseover="alert|
    refute html =~ ~S|href="https://example.com/" |
    assert html =~ ~S|href="https://example.com/&quot; onmouseover=&quot;alert(1"|
    assert html =~ ">x</a>"
  end

  test "keeps an ordinary https citation as a single quoted href" do
    html = MarkdownHTML.to_html(~S|[source](https://example.test/a)|)

    assert html =~ ~S|<a href="https://example.test/a">source</a>|
  end
end
