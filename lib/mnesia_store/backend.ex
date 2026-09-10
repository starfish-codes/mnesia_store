defmodule MnesiaStore.Backend do
  @moduledoc false

  alias MnesiaStore.{Coordinator, Table}

  # Every RPC, including a delayed RPC from an abandoned operation, must acquire
  # permission from the current coordinator before touching Mnesia.
  @spec execute(reference(), term()) :: :ok | {:ok, term()} | {:error, term()}
  def execute(token, action) do
    with {:ok, reference} <- Coordinator.checkout(token) do
      try do
        perform(action)
      after
        Coordinator.checkin(reference)
      end
    end
  end

  defp perform(:describe) do
    {:ok, Table.describe()}
  end

  defp perform({:ensure, definitions, timeout}) do
    Enum.reduce_while(definitions, :ok, fn {name, attributes}, :ok ->
      case Table.ensure(name, attributes, timeout) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp perform({:join, seed}) do
    with {:ok, connected} <- :mnesia.change_config(:extra_db_nodes, [seed]) do
      require_seed(connected, seed)
    end
  end

  defp perform(:snapshot) do
    tables = Map.keys(Table.describe().tables)

    transaction(fn ->
      Map.new(tables, fn table ->
        records = :mnesia.foldl(fn record, acc -> [record | acc] end, [], table)
        {table, Map.new(records, &{elem(&1, 1), &1})}
      end)
    end)
  end

  defp perform({:import, snapshot}) do
    transaction(fn ->
      Enum.each(snapshot, fn {_table, records} -> write_records(records) end)
    end)
  end

  defp perform(:stop) do
    case :mnesia.stop() do
      :stopped -> :ok
      error -> {:error, error}
    end
  end

  defp perform(:start_empty) do
    # Explicit RAM mode ignores any disk schema. No distributed delete_table or
    # filesystem deletion: the source's records have already been transferred.
    Application.put_env(:mnesia, :schema_location, :ram)
    Application.put_env(:mnesia, :extra_db_nodes, [])

    with :ok <- :mnesia.start() do
      require_empty_schema()
    end
  end

  defp require_seed(connected, seed) do
    if seed in connected do
      :ok
    else
      {:error, {:seed_unavailable, seed}}
    end
  end

  defp require_empty_schema do
    if :mnesia.system_info(:tables) == [:schema] do
      :ok
    else
      {:error, :schema_not_empty}
    end
  end

  defp write_records(records) do
    Enum.each(records, fn {_key, record} -> :mnesia.write(record) end)
  end

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end
end
