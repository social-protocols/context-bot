defmodule ContextBot.LimitNoticeNoop do
  @moduledoc false

  def handoff_actor_rate(_invocation, _deps), do: :ok
  def maybe_post_budget(_invocation, _deps), do: :ok
end

defmodule ContextBot.LimitNoticeRecorder do
  @moduledoc false

  def handoff_actor_rate(invocation, _deps) do
    send(self(), {:limit_notice, :actor_rate, invocation.id})
    :ok
  end

  def maybe_post_budget(invocation, _deps) do
    send(self(), {:limit_notice, :budget, invocation.id})
    :ok
  end
end
