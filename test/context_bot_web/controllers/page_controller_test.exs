defmodule ContextBotWeb.PageControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET / returns the homepage", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert response = html_response(conn, 200)
    assert response =~ "Context Bot"
    assert response =~ "Mention @getcontext.bot on a Bluesky post"
    assert response =~ "A Social Protocols project"
    assert response =~ "versioned system prompt"
    assert response =~ "Anthropic request parameters"
    refute response =~ "stored as atproto records"
  end

  test "GET / includes proper HTML structure", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ "<!DOCTYPE html>"
    assert response =~ "<html lang=\"en\">"
    assert response =~ "<meta charset=\"utf-8\">"
    assert response =~ "<meta name=\"viewport\""
  end

  test "GET / includes main content sections", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    # Verify page has section headings
    assert response =~ ~r/<h2>/
    # Verify page has lists or paragraphs
    assert response =~ ~r/<(ul|p)>/
  end
end
