defmodule ContextBot.Logging do
  @moduledoc """
  Builds the validated Logger handler configuration used by every runtime.
  """

  alias ContextBot.Logging.JSONFormatter

  @invalid_path_message "invalid CONTEXT_BOT_LOG_PATH"

  @spec handler_config(nil | String.t()) :: keyword()
  def handler_config(path) when path in [nil, ""], do: handler(type: :standard_error)

  def handler_config(path) when is_binary(path) do
    if Path.type(path) == :absolute and appendable_regular_file?(path) do
      handler(file: String.to_charlist(path))
    else
      raise ArgumentError, @invalid_path_message
    end
  end

  def handler_config(_path), do: raise(ArgumentError, @invalid_path_message)

  defp handler(destination), do: [config: destination, formatter: {JSONFormatter, %{}}]

  defp appendable_regular_file?(path) do
    not File.dir?(path) and
      case File.open(path, [:append, :utf8]) do
        {:ok, device} ->
          File.close(device)
          true

        {:error, _reason} ->
          false
      end
  end
end
