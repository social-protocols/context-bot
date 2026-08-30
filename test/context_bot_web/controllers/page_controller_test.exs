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
    assert response =~ "Limits"
    assert response =~ "Anyone may mention"
    assert response =~ "5 invocations per rolling day"
    assert response =~ "1 invocation per rolling day"
    assert response =~ "$20 per UTC day"
    assert response =~ "enter their own funding keys"
  end

  test "GET / includes example prompts", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ "“Is this claim true?”"
    assert response =~ "“What important context is missing?”"
    assert response =~ "“Can you find the original source?”"
  end

  test "GET / features the Stancil geographic-name invocation with a Bluesky embed", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)
    assert response =~ "Geographic-Name Policy for Gulf of America"
    refute response =~ "Yosemite"
    refute response =~ "Lake America"
    refute response =~ "acceptable-opinion"
    refute response =~ "acceptable opinion"

    assert response =~ ~s(class="bluesky-embed")

    assert response =~
             ~s(data-bluesky-uri="at://did:plc:7umvpuxe2vbrc3zrzuquzniu/app.bsky.feed.post/3muclgbgkic25")

    assert response =~
             ~s(data-bluesky-uri="at://did:plc:33avz2l7y5scw3abq3lmylns/app.bsky.feed.post/3muda3adex22u")

    assert response =~ ~s(src="https://embed.bsky.app/static/embed.js")

    assert response =~
             ~s(href="https://standard-reader.app/a/did:plc:anbhmngzs3exwbq47xxzogk4/3mudapth2od2p")

    assert response =~
             ~s(href="https://bsky.app/profile/getcontext.bot/post/3mudelkjrym23")

    csp = conn |> get_resp_header("content-security-policy") |> List.first()
    assert csp =~ "https://embed.bsky.app"
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
