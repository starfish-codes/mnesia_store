defmodule MnesiaStore.Healer do
  @moduledoc false

  use GenServer

  require Logger
  require Record

  Record.defrecordp(:cstruct, Record.extract(:cstruct, from_lib: "mnesia/src/mnesia.hrl"))

  @timeout :timer.minutes(5)

  @spec start_link(module()) :: GenServer.on_start()
  def start_link(resource_mod), do: GenServer.start_link(__MODULE__, resource_mod)

  @impl GenServer
  def init(resource_mod) do
    send(self(), :check)
    {:ok, resource_mod}
  end

  @impl GenServer
  def handle_info(:check, resource_mod) do
    schedule_check()
    perform_check(resource_mod)
    {:noreply, resource_mod}
  end

  defp perform_check(resource_mod) do
    cstruct(cookie: cookie) = :mnesia_lib.val({resource_mod, :cstruct})

    resource_mod
    |> divergent_nodes(cookie)
    |> reinit_table(resource_mod)
  end

  defp divergent_nodes(resource_mod, local_cookie) do
    :visible
    |> Node.list()
    |> Enum.filter(fn node ->
      case :erpc.call(node, :mnesia_lib, :val, [{resource_mod, :cstruct}]) do
        cstruct(cookie: foreign_cookie) -> local_cookie != foreign_cookie
        _error -> false
      end
    end)
  end

  defp reinit_table([], _resource_mod), do: :ok

  defp reinit_table(nodes, resource_mod) do
    Enum.each(nodes, &migrate_data(&1, resource_mod))
    :erpc.multicall(nodes, resource_mod, :delete_table, [])
    :erpc.multicall(nodes, resource_mod, :init_table, [])

    :ok
  end

  defp migrate_data(divergent_node, resource_mod) do
    case :erpc.call(divergent_node, resource_mod, :all, []) do
      {:ok, data} ->
        Enum.each(data, &MnesiaStore.put/1)

      {:error, reason} ->
        Logger.error(
          "Could not fetch #{resource_mod} data from #{divergent_node}: " <> inspect(reason)
        )
    end
  end

  defp schedule_check, do: Process.send_after(self(), :check, period())

  defp period do
    jitter =
      1
      |> :timer.minutes()
      |> :rand.uniform()

    @timeout + jitter
  end
end
