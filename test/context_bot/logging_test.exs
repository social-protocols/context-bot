defmodule ContextBot.LoggingTest do
  use ExUnit.Case, async: true

  alias ContextBot.Logging
  alias ContextBot.Logging.JSONFormatter

  test "defaults to stderr" do
    assert [config: [type: :standard_error], formatter: {JSONFormatter, %{}}] =
             Logging.handler_config(nil)

    assert Logging.handler_config("") == Logging.handler_config(nil)
  end

  test "accepts an absolute appendable file path" do
    path = Path.join(System.tmp_dir!(), "context-bot-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    assert [config: [file: configured_path], formatter: {JSONFormatter, %{}}] =
             Logging.handler_config(path)

    assert configured_path == String.to_charlist(path)
    File.write!(path, "{\"first\":true}\n", [:append])

    assert [config: [file: ^configured_path], formatter: {JSONFormatter, %{}}] =
             Logging.handler_config(path)

    File.write!(path, "{\"second\":true}\n", [:append])
    assert File.read!(path) == "{\"first\":true}\n{\"second\":true}\n"
  end

  test "rejects relative, directory, and unwritable destinations without echoing paths" do
    directory =
      Path.join(System.tmp_dir!(), "context-bot-log-dir-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rmdir(directory) end)

    missing_parent = Path.join([directory, "missing", "secret-name.jsonl"])

    for invalid <- ["logs/context.jsonl", directory, missing_parent] do
      error = assert_raise ArgumentError, fn -> Logging.handler_config(invalid) end
      assert Exception.message(error) == "invalid CONTEXT_BOT_LOG_PATH"
      refute Exception.message(error) =~ invalid
    end
  end
end
