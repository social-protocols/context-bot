defmodule ContextBot.Research.CitationsTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Citations

  test "extracts url and cited_text from citation blocks and does not invent URLs" do
    blocks = [
      %{
        "type" => "text",
        "text" => "A cited writeup.",
        "citations" => [
          %{
            "type" => "web_search_result_location",
            "url" => "https://primary.example/report",
            "cited_text" => "exact excerpt",
            "title" => "Primary report"
          },
          %{
            "type" => "char_location",
            "cited_text" => "no url here"
          },
          %{
            "url" => "not-a-url",
            "cited_text" => "ignored scheme"
          }
        ]
      }
    ]

    assert Citations.from_content(blocks) == [
             %{"url" => "https://primary.example/report", "cited_text" => "exact excerpt"},
             %{"cited_text" => "no url here"}
           ]

    assert Citations.urls(Citations.from_content(blocks)) == ["https://primary.example/report"]
  end

  test "appends a Sources section only when the writeup has no visible https links" do
    citations = [
      %{"url" => "https://primary.example/report", "cited_text" => "excerpt"},
      %{"url" => "https://second.example/page"}
    ]

    assert Citations.publishable_writeup("No links yet.", citations) ==
             "No links yet.\n\n## Sources\n\n- https://primary.example/report\n- https://second.example/page"

    assert Citations.publishable_writeup("See https://already.example/page", citations) ==
             "See https://already.example/page"

    assert Citations.publishable_writeup("No citations.", []) == "No citations."
  end
end
