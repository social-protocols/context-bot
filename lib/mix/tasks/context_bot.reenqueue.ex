defmodule Mix.Tasks.ContextBot.Reenqueue do
  @moduledoc "Resets one failed or unpublished-complete invocation and enqueues a fresh research run."

  use Mix.Task

  alias ContextBot.LocalMigrate
  alias ContextBot.Workflow.{Reenqueuer, ReprocessorRuntime}

  @requirements ["app.config"]
  @shortdoc "Reenqueue a failed invocation as a fresh two-phase research run"

  @impl Mix.Task
  def run([invocation_id]) do
    id = parse_invocation_id!(invocation_id)
    config = Application.get_env(:context_bot, __MODULE__, [])
    runtime = Keyword.get(config, :runtime, ReprocessorRuntime)
    reenqueuer = Keyword.get(config, :reenqueuer, Reenqueuer)
    now = Keyword.get(config, :now, &DateTime.utc_now/0)

    LocalMigrate.ensure_migrated!()
    start_runtime!(runtime)

    case reenqueuer.reenqueue(id, now: now.()) do
      {:ok, %{id: ^id}} ->
        Mix.shell().info("status=reenqueued")
        Mix.shell().info("invocation_id=#{id}")
        :ok

      {:error, reason} ->
        Mix.raise(reenqueue_error(reason))

      _invalid ->
        Mix.raise("reenqueuing failed")
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

  defp reenqueue_error(:not_found), do: "invocation not found"
  defp reenqueue_error(:not_reenqueueable), do: "invocation is not reenqueueable"
  defp reenqueue_error(:already_published), do: "invocation already has a published reply"
  defp reenqueue_error(:ambiguous_provider_attempt), do: "provider attempt is ambiguous"
  defp reenqueue_error(_reason), do: "reenqueuing failed"
end
