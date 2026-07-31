defmodule ContextBot.HTTP.BodyLimitTest do
  use ExUnit.Case, async: true

  alias ContextBot.HTTP.BodyLimit
  alias ContextBot.HTTP.BodyLimit.ResponseTooLargeError

  @max_bytes 4

  test "content-length responses accept the exact byte limit" do
    body = "1234"

    assert {:ok, %Req.Response{body: ^body}} =
             body
             |> content_length_request()
             |> BodyLimit.attach(@max_bytes)
             |> Req.get()
  end

  test "content-length responses reject the next byte before JSON decoding" do
    assert {:error, %ResponseTooLargeError{}} =
             "12345"
             |> content_length_request("application/json")
             |> BodyLimit.attach(@max_bytes)
             |> Req.get()
  end

  test "chunked responses accept the exact byte limit" do
    assert {:ok, %Req.Response{body: "1234"}} =
             ["12", "34"]
             |> chunked_request()
             |> BodyLimit.attach(@max_bytes)
             |> Req.get()
  end

  test "chunked responses reject the next byte at the same limit" do
    assert {:error, %ResponseTooLargeError{}} =
             ["12", "34", "5"]
             |> chunked_request()
             |> BodyLimit.attach(@max_bytes)
             |> Req.get()
  end

  defp content_length_request(body, content_type \\ "application/octet-stream") do
    Req.new(
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
        |> Plug.Conn.send_resp(200, body)
      end
    )
  end

  defp chunked_request(chunks) do
    Req.new(
      plug: fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end
    )
  end
end
