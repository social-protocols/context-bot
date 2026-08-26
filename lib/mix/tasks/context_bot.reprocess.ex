defmodule Mix.Tasks.ContextBot.Reprocess do
  @moduledoc "Reopens one failed invocation from its complete retained Anthropic response."

  use Mix.Task

  alias ContextBot.LocalMigrate
  alias ContextBot.Workflow.{Reprocessor, ReprocessorRuntime}

  @requirements ["app.config"]
  @shortdoc "Reopen a provider-processing failure from its retained response"

  @impl Mix.Task
  def run([invocation_id]) do
    id = parse_invocation_id!(invocation_id)
    config = Application.get_env(:context_bot, __MODULE__, [])
    runtime = Keyword.get(config, :runtime, ReprocessorRuntime)
    reprocessor = Keyword.get(config, :reprocessor, Reprocessor)
    now = Keyword.get(config, :now, &DateTime.utc_now/0)

    LocalMigrate.ensure_migrated!()
    start_runtime!(runtime)

    case reprocessor.reprocess(id, now: now.()) do
      {:ok, %{id: ^id}} ->
        Mix.shell().info("status=reopened")
        Mix.shell().info("invocation_id=#{id}")
        :ok

      {:error, reason} ->
        Mix.raise(reprocess_error(reason))

      _invalid ->
        Mix.raise("reprocessing failed")
    end
  end

  def run(_arguments), do: Mix.raise("expected exactly one positive integer invocation ID")

  defp parse_invocation_id!(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _invalid -> Mix.raise("expected exactly one positive integer invocation ID")
    end
  end

  defp start_runtime!(runtime) do
    case runtime.ensure_started() do
      :ok -> :ok
      _error -> Mix.raise("unable to start worker-free reprocessing runtime")
    end
  end

  defp reprocess_error(:not_found), do: "invocation not found"
  defp reprocess_error(:not_reprocessable), do: "invocation is not reprocessable"
  defp reprocess_error(:ambiguous_provider_attempt), do: "provider attempt is ambiguous"
  defp reprocess_error(:missing_recorded_response), do: "recorded response is missing"
  defp reprocess_error(:invalid_recorded_response), do: "recorded response is not replayable"
  defp reprocess_error(_reason), do: "reprocessing failed"
end
