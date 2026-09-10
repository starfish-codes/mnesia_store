defmodule MnesiaStore.Table do
  @moduledoc false

  @spec ensure(atom(), [atom()], timeout()) :: :ok | {:error, term()}
  def ensure(name, attributes, timeout \\ 10_000) do
    options = [
      ram_copies: [node()],
      attributes: attributes,
      user_properties: [{:mnesia_store, true}]
    ]

    with :ok <- create(name, options),
         :ok <- compatible(name, attributes),
         :ok <- copy(name) do
      loaded([name], timeout)
    end
  end

  @spec loaded([atom()], timeout()) :: :ok | {:error, term()}
  def loaded(tables, timeout) do
    case :mnesia.wait_for_tables(tables, timeout) do
      :ok -> :ok
      other -> {:error, {:tables_unavailable, other}}
    end
  end

  @spec describe() :: map()
  def describe do
    tables = :mnesia.system_info(:tables) -- [:schema]

    running =
      :running_db_nodes
      |> :mnesia.system_info()
      |> Enum.sort()

    %{
      generation: Process.whereis(:mnesia_controller),
      running: running,
      ram_schema:
        :mnesia.table_info(:schema, :storage_type) == :ram_copies and
          :mnesia.table_info(:schema, :disc_copies) == [],
      tables: Map.new(tables, &{&1, definition(&1)})
    }
  end

  @spec owned?(map()) :: boolean()
  def owned?(description) do
    description.ram_schema and
      Enum.all?(description.tables, fn {_table, definition} ->
        definition.owned and definition.ram_only and definition.type == :set
      end)
  end

  defp definition(table) do
    %{
      attributes: :mnesia.table_info(table, :attributes),
      cookie: :mnesia.table_info(table, :cookie),
      type: :mnesia.table_info(table, :type),
      owned: :mnesia.table_info(table, :user_properties)[:mnesia_store] == true,
      ram_only:
        :mnesia.table_info(table, :disc_copies) == [] and
          :mnesia.table_info(table, :disc_only_copies) == [],
      local: :mnesia.table_info(table, :storage_type) == :ram_copies
    }
  end

  defp create(table, options) do
    case :mnesia.create_table(table, options) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp compatible(table, attributes) do
    if :mnesia.table_info(table, :attributes) == attributes and
         :mnesia.table_info(table, :record_name) == table and
         :mnesia.table_info(table, :type) == :set do
      :ok
    else
      {:error, {:incompatible_table, table}}
    end
  end

  defp copy(table) do
    case :mnesia.add_table_copy(table, node(), :ram_copies) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table, _node}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end
end
