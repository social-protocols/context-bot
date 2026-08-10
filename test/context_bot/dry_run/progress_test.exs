defmodule ContextBot.DryRun.ProgressTest do
  use ExUnit.Case, async: true

  alias ContextBot.DryRun.Progress
  alias ContextBot.Workflow.Invocation

  test "non-TTY output emits one plain line per durable stage" do
    {:ok, io} = StringIO.open("")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now = fn -> Agent.get(clock, & &1) end

    state =
      Progress.start(invocation(:capturing_thread),
        io: io,
        tty?: false,
        monotonic_ms: now,
        anthropic_timeout_ms: 300_000
      )

    state = Progress.update(state, invocation(:capturing_thread))
    Agent.update(clock, fn _ -> 2_000 end)
    state = Progress.update(state, invocation(:thread_ready))
    state = Progress.update(state, invocation(:thread_ready))
    Agent.update(clock, fn _ -> 3_000 end)
    _state = Progress.update(state, invocation(:researching))

    assert output(io) ==
             "dry_run_id=42 stage=capturing_thread elapsed=0s fetching selected post and ancestors\n" <>
               "dry_run_id=42 stage=thread_ready elapsed=2s thread snapshot stored; queued for research\n" <>
               "dry_run_id=42 stage=researching elapsed=3s waiting for Claude research (may take up to 300s)\n"

    refute output(io) =~ "\e["
    refute output(io) =~ "%"
  end

  test "TTY output animates one line and finish clears it" do
    {:ok, io} = StringIO.open("")

    state =
      Progress.start(invocation(:researching),
        io: io,
        tty?: true,
        monotonic_ms: fn -> 12_000 end,
        started_ms: 10_000,
        anthropic_timeout_ms: 300_000
      )

    state = Progress.tick(state)
    state = Progress.tick(state)
    assert :ok = Progress.finish(state)

    rendered = output(io)
    assert rendered =~ "\r\e[2K| dry_run_id=42 stage=researching elapsed=2s"
    assert rendered =~ "\r\e[2K/ dry_run_id=42 stage=researching elapsed=2s"
    assert rendered =~ "\r\e[2K- dry_run_id=42 stage=researching elapsed=2s"
    assert String.ends_with?(rendered, "\r\e[2K")
    refute rendered =~ "\n"
  end

  test "unknown stages are rendered without inspecting invocation content" do
    {:ok, io} = StringIO.open("")

    state =
      Progress.start(%{invocation(:capturing_thread) | stage: :received},
        io: io,
        tty?: false,
        monotonic_ms: fn -> 0 end
      )

    assert output(io) == "dry_run_id=42 stage=received elapsed=0s working\n"
    refute output(io) =~ "private question"
    assert :ok = Progress.finish(state)
  end

  defp invocation(stage) do
    %Invocation{
      id: 42,
      dry_run: true,
      stage: stage,
      invocation_text: "private question"
    }
  end

  defp output(io) do
    {_input, output} = StringIO.contents(io)
    output
  end
end
