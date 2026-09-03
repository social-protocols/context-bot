defmodule ContextBot.Research.CitationsTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Citations

  test "extracts url, title, cited_text, and span and does not invent URLs" do
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
             %{
               "url" => "https://primary.example/report",
               "cited_text" => "exact excerpt",
               "title" => "Primary report",
               "span" => "A cited writeup."
             },
             %{"cited_text" => "no url here", "span" => "A cited writeup."}
           ]

    assert Citations.urls(Citations.from_content(blocks)) == ["https://primary.example/report"]
  end

  test "inserts numbered markers after the cited span and reuses numbers for the same URL" do
    writeup = "SERVIR-HKH built regional capacity. Later reporting confirmed the same finding."

    citations = [
      %{
        "url" => "https://edition.cnn.com/nepal",
        "title" => "CNN title",
        "cited_text" => "source excerpt one",
        "span" => "SERVIR-HKH built regional capacity."
      },
      %{
        "url" => "https://reliefweb.int/report",
        "title" => "ReliefWeb report",
        "cited_text" => "source excerpt two",
        "span" => "Later reporting confirmed the same finding."
      },
      %{
        "url" => "https://edition.cnn.com/nepal",
        "title" => "CNN title",
        "cited_text" => "another excerpt",
        "span" => "Later reporting confirmed the same finding."
      }
    ]

    assert Citations.publishable_writeup(writeup, citations) ==
             """
             SERVIR-HKH built regional capacity.[1] Later reporting confirmed the same finding.[2][1]

             ## Sources

             1. [CNN title](https://edition.cnn.com/nepal)
             2. [ReliefWeb report](https://reliefweb.int/report)
             """
             |> String.trim()
  end

  test "matches cited_text when no span is stored and does not emit GFM footnotes" do
    writeup = "The cited primary source resolves the disputed date."

    citations = [
      %{
        "url" => "https://primary.example/report",
        "title" => "Primary report",
        "cited_text" => "The cited primary source resolves the disputed date."
      }
    ]

    result = Citations.publishable_writeup(writeup, citations)

    assert result ==
             """
             The cited primary source resolves the disputed date.[1]

             ## Sources

             1. [Primary report](https://primary.example/report)
             """
             |> String.trim()

    refute String.contains?(result, "[^")
  end

  test "replaces a model-written Sources section so the page has one titled list" do
    writeup = """
    Floods hit Nepal.

    ## Sources
    1. [CNN title](https://edition.cnn.com/real)
    2. [Made up](https://invented.example/nope)
    """

    citations = [
      %{
        "url" => "https://edition.cnn.com/real",
        "title" => "CNN title",
        "cited_text" => "Floods hit Nepal.",
        "span" => String.trim(writeup)
      }
    ]

    result = Citations.publishable_writeup(writeup, citations)

    assert result ==
             """
             Floods hit Nepal.[1]

             ## Sources

             1. [CNN title](https://edition.cnn.com/real)
             """
             |> String.trim()

    refute String.contains?(result, "invented.example")
    refute String.contains?(result, "- https://")
    assert result |> String.split("## Sources") |> length() == 2
  end

  test "does not invent URLs and falls back to cited_text or host for the link title" do
    writeup = "No links yet. See also later confirmation."

    citations = [
      %{
        "url" => "https://primary.example/report",
        "cited_text" => "exact excerpt",
        "span" => "No links yet."
      },
      %{
        "url" => "https://second.example/page",
        "span" => "See also later confirmation."
      },
      %{"cited_text" => "orphan excerpt with no url"},
      %{"url" => "ftp://not-allowed.example/file", "cited_text" => "ignored scheme"}
    ]

    result = Citations.publishable_writeup(writeup, citations)

    assert result ==
             """
             No links yet.[1] See also later confirmation.[2]

             ## Sources

             1. [exact excerpt](https://primary.example/report)
             2. [second.example](https://second.example/page)
             """
             |> String.trim()

    refute String.contains?(result, "ftp://")
    refute String.contains?(result, "https://invented.")
    refute String.contains?(result, "orphan excerpt with no url)")
  end

  test "keeps existing https prose and still publishes one allowlisted Sources list" do
    writeup = "See https://already.example/page for background."

    citations = [
      %{
        "url" => "https://primary.example/report",
        "title" => "Primary report",
        "cited_text" => "background excerpt",
        "span" => writeup
      }
    ]

    result = Citations.publishable_writeup(writeup, citations)

    assert result ==
             """
             See https://already.example/page for background.[1]

             ## Sources

             1. [Primary report](https://primary.example/report)
             """
             |> String.trim()

    refute String.contains?(result, "](https://already.example/page)")
    refute String.contains?(result, "- https://")
  end

  test "returns the writeup unchanged when there are no allowlisted citation URLs" do
    assert Citations.publishable_writeup("No citations.", []) == "No citations."

    assert Citations.publishable_writeup("Still no urls.", [%{"cited_text" => "excerpt"}]) ==
             "Still no urls."
  end
end
