defmodule MnesiaStore.Workflow do
  @moduledoc false

  alias MnesiaStore.Coordinator
  alias MnesiaStore.Workflow.{Healing, Operation, Reconciliation}

  @spec bootstrap(keyword()) :: :ok | {:error, term()}
  def bootstrap(opts) do
    Operation.run(fn -> bootstrap!(opts) end)
  end

  defp bootstrap!(opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :discovery_timeout, 5_000)
    peers = discover(opts, deadline)

    seed =
      peers
      |> Map.keys()
      |> Enum.min(fn -> nil end)

    members = seed_members(peers, seed)

    nodes =
      [node() | members]
      |> Enum.uniq()
      |> Enum.sort()

    Operation.session(nodes, opts, &bootstrap_session(nodes, seed, &1, opts), :bootstrap)
  end

  defp seed_members(_peers, nil) do
    []
  end

  defp seed_members(peers, seed) do
    Map.fetch!(peers, seed).running
  end

  defp discover(opts, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      discover_peers(opts, deadline, remaining)
    else
      %{}
    end
  end

  defp discover_peers(opts, deadline, remaining) do
    candidates = candidate_nodes(opts) -- [node()]
    timeout = min(remaining, Keyword.get(opts, :rpc_timeout, 10_000))

    # Probe in parallel with one budget for the whole round. An unresponsive
    # coordinator must not cost a full RPC timeout for every candidate.
    replies = :erpc.multicall(candidates, Coordinator, :describe, [], timeout)

    peers =
      for {candidate, {:ok, {:ok, description}}} <- Enum.zip(candidates, replies),
          into: %{} do
        {candidate, description}
      end

    if map_size(peers) > 0 do
      peers
    else
      delay = min(100, max(0, deadline - System.monotonic_time(:millisecond)))
      Process.sleep(delay)
      discover(opts, deadline)
    end
  end

  defp bootstrap_session(nodes, seed, token, opts) do
    local = Operation.backend(node(), token, :describe, opts)

    if map_size(local.tables) != 0 or not local.ram_schema do
      Operation.fail(:schema_not_empty)
    end

    if seed do
      remote = Operation.backend(seed, token, :describe, opts)
      Reconciliation.require_owned!(remote)
    end

    Operation.commit(nodes, token, opts)

    if seed do
      Operation.backend(node(), token, {:join, seed}, opts)
    end

    definitions = bootstrap_definitions(token, opts)
    Operation.ensure_tables(node(), token, definitions, opts)
    Operation.finish(nodes, token, opts)
  end

  defp bootstrap_definitions(token, opts) do
    inherited =
      node()
      |> Operation.backend(token, :describe, opts)
      |> Reconciliation.definitions()

    declared = Keyword.fetch!(opts, :table_definitions)
    Reconciliation.merge_definitions(inherited, declared)
  end

  @spec check(keyword()) :: :ok | {:error, term()}
  def check(opts) do
    peers = available(opts)

    case Map.get(peers, node()) do
      nil ->
        :ok

      local ->
        check_peers(local, Map.keys(peers), opts)
    end
  end

  defp check_peers(local, peer_nodes, opts) do
    foreign = Enum.reject(peer_nodes, &(&1 in local.running))

    if foreign != [] and node() == Enum.min(peer_nodes) do
      heal(peer_nodes, opts)
    else
      :ok
    end
  end

  @spec heal([node()], keyword()) :: :ok | {:error, term()}
  def heal(requested, opts) do
    Healing.run(requested, opts)
  end

  defp candidate_nodes(opts) do
    candidates =
      case Keyword.get(opts, :nodes, fn -> Node.list(:visible) end) do
        fun when is_function(fun, 0) -> fun.()
        nodes -> nodes
      end

    Enum.uniq([node() | candidates])
  end

  defp available(opts) do
    opts
    |> candidate_nodes()
    |> Enum.reduce(%{}, fn candidate, acc ->
      case Operation.safe_rpc(candidate, Coordinator, :describe, [], opts) do
        {:ok, description} -> Map.put(acc, candidate, description)
        _error -> acc
      end
    end)
  end
end
