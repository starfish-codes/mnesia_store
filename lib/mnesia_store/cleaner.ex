defmodule MnesiaStore.Cleaner do
  @moduledoc false

  use GenServer

  @timeout :timer.minutes(1)

  @spec start_link(module()) :: GenServer.on_start()
  def start_link(resource_mod), do: GenServer.start_link(__MODULE__, resource_mod)

  @impl GenServer
  def init(resource_mod), do: {:ok, resource_mod, 0}

  @impl GenServer
  def handle_info(:timeout, resource_mod) do
    MnesiaStore.Resource.evict_expired(resource_mod)

    {:noreply, resource_mod, @timeout}
  end
end
