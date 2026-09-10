defmodule MnesiaStore.Resources do
  @moduledoc false

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_started([module()]) :: :ok
  def ensure_started(resources) do
    Enum.each(resources, fn resource ->
      case DynamicSupervisor.start_child(__MODULE__, {resource, :managed}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
