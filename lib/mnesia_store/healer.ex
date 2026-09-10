defmodule MnesiaStore.Healer do
  @moduledoc false

  # Reconciles a table whose schema diverged between nodes that can see each
  # other (independently created copies have different cookies and cannot be
  # merged). Nodes sharing a cookie form a group; the largest group wins, ties
  # go to the group holding the lexically smallest node name. Only a loser
  # acts, and only on itself: it drops its copy, rejoins the cluster and writes
  # its rows back without overwriting the winner's. Peers are never touched.

  use GenServer

  require Logger
  require Record

  Record.defrecordp(:cstruct, Record.extract(:cstruct, from_lib: "mnesia/src/mnesia.hrl"))

  @timeout :timer.minutes(5)
  @retry :timer.seconds(30)

  @spec start_link(module()) :: GenServer.on_start()
  def start_link(resource_mod), do: GenServer.start_link(__MODULE__, resource_mod)

  @impl GenServer
  def init(resource_mod) do
    send(self(), :check)
    {:ok, resource_mod}
  end

  @impl GenServer
  def handle_info(:check, resource_mod) do
    resource_mod
    |> perform_check()
    |> schedule_check()

    {:noreply, resource_mod}
  end

  # Returns the delay until the next check.
  defp perform_check(resource_mod) do
    if resource_mod in :mnesia.system_info(:local_tables) do
      if loser?(resource_mod), do: rejoin(resource_mod)
      period()
    else
      # No local copy: the boot-time init_table failed or could not add the
      # copy. Try again soon rather than on the regular schedule.
      resource_mod.init_table()
      @retry
    end
  end

  defp loser?(resource_mod) do
    {:ok, local_cookie} = cookie(node(), resource_mod)

    peers =
      for peer <- Node.list(:visible),
          {:ok, peer_cookie} <- [cookie(peer, resource_mod)],
          do: {peer, peer_cookie}

    local_cookie != winner_cookie([{node(), local_cookie} | peers])
  end

  # Largest group of nodes sharing a cookie wins; ties go to the group holding
  # the lexically smallest node name.
  defp winner_cookie(node_cookies) do
    {cookie, _nodes} =
      node_cookies
      |> Enum.group_by(fn {_node, cookie} -> cookie end, fn {node, _cookie} -> node end)
      |> Enum.min_by(fn {_cookie, nodes} -> {-length(nodes), Enum.min(nodes)} end)

    cookie
  end

  defp cookie(node, resource_mod) do
    cstruct(cookie: cookie) = :erpc.call(node, :mnesia_lib, :val, [{resource_mod, :cstruct}])
    {:ok, cookie}
  catch
    # The peer is unreachable or does not know the table.
    _class, _reason -> :error
  end

  defp rejoin(resource_mod) do
    Logger.warning(
      "Table [#{resource_mod}] diverged from the cluster; dropping the local copy and rejoining"
    )

    with {:ok, records} <- resource_mod.all(),
         :ok <- resource_mod.delete_table() do
      resource_mod.init_table()
      Enum.each(records, &MnesiaStore.put_new/1)
    else
      {:error, reason} ->
        Logger.error("Could not rejoin [#{resource_mod}]: " <> inspect(reason))
    end
  end

  defp schedule_check(delay), do: Process.send_after(self(), :check, delay)

  defp period do
    jitter =
      1
      |> :timer.minutes()
      |> :rand.uniform()

    @timeout + jitter
  end
end
