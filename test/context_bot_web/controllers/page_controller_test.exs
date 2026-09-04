defmodule ContextBotWeb.PageControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET / returns the homepage", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert response = html_response(conn, 200)
    assert response =~ "Context Bot"
    assert response =~ ~s(<img src="/images/logo.png" alt="Context Bot" width="96" height="96">)
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

    assert response =~
             ~s(data-bluesky-uri="at://did:plc:anbhmngzs3exwbq47xxzogk4/app.bsky.feed.post/3mudelkjrym23")

    assert response =~
             ~s(data-bluesky-uri="at://did:plc:anbhmngzs3exwbq47xxzogk4/app.bsky.feed.post/3mudellmx6b24")

    assert response =~ ~s(src="https://embed.bsky.app/static/embed.js")

    assert response =~ ~s(href="/r/3mudapth2od2p")

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
    assert response =~ ~s(<link rel="canonical" href="https://getcontext.bot/">)
  end

  test "GET / links favicon and apple-touch-icon assets in the document head", %{conn: conn} do
    conn = get(conn, ~p"/")

    response = html_response(conn, 200)

    assert response =~ ~s(<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">)

    assert response =~
             ~s(<link rel="icon" type="image/png" sizes="32x32" href="/images/favicon-32x32.png">)

    assert response =~
             ~s(<link rel="icon" type="image/png" sizes="16x16" href="/images/favicon-16x16.png">)

    assert response =~
             ~s(<link rel="apple-touch-icon" sizes="180x180" href="/images/apple-touch-icon.png">)

    assert response =~ ~s(<link rel="canonical" href="https://getcontext.bot/">)

    assert response =~
             ~s(<meta property="og:image" content="https://getcontext.bot/images/og.png">)
  end

  test "GET /favicon.ico serves a multi-size ICO derived from the square logo", %{conn: conn} do
    conn = get(conn, "/favicon.ico")

    assert conn.status == 200
    assert ico_content_type?(get_resp_header(conn, "content-type"))
    assert byte_size(conn.resp_body) > 1_000
    refute png?(conn.resp_body)
    assert ico_sizes(conn.resp_body) == [{16, 16}, {32, 32}, {48, 48}]
  end

  test "GET /images/favicon-16x16.png serves a 16x16 PNG", %{conn: conn} do
    conn = get(conn, "/images/favicon-16x16.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert png_dimensions(conn.resp_body) == {16, 16}
  end

  test "GET /images/favicon-32x32.png serves a 32x32 PNG", %{conn: conn} do
    conn = get(conn, "/images/favicon-32x32.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert png_dimensions(conn.resp_body) == {32, 32}
  end

  test "GET /images/apple-touch-icon.png serves a 180x180 PNG", %{conn: conn} do
    conn = get(conn, "/images/apple-touch-icon.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert png_dimensions(conn.resp_body) == {180, 180}
    assert byte_size(conn.resp_body) > 1_000
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

  test "GET /images/logo.png serves the homepage logo", %{conn: conn} do
    conn = get(conn, "/images/logo.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert byte_size(conn.resp_body) == File.stat!("priv/static/images/logo.png").size
    assert png_dimensions(conn.resp_body) == {512, 512}
  end

  defp png?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: true
  defp png?(_body), do: false

  defp png_dimensions(
         <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32,
           height::32, _rest::binary>>
       ) do
    {width, height}
  end

  defp ico_content_type?([type | _rest]) when is_binary(type) do
    String.contains?(type, "icon") or type == "image/x-icon"
  end

  defp ico_content_type?(_headers), do: false

  defp ico_sizes(<<0::16-little, 1::16-little, count::16-little, rest::binary>>)
       when count > 0 do
    ico_entries(rest, count, [])
  end

  defp ico_entries(_rest, 0, acc), do: Enum.reverse(acc)

  defp ico_entries(
         <<width::8, height::8, _color_count::8, _reserved::8, _planes::16-little,
           _bit_count::16-little, _bytes_in_res::32-little, _image_offset::32-little,
           rest::binary>>,
         count,
         acc
       ) do
    ico_entries(rest, count - 1, [
      {ico_dimension(width), ico_dimension(height)} | acc
    ])
  end

  defp ico_dimension(0), do: 256
  defp ico_dimension(size), do: size
end
