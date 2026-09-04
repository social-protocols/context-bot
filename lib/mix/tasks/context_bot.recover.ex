defmodule Mix.Tasks.ContextBot.Recover do
  @moduledoc """
  Runs the same durable recovery path as boot.

  With no arguments, scans abandoned and failed invocations via
  `Recovery.recover_orphans/1`. With one id, recovers that row via
  `Recovery.recover_invocation/2` with `operator?: true`, which retries
  structure-from-writeup for `max_tokens`, `invalid_structured_output`,
  `empty_compact`, `overlong_compact`, and `invalid_repair` without
  clearing research. May enqueue work that later publishes a Bluesky reply.
  """

  use Mix.Task

  alias ContextBot.LocalMigrate
  alias ContextBot.Workflow.{Recovery, ReprocessorRuntime}

  @requirements ["app.config"]
  @shortdoc "Recover failed invocations using the same path as boot"

  @impl Mix.Task
  def run(arguments) do
    id = parse_arguments!(arguments)
    config = Application.get_env(:context_bot, __MODULE__, [])
    runtime = Keyword.get(config, :runtime, ReprocessorRuntime)
    recovery = Keyword.get(config, :recovery, Recovery)
    now = Keyword.get(config, :now, &DateTime.utc_now/0)

    LocalMigrate.ensure_migrated!()
    start_runtime!(runtime)

    case id do
      :all -> recover_all(recovery, now.())
      invocation_id -> recover_one(recovery, invocation_id, now.())
    end
  end

  defp parse_arguments!([]), do: :all
  defp parse_arguments!([""]), do: :all
  defp parse_arguments!([invocation_id]), do: parse_invocation_id!(invocation_id)

  defp parse_arguments!(_arguments),
    do: Mix.raise("expected no arguments or one positive integer invocation ID")

  defp recover_all(recovery, now) do
    case recovery.recover_orphans(recover_orphans_options(now)) do
      {:ok, summary} ->
        Mix.shell().info("status=recovered")
        Mix.shell().info("examined=#{summary.examined}")
        Mix.shell().info("resumed=#{summary.resumed}")
        Mix.shell().info("terminalized=#{summary.terminalized}")
        Mix.shell().info("unchanged=#{summary.unchanged}")
        :ok

      {:error, _reason} ->
        Mix.raise("recovery failed")
    end
  end

  defp recover_one(recovery, id, now) do
    case recovery.recover_invocation(id, now: now, operator?: true) do
      result when result in [:resumed, :terminalized, :unchanged] ->
        Mix.shell().info("status=#{result}")
        Mix.shell().info("invocation_id=#{id}")
        :ok

      {:error, :not_found} ->
        Mix.raise("invocation not found")

      _invalid ->
        Mix.raise("recovery failed")
    end
  end

  defp recover_orphans_options(now) do
    [
      now: now,
      job_states: ["executing", "completed", "cancelled", "discarded"]
    ]
  end

  defp parse_invocation_id!(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _invalid -> Mix.raise("expected no arguments or one positive integer invocation ID")
    end
  end

  defp start_runtime!(runtime) do
    case runtime.ensure_started() do
      :ok -> :ok
      _error -> Mix.raise("unable to start worker-free reprocessing runtime")
    end
  end
end
