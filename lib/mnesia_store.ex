defmodule MnesiaStore do
  @moduledoc """
  Provides ability to create/add_table_copy ram-copy mnesia tables.

  ## Configuration

  * `:join_timeout` - how long `init_table/2` waits for the node to join the
    Mnesia cluster of its visible peers before starting the table locally
    instead. Defaults to 10 seconds.

        config :mnesia_store, join_timeout: :timer.seconds(10)
  """

  require Logger

  @default_join_timeout :timer.seconds(10)

  @spec init_table(atom(), [atom()]) :: :ok | {:error, term()}
  def init_table(tab_name, attributes) do
    nodes = db_nodes()

    result =
      case join_cluster(nodes) do
        {:ok, nodes_alive} ->
          nodes_alive_list = Enum.join(nodes_alive, ", ")
          Logger.info("Change mnesia config. Nodes alive are: [#{nodes_alive_list}]")
          create_table(tab_name, attributes, nodes)

        {:error, reason} ->
          Logger.warning(
            "Could not join mnesia cluster #{inspect(nodes)}: #{inspect(reason)}. " <>
              "Starting [#{tab_name}] on the local node only"
          )

          create_table(tab_name, attributes, [node()])
      end

    log_failure(result, tab_name)
  end

  @spec put(tuple()) :: :ok | {:error, term()}
  def put(record), do: transaction(fn -> :mnesia.write(record) end)

  @doc "Writes the record unless a record with the same key already exists."
  @spec put_new(tuple()) :: :ok | {:error, term()}
  def put_new(record) do
    tab_name = elem(record, 0)
    key = elem(record, 1)

    transaction(fn ->
      case :mnesia.read(tab_name, key) do
        [] -> :mnesia.write(record)
        _existing -> :ok
      end
    end)
  end

  @spec fetch(atom(), term()) :: {:ok, term()} | {:error, term()}
  def fetch(tab_name, id), do: one(fn -> :mnesia.read(tab_name, id) end)

  @spec match(term()) :: {:ok, term()} | {:error, term()}
  def match(matcher), do: transaction(fn -> :mnesia.match_object(matcher) end)

  @spec match_one(term()) :: {:ok, term()} | {:error, term}
  def match_one(matcher), do: one(fn -> :mnesia.match_object(matcher) end)

  @spec remove(atom(), term()) :: :ok | {:error, term()}
  def remove(tab_name, id), do: transaction(fn -> :mnesia.delete(tab_name, id, :write) end)

  @spec select(atom(), :ets.match_spec()) :: term()
  def select(tab_name, spec), do: transaction(fn -> :mnesia.select(tab_name, spec) end)

  @spec all(atom()) :: {:ok, [term()]} | {:error, term()}
  def all(tab_name) do
    transaction(fn ->
      tab_name
      |> :mnesia.all_keys()
      |> Enum.flat_map(fn key -> :mnesia.read(tab_name, key) end)
    end)
  end

  defp log_failure({:error, reason} = error, tab_name) do
    Logger.error("Could not init table [#{tab_name}]: " <> inspect(reason))
    error
  end

  defp log_failure(ok, _tab_name), do: ok

  defp one(f) do
    case :mnesia.transaction(f) do
      {:atomic, []} -> {:error, :not_found}
      {:atomic, [record]} -> {:ok, record}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp transaction(f) do
    case :mnesia.transaction(f) do
      {:atomic, :ok} -> :ok
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  # The schema merge behind `:mnesia.change_config/2` is a transaction that
  # Mnesia retries forever, so the call can block indefinitely when a peer's
  # view of the cluster is inconsistent. Bound it so a supervision tree waiting
  # on us can carry on.
  #
  # A join that never completes means a peer still lists this node among its
  # running db nodes from an earlier merge that was aborted halfway (a node went
  # down mid-merge). Only a nodedown clears that entry on the peer, so drop and
  # re-establish the connections and try once more before giving up.
  defp join_cluster(nodes) do
    case join(nodes) do
      {:error, :timeout} ->
        Logger.warning("Mnesia cluster join timed out; reconnecting to peers and retrying once")
        reconnect(nodes -- [node()])
        join(nodes)

      result ->
        result
    end
  end

  defp join(nodes) do
    task = Task.async(fn -> :mnesia.change_config(:extra_db_nodes, nodes) end)

    case Task.yield(task, join_timeout()) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> abort_join(task)
    end
  end

  defp reconnect(peers) do
    Enum.each(peers, &:erlang.disconnect_node/1)
    Enum.each(peers, &Node.connect/1)
  end

  # `:mnesia.change_config/2` spawns `mnesia_controller:connect_nodes2/3`, which
  # traps exits and runs the merge in a schema transaction whose coordinator is
  # linked to `mnesia_controller` only. Killing just the task would leave both
  # behind, with the merge holding the schema write lock that `create_table`
  # needs next, so stop them explicitly once the task (and its link to us) is gone.
  # Only coordinators spawned by our merge are touched; an unrelated schema
  # transaction running at the same time keeps its coordinator.
  defp abort_join(task) do
    mergers = linked(task.pid, {:mnesia_controller, :connect_nodes2, 3})

    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _not_finished ->
        stop_merge(mergers)
        {:error, :timeout}
    end
  end

  defp stop_merge([]) do
    Logger.error(
      "Mnesia cluster join timed out but no merge process was found to stop; " <>
        "the schema lock may still be held and table creation can block"
    )
  end

  defp stop_merge(mergers) do
    coordinators =
      :mnesia_controller
      |> Process.whereis()
      |> linked({:mnesia_schema, :schema_coordinator, 3})
      |> Enum.filter(fn pid ->
        case :erlang.process_info(pid, :parent) do
          {:parent, parent} -> parent in mergers
          _gone -> false
        end
      end)

    Enum.each(mergers ++ coordinators, &Process.exit(&1, :kill))
  end

  defp linked(nil, _initial_call), do: []

  defp linked(pid, initial_call) do
    case Process.info(pid, :links) do
      {:links, links} ->
        for linked <- links,
            is_pid(linked),
            Process.info(linked, :initial_call) == {:initial_call, initial_call},
            do: linked

      nil ->
        []
    end
  end

  defp join_timeout, do: Application.get_env(:mnesia_store, :join_timeout, @default_join_timeout)

  defp create_table(tab_name, attributes, nodes) do
    options = [
      {:ram_copies, nodes},
      {:attributes, attributes}
    ]

    case :mnesia.create_table(tab_name, options) do
      {:atomic, :ok} ->
        Logger.info("Table [#{tab_name}] was successfully created")

      {:aborted, {:already_exists, ^tab_name}} ->
        add_table_copy(tab_name)

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp add_table_copy(tab_name) do
    :mnesia.wait_for_tables([tab_name], :timer.seconds(10))

    case :mnesia.add_table_copy(tab_name, node(), :ram_copies) do
      {:atomic, :ok} ->
        Logger.info("Copy of [#{tab_name}] was successfully added to current node")

      {:aborted, {:already_exists, ^tab_name, _node}} ->
        Logger.info("Copy of [#{tab_name}] is already added to current node")

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp db_nodes, do: Node.list(:this) ++ Node.list(:visible)
end
