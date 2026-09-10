defmodule MnesiaStore do
  @moduledoc """
  Provides ability to create/add_table_copy ram-copy mnesia tables.
  """

  require Logger

  @doc "Initializes a table using the legacy per-call cluster join, without a coordinator."
  @spec init_table(atom(), [atom()]) :: :ok | {:error, term()}
  def init_table(tab_name, attributes) do
    nodes = Node.list(:this) ++ Node.list(:visible)
    {:ok, nodes_alive} = :mnesia.change_config(:extra_db_nodes, nodes)
    nodes_alive_list = Enum.join(nodes_alive, ", ")
    Logger.info("Change mnesia config. Nodes alive are: [#{nodes_alive_list}]")
    create_table(tab_name, attributes, nodes)
  end

  @doc "Ensures a local resource table through the coordinator, without joining databases."
  @spec managed_init_table(atom(), [atom()]) :: :ok | {:error, term()}
  def managed_init_table(tab_name, attributes) do
    with_access(fn -> MnesiaStore.Table.ensure(tab_name, attributes) end)
  end

  @doc "True only after the managed database's local replicas are ready."
  @spec ready?() :: boolean()
  def ready? do
    status().phase in [:ready, :admitting]
  end

  @doc "Returns the coordinator phase, worker state and last operation error."
  @spec status() :: map()
  def status do
    MnesiaStore.Coordinator.status()
  catch
    :exit, _reason -> %{phase: :unavailable, working: false, last_error: :coordinator_unavailable}
  end

  @doc "Waits for initial synchronization; use ready?/0 for an HTTP readiness probe."
  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 10_000) do
    MnesiaStore.Coordinator.await_ready(timeout)
  end

  @doc "Requests coordinated healing with the supplied nodes and their running peers."
  @spec heal([node()]) :: :ok | {:error, term()}
  def heal(nodes) do
    MnesiaStore.Coordinator.heal(nodes)
  end

  @doc "Runs a database operation through the managed coordinator's admission barrier."
  @spec with_access((-> result)) :: result | {:error, term()} when result: var
  def with_access(fun) do
    with {:ok, reference} <- MnesiaStore.Coordinator.checkout() do
      try do
        fun.()
      after
        MnesiaStore.Coordinator.checkin(reference)
      end
    end
  catch
    :exit, reason -> {:error, {:coordinator_unavailable, reason}}
  end

  @spec put(tuple()) :: :ok | {:error, term()}
  def put(record) do
    transaction(fn -> :mnesia.write(record) end)
  end

  @spec fetch(atom(), term()) :: {:ok, term()} | {:error, term()}
  def fetch(tab_name, id) do
    one(fn -> :mnesia.read(tab_name, id) end)
  end

  @spec match(term()) :: {:ok, term()} | {:error, term()}
  def match(matcher) do
    transaction(fn -> :mnesia.match_object(matcher) end)
  end

  @spec match_one(term()) :: {:ok, term()} | {:error, term}
  def match_one(matcher) do
    one(fn -> :mnesia.match_object(matcher) end)
  end

  @spec remove(atom(), term()) :: :ok | {:error, term()}
  def remove(tab_name, id) do
    transaction(fn -> :mnesia.delete(tab_name, id, :write) end)
  end

  @spec select(atom(), :ets.match_spec()) :: term()
  def select(tab_name, spec) do
    transaction(fn -> :mnesia.select(tab_name, spec) end)
  end

  @spec all(atom()) :: {:ok, [term()]} | {:error, term()}
  def all(tab_name) do
    transaction(fn ->
      tab_name
      |> :mnesia.all_keys()
      |> Enum.flat_map(fn key -> :mnesia.read(tab_name, key) end)
    end)
  end

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
end
