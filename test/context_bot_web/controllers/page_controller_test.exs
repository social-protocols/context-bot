defmodule ContextBotWeb.PageControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET / returns the homepage", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert response = html_response(conn, 200)
    assert response =~ "Context Bot"
    assert response =~ "@getcontext.bot"
    refute response =~ "@getcontext-bot"
    assert response =~ "on a Bluesky post"
    assert response =~ ~s(href="https://bsky.app/profile/getcontext.bot")
    assert response =~ "Social Protocols"
    assert response =~ "cited sources"
    refute response =~ "soures"
    refute response =~ "joints"
    refute response =~ "Invite Only"
    assert response =~ "joins"
    assert response =~ ~s(href="https://github.com/social-protocols/context-bot/")
    assert response =~ ~s(href="https://social-protocols.org")
  end

  test "GET / includes example prompts", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ "“Is this claim true?”"
    assert response =~ "“What important context is missing?”"
    assert response =~ "“Can you find the original source?”"
  end

  test "GET / features the Yosemite land-deal invocation", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ "The Story on the Yosemite Land Deal"
    assert response =~ "How big is the parcel?"
    assert response =~ "Why does the developer want it?"
    assert response =~ "What would the Park Service get in return?"
    assert response =~ "Is there a legitimate reason for the NPS to consider it?"
    assert response =~ "Per NOTUS"
    assert response =~ "0.25-mile strip inside Yosemite"
    assert response =~ "Kingsbarn Realty Capital"

    assert response =~
             ~s(href="https://standard-reader.app/a/did:plc:anbhmngzs3exwbq47xxzogk4/3mu67jhxqnv2b")

    assert response =~
             ~s(href="https://bsky.app/profile/getcontext.bot/post/3mu67jhxqnv2c")

    refute response =~ "Lake America"
    refute response =~ "acceptable-opinion"
    refute response =~ "acceptable opinion"
  end

  test "GET / includes Open Graph and Twitter metadata", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ ~s(<meta property="og:title" content="Context Bot">)
    assert response =~ ~s(<meta property="og:description" content=")
    assert response =~ "@getcontext.bot"

    assert response =~
             ~s(<meta property="og:image" content="https://getcontext.bot/images/og.png">)

    assert response =~ ~s(<meta property="og:url" content="https://getcontext.bot/">)
    assert response =~ ~s(<meta property="og:type" content="website">)
    assert response =~ ~s(<meta name="twitter:card" content="summary_large_image">)
    assert response =~ ~s(<meta name="twitter:title" content="Context Bot">)

    assert response =~
             ~s(<meta name="twitter:image" content="https://getcontext.bot/images/og.png">)

    assert response =~ ~s(<meta name="twitter:description" content=")
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

  test "GET /images/og.png serves the share image", %{conn: conn} do
    conn = get(conn, "/images/og.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert byte_size(conn.resp_body) > 1_000
  end
end
