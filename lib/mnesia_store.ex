defmodule MnesiaStore do
  @moduledoc """
  Provides ability to create/add_table_copy ram-copy mnesia tables.
  """

  require Logger

  @spec init_mnesia_table(atom(), [atom()]) :: :ok | {:error, term()}
  def init_mnesia_table(tab_name, attributes) do
    nodes = db_nodes()
    {:ok, nodes_alive} = :mnesia.change_config(:extra_db_nodes, nodes)
    Logger.debug("Change mnesia config", nodes: nodes_alive)
    create_table(tab_name, attributes, nodes)
  end

  @spec put(tuple()) :: :ok | {:error, term()}
  def put(record) do
    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  @spec fetch(atom(), term()) :: {:ok, term()} | {:error, term()}
  def fetch(tab_name, id) do
    case :mnesia.transaction(fn -> :mnesia.read(tab_name, id) end) do
      {:atomic, []} -> {:error, :not_found}
      {:atomic, [record]} -> {:ok, record}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @spec remove(atom(), term()) :: {:ok, term()} | {:error, term()}
  def remove(tab_name, id) do
    case :mnesia.transaction(fn -> :mnesia.delete(tab_name, id, :write) end) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  @spec select(atom(), :ets.match_spec()) :: term()
  def select(tab_name, spec) do
    case :mnesia.transaction(fn -> :mnesia.select(tab_name, spec) end) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp create_table(tab_name, attributes, nodes) do
    options = [
      {:ram_copies, nodes},
      {:attributes, attributes}
    ]

    case :mnesia.create_table(tab_name, options) do
      {:atomic, :ok} ->
        Logger.info("Table [#{tab_name}] was successfully created", tab_name: tab_name)

      {:aborted, {:already_exists, ^tab_name}} ->
        add_table_copy(tab_name)
    end
  end

  defp add_table_copy(tab_name) do
    :mnesia.wait_for_tables([tab_name], :timer.seconds(10))

    case :mnesia.add_table_copy(tab_name, node(), :ram_copies) do
      {:atomic, :ok} ->
        Logger.info("Copy of [#{tab_name}] was successfully added to current node",
          tab_name: tab_name
        )

      {:aborted, {:already_exists, ^tab_name, _node}} ->
        Logger.info("Copy of [#{tab_name}] is already added to current node", tab_name: tab_name)

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp db_nodes, do: Node.list(:this) ++ Node.list(:visible)
end
