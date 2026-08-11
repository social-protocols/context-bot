defmodule ContextBot.LiveRun.Progress do
  @moduledoc """
  Renders content-free progress from durable public live-run stages.
  """

  alias ContextBot.Workflow.Invocation

  @frames ["|", "/", "-", "\\"]
  @clear_line "\r\e[2K"

  @enforce_keys [
    :id,
    :stage,
    :started_ms,
    :frame,
    :tty?,
    :io,
    :monotonic_ms,
    :anthropic_timeout_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          stage: atom() | nil,
          started_ms: integer(),
          frame: non_neg_integer(),
          tty?: boolean(),
          io: IO.device(),
          monotonic_ms: (-> integer()),
          anthropic_timeout_ms: pos_integer()
        }

  @spec start(Invocation.t(), keyword()) :: t()
  def start(%Invocation{id: id, stage: stage}, options \\ []) when is_integer(id) and id > 0 do
    io = Keyword.get(options, :io, :stdio)

    monotonic_ms =
      Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    state = %__MODULE__{
      id: id,
      stage: stage,
      started_ms: Keyword.get(options, :started_ms, monotonic_ms.()),
      frame: 0,
      tty?: Keyword.get_lazy(options, :tty?, fn -> tty?(io) end),
      io: io,
      monotonic_ms: monotonic_ms,
      anthropic_timeout_ms: Keyword.get(options, :anthropic_timeout_ms, 300_000)
    }

    render(state)
  end

  @spec update(t(), Invocation.t()) :: t()
  def update(%__MODULE__{stage: stage} = state, %Invocation{stage: stage}), do: state

  def update(%__MODULE__{} = state, %Invocation{stage: stage}) do
    state
    |> Map.put(:stage, stage)
    |> render()
  end

  @spec tick(t()) :: t()
  def tick(%__MODULE__{tty?: false} = state), do: state

  def tick(%__MODULE__{} = state) do
    state
    |> Map.update!(:frame, &(&1 + 1))
    |> render()
  end

  @spec finish(t()) :: :ok
  def finish(%__MODULE__{tty?: true, io: io}) do
    IO.write(io, @clear_line)
    :ok
  end

  def finish(%__MODULE__{}), do: :ok

  defp render(%__MODULE__{tty?: true} = state) do
    frame = Enum.at(@frames, rem(state.frame, length(@frames)))
    IO.write(state.io, [@clear_line, frame, " ", line(state)])
    state
  end

  defp render(%__MODULE__{} = state) do
    IO.write(state.io, [line(state), "\n"])
    state
  end

  defp line(state) do
    [
      "live_run_id=",
      Integer.to_string(state.id),
      " stage=",
      stage_name(state.stage),
      " elapsed=",
      Integer.to_string(elapsed_seconds(state)),
      "s ",
      stage_description(state.stage, state.anthropic_timeout_ms)
    ]
  end

  defp stage_name(stage) when is_atom(stage), do: Atom.to_string(stage)
  defp stage_name(_stage), do: "working"

  defp elapsed_seconds(state),
    do: max(div(state.monotonic_ms.() - state.started_ms, 1_000), 0)

  defp stage_description(:capturing_thread, _timeout),
    do: "fetching selected post and ancestors"

  defp stage_description(:thread_ready, _timeout),
    do: "thread snapshot stored; queued for research"

  defp stage_description(:researching, timeout),
    do: "waiting for Claude research (may take up to #{div(timeout, 1_000)}s)"

  defp stage_description(:reply_ready, _timeout), do: "reply prepared; queued for publication"
  defp stage_description(:publishing, _timeout), do: "publishing Bluesky reply"
  defp stage_description(:deferred_budget, _timeout), do: "deferred by daily API budget"
  defp stage_description(:complete, _timeout), do: "complete"
  defp stage_description(:failed, _timeout), do: "failed"
  defp stage_description(_stage, _timeout), do: "working"

  defp tty?(io) do
    IO.ANSI.enabled?() and match?({:ok, _columns}, :io.columns(io))
  end
end
