defmodule MnesiaStore.Coordinator.Jobs do
  @moduledoc false

  alias MnesiaStore.Workflow

  @spec check(atom(), map()) :: map()
  def check(:booting, %{task: nil} = data) do
    launch(data, fn -> Workflow.bootstrap(data.opts) end)
  end

  def check(:ready, %{task: nil} = data) do
    launch(data, fn -> Workflow.check(data.opts) end)
  end

  def check(_state, data) do
    data
  end

  @spec heal(map(), [node()]) :: map()
  def heal(data, nodes) do
    launch(data, fn -> Workflow.heal(nodes, data.opts) end)
  end

  @spec completed(map(), atom(), term()) :: map()
  def completed(data, :failed, nil) do
    %{data | task: nil}
  end

  def completed(data, _state, error) do
    %{data | task: nil, last_error: error}
  end

  @spec schedule(map()) :: [term()]
  def schedule(data) do
    interval = Keyword.get(data.opts, :check_interval, 5_000)
    [{{:timeout, :check}, interval, :check}]
  end

  defp launch(data, fun) do
    task = Task.Supervisor.async_nolink(MnesiaStore.Workers, fun)
    %{data | task: task}
  end
end
