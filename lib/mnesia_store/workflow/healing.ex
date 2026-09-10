defmodule MnesiaStore.Workflow.Healing do
  @moduledoc false

  alias MnesiaStore.Coordinator
  alias MnesiaStore.Workflow.{Operation, Reconciliation}

  @spec run([node()], keyword()) :: :ok | {:error, term()}
  def run(requested, opts) do
    Operation.run(fn ->
      nodes = participants(Enum.uniq([node() | requested]), opts)
      Operation.session(nodes, opts, &heal_session(nodes, &1, opts))
    end)
  end

  defp heal_session(nodes, token, opts) do
    descriptions = Map.new(nodes, &{&1, Operation.backend(&1, token, :describe, opts)})
    Reconciliation.validate_membership!(descriptions)
    Enum.each(descriptions, fn {_member, info} -> Reconciliation.require_owned!(info) end)
    Reconciliation.validate_history!(descriptions)

    target = Enum.min(nodes)
    retained = Map.fetch!(descriptions, target).running
    donors = nodes -- retained

    if donors != [] do
      transfer_and_rejoin(nodes, target, donors, descriptions, token, opts)
    end

    Operation.finish(nodes, token, opts)
  end

  defp transfer_and_rejoin(nodes, target, donors, descriptions, token, opts) do
    definitions =
      Enum.reduce(descriptions, %{}, fn {_node, info}, acc ->
        Reconciliation.merge_definitions(acc, Reconciliation.definitions(info))
      end)

    # Resolve every record before changing either database. A conflict in the
    # last table must not destroy or partially merge the preceding tables.
    snapshots = Map.new(nodes, &{&1, Operation.backend(&1, token, :snapshot, opts)})
    merged = Reconciliation.merge_snapshots(target, snapshots, opts)

    Operation.commit(nodes, token, opts)
    Operation.ensure_tables(target, token, definitions, opts)
    Operation.backend(target, token, {:import, merged}, opts)

    # Confirm the complete transfer before stopping any source. A failed or
    # ambiguous RPC leaves admission closed; it never authorizes a reset.
    imported = Operation.backend(target, token, :snapshot, opts)

    if imported != merged do
      Operation.fail(:transfer_verification_failed)
    end

    rejoin_sources(donors, target, token, definitions, opts)
    Enum.each(nodes -- donors, &Operation.ensure_tables(&1, token, definitions, opts))
    verify_replicas(nodes, merged, token, opts)
  end

  defp rejoin_sources(donors, target, token, definitions, opts) do
    # A source can itself be a multi-node Mnesia component. Stop that component
    # before introducing its names into the retained database.
    Enum.each(donors, &Operation.backend(&1, token, :stop, opts))

    Enum.each(donors, fn donor ->
      Operation.backend(donor, token, :start_empty, opts)
      Operation.backend(donor, token, {:join, target}, opts)
      Operation.ensure_tables(donor, token, definitions, opts)
    end)
  end

  defp verify_replicas(nodes, merged, token, opts) do
    Enum.each(nodes, fn member ->
      info = Operation.backend(member, token, :describe, opts)

      if info.running != nodes do
        Operation.fail({:membership_changed, member})
      end

      snapshot = Operation.backend(member, token, :snapshot, opts)

      if snapshot != merged do
        Operation.fail({:replica_verification_failed, member})
      end
    end)
  end

  defp participants(nodes, opts) do
    descriptions = Map.new(nodes, &{&1, Operation.rpc!(&1, Coordinator, :describe, [], opts)})
    running = Enum.flat_map(descriptions, fn {_member, info} -> info.running end)

    expanded = sorted_nodes(nodes ++ running)

    if expanded == Enum.sort(nodes) do
      expanded
    else
      participants(expanded, opts)
    end
  end

  defp sorted_nodes(nodes) do
    nodes
    |> Enum.uniq()
    |> Enum.sort()
  end
end
