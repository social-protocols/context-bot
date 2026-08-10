defmodule ContextBot.DryRun.Interrupts do
  @moduledoc """
  Installs process-scoped signal callbacks for the foreground dry-run command.

  Signal callbacks only notify the owner. Cleanup and durable recovery remain in normal process
  code where blocking work is safe.
  """

  @type token :: reference()

  @spec install(pid(), keyword()) :: {:ok, token()} | {:error, atom()}
  def install(owner, options \\ [])

  def install(owner, options) when is_pid(owner) and is_list(options) do
    trap_signal = Keyword.get(options, :trap_signal, &System.trap_signal/3)
    untrap_signal = Keyword.get(options, :untrap_signal, &System.untrap_signal/2)

    if is_function(trap_signal, 3) and is_function(untrap_signal, 2) do
      token = make_ref()

      case trap_signal.(:sigint, token, fn -> notify(owner, :sigint) end) do
        {:ok, ^token} ->
          case trap_signal.(:sigterm, token, fn -> notify(owner, :sigterm) end) do
            {:ok, ^token} ->
              {:ok, token}

            {:error, reason} ->
              safe_untrap(untrap_signal, :sigint, token)
              {:error, reason}

            _unexpected ->
              safe_untrap(untrap_signal, :sigint, token)
              {:error, :signal_trap_failed}
          end

        {:error, reason} ->
          {:error, reason}

        _unexpected ->
          {:error, :signal_trap_failed}
      end
    else
      {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :signal_trap_failed}
  end

  def install(_owner, _options), do: {:error, :invalid_input}

  @spec remove(token(), keyword()) :: :ok
  def remove(token, options \\ [])

  def remove(token, options) when is_list(options) do
    untrap_signal = Keyword.get(options, :untrap_signal, &System.untrap_signal/2)

    if is_function(untrap_signal, 2) do
      safe_untrap(untrap_signal, :sigint, token)
      safe_untrap(untrap_signal, :sigterm, token)
    end

    :ok
  end

  def remove(_token, _options), do: :ok

  defp notify(owner, signal) do
    send(owner, {:context_bot_interrupt, signal})
    :ok
  end

  defp safe_untrap(untrap_signal, signal, token) do
    untrap_signal.(signal, token)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
