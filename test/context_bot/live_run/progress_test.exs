defmodule ContextBot.LiveRun.ProgressTest do
  use ExUnit.Case, async: true

  alias ContextBot.LiveRun.Progress
  alias ContextBot.Workflow.Invocation

  test "non-TTY output emits one content-free line per durable public stage" do
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
    state = Progress.update(state, invocation(:researching))
    state = Progress.update(state, invocation(:reply_ready))
    state = Progress.update(state, invocation(:publishing))
    state = Progress.update(state, invocation(:deferred_budget))
    state = Progress.update(state, invocation(:complete))
    _state = Progress.update(state, invocation(:failed))

    rendered = output(io)

    assert rendered =~
             "live_run_id=42 stage=capturing_thread elapsed=0s fetching selected post and ancestors\n"

    assert rendered =~
             "live_run_id=42 stage=thread_ready elapsed=2s thread snapshot stored; queued for research\n"

    assert rendered =~
             "live_run_id=42 stage=researching elapsed=2s waiting for Claude research (may take up to 300s)\n"

    assert rendered =~
             "live_run_id=42 stage=reply_ready elapsed=2s reply prepared; queued for publication\n"

    assert rendered =~ "live_run_id=42 stage=publishing elapsed=2s publishing Bluesky reply\n"

    assert rendered =~
             "live_run_id=42 stage=deferred_budget elapsed=2s deferred by daily API budget\n"

    assert rendered =~ "live_run_id=42 stage=complete elapsed=2s complete\n"
    assert rendered =~ "live_run_id=42 stage=failed elapsed=2s failed\n"
    refute rendered =~ "private question"
    refute rendered =~ "private answer"
    refute rendered =~ "\e["
  end

  test "TTY output animates one line and finish clears it" do
    {:ok, io} = StringIO.open("")

    state =
      Progress.start(invocation(:publishing),
        io: io,
        tty?: true,
        monotonic_ms: fn -> 12_000 end,
        started_ms: 10_000
      )

    state = Progress.tick(state)
    state = Progress.tick(state)
    assert :ok = Progress.finish(state)

    rendered = output(io)
    assert rendered =~ "\r\e[2K| live_run_id=42 stage=publishing elapsed=2s"
    assert rendered =~ "\r\e[2K/ live_run_id=42 stage=publishing elapsed=2s"
    assert rendered =~ "\r\e[2K- live_run_id=42 stage=publishing elapsed=2s"
    assert String.ends_with?(rendered, "\r\e[2K")
    refute rendered =~ "\n"
  end

  test "progress never renders stored question or answer content" do
    {:ok, io} = StringIO.open("")

    state = Progress.start(invocation(:publishing), io: io, tty?: false)
    rendered = output(io)

    assert rendered =~ "live_run_id=42 stage=publishing"
    refute rendered =~ "private question"
    refute rendered =~ "private answer"
    assert :ok = Progress.finish(state)
  end

  defp invocation(stage) do
    %Invocation{
      id: 42,
      dry_run: false,
      stage: stage,
      invocation_text: "private question",
      selected_reply: "private answer"
    }
  end

  defp output(io) do
    {_input, output} = StringIO.contents(io)
    output
  end
end
