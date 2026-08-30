defmodule ContextBotWeb.PageControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET / returns the homepage", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert response = html_response(conn, 200)
    assert response =~ "Context Bot"
    assert response =~ "@getcontext.bot"
    assert response =~ "on a Bluesky post"
    assert response =~ ~s(href="https://bsky.app/profile/getcontext.bot")
    assert response =~ "Social Protocols"
    assert response =~ "stored as atproto records"
    assert response =~ ~s(href="https://github.com/social-protocols/context-bot/")
    assert response =~ ~s(href="https://social-protocols.org")
    refute response =~ "Invite Only"
    assert response =~ "Limits"
    assert response =~ "Anyone may mention"
    assert response =~ "5 invocations per rolling day"
    assert response =~ "1 invocation per rolling day"
    assert response =~ "$20 per UTC day"
    assert response =~ "enter their own funding keys"
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
