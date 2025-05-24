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
    cstruct(cookie: cookie, ram_copies: nodes) = :mnesia_lib.val({resource_mod, :cstruct})

    unless cookie_match?(resource_mod, cookie) do
      reinit_table(nodes, resource_mod)
    end
  end

  defp cookie_match?(resource_mod, local_cookie) do
    :visible
    |> Node.list()
    |> :erpc.multicall(:mnesia_lib, :val, [{resource_mod, :cstruct}])
    |> Enum.all?(fn
      {:ok, cstruct(cookie: foreign_cookie)} -> local_cookie == foreign_cookie
      _error -> true
    end)
  end

  defp reinit_table(nodes, resource_mod) do
    case resource_mod.all() do
      {:ok, data} ->
        reinit_table(nodes, resource_mod, data)

      {:error, reason} ->
        Logger.error("Could not load #{resource_mod} data: " <> inspect(reason))
    end
  end

  defp reinit_table(nodes, resource_mod, data) do
    resource_mod.delete_table()
    Enum.each(nodes, &:erpc.call(&1, resource_mod, :init_table, []))
    Enum.each(data, &MnesiaStore.put/1)
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
