defmodule MnesiaStore do
  @moduledoc """
  Provides ability to create/add_table_copy ram-copy mnesia tables.
  """

  require Logger

  @spec init_table(atom(), [atom()]) :: :ok | {:error, term()}
  def init_table(tab_name, attributes) do
    nodes = db_nodes()
    {:ok, nodes_alive} = :mnesia.change_config(:extra_db_nodes, nodes)
    nodes_alive_list = Enum.join(nodes_alive, ", ")
    Logger.info("Change mnesia config. Nodes alive are: [#{nodes_alive_list}]")
    create_table(tab_name, attributes, nodes)
  end

  @spec put(tuple()) :: :ok | {:error, term()}
  def put(record), do: transaction(fn -> :mnesia.write(record) end)

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
