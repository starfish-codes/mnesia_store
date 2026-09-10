defmodule MnesiaStore.Workflow.Reconciliation do
  @moduledoc false

  alias MnesiaStore.Workflow.Operation

  @spec validate_membership!(map()) :: :ok
  def validate_membership!(descriptions) do
    members = Map.keys(descriptions)

    Enum.each(descriptions, fn {member, info} ->
      validate_member!(member, info, members, descriptions)
    end)
  end

  defp validate_member!(member, info, members, descriptions) do
    if info.running -- members != [] do
      Operation.fail({:membership_changed, member})
    end

    Enum.each(info.running, fn other ->
      if Map.fetch!(descriptions, other).running != info.running do
        Operation.fail({:asymmetric_membership, member, other})
      end
    end)
  end

  @spec validate_history!(map()) :: [:ok]
  def validate_history!(descriptions) do
    for {_member, info} <- descriptions,
        {other, remote} <- descriptions,
        other not in info.running do
      validate_cookies!(info.tables, remote.tables)
    end
  end

  defp validate_cookies!(local, remote) do
    Enum.each(local, fn {table, definition} ->
      case Map.get(remote, table) do
        %{cookie: cookie} when cookie == definition.cookie ->
          Operation.fail({:shared_history_requires_reconciliation, table})

        _other ->
          :ok
      end
    end)
  end

  @spec require_owned!(map()) :: map()
  def require_owned!(info) do
    if not MnesiaStore.Table.owned?(info) do
      Operation.fail(:unmanaged_database)
    end

    info
  end

  @spec definitions(map()) :: map()
  def definitions(info) do
    Map.new(info.tables, fn {table, definition} -> {table, definition.attributes} end)
  end

  @spec merge_definitions(map(), map()) :: map()
  def merge_definitions(left, right) do
    Map.merge(left, right, fn table, a, b ->
      if a != b do
        Operation.fail({:incompatible_table, table})
      end

      a
    end)
  end

  @spec merge_snapshots(node(), map(), keyword()) :: map()
  def merge_snapshots(target, snapshots, opts) do
    sources = Map.keys(snapshots) -- [target]

    sources
    |> Enum.sort()
    |> Enum.reduce(Map.fetch!(snapshots, target), fn member, acc ->
      Map.merge(acc, Map.fetch!(snapshots, member), &merge_records(&1, &2, &3, opts))
    end)
  end

  defp merge_records(table, current, incoming, opts) do
    Map.merge(current, incoming, fn key, left, right ->
      resolve(table, key, left, right, opts)
    end)
  end

  defp resolve(_table, _key, record, record, _opts) do
    record
  end

  defp resolve(table, key, left, right, opts) do
    case Keyword.get(opts, :conflict_resolver) do
      nil ->
        Operation.fail({:record_conflict, table})

      {module, function} ->
        resolve_record(module, function, table, key, left, right)
    end
  end

  defp resolve_record(module, function, table, key, left, right) do
    case apply(module, function, [table, left, right]) do
      {:ok, record} -> validate_record!(record, table, key, tuple_size(left))
      {:error, reason} -> Operation.fail(reason)
    end
  end

  defp validate_record!(record, table, key, size) do
    if not is_tuple(record) or tuple_size(record) != size or
         elem(record, 0) != table or elem(record, 1) != key do
      Operation.fail({:invalid_resolved_record, table})
    end

    record
  end
end
