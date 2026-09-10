defmodule MnesiaStore.ApiCompatibilityTest do
  use MnesiaStore.ClusterCase, async: false

  alias MnesiaStore.{Coordinator, TestCluster}

  test "the legacy table API works without a coordinator while resources require one" do
    {a, _an} = peer(:legacy)
    assert :ok = call(a, MnesiaStore, :init_table, [:legacy, [:key, :value]])
    assert :ok = call(a, MnesiaStore, :put, [{:legacy, :key, :value}])
    assert {:ok, {:legacy, :key, :value}} = call(a, MnesiaStore, :fetch, [:legacy, :key])
    assert nil == call(a, Process, :whereis, [Coordinator])

    assert {:error, {:coordinator_unavailable, _reason}} =
             call(a, MnesiaStore, :managed_init_table, [
               TestCluster.First,
               [:key, :value, :expires_at]
             ])

    assert {:error, {:coordinator_unavailable, _reason}} =
             call(a, TestCluster.First, :put, [:key, :value])

    assert {:error, :mnesia_store_supervisor_required} =
             call(a, TestCluster.First, :start_link, [[]])

    tables =
      a
      |> call(:mnesia, :system_info, [:tables])
      |> Enum.sort()

    assert [:legacy, :schema] == tables
  end

  test "resource operations never fall back to legacy access when the coordinator disappears" do
    {a, _an} = peer(:missing_coordinator)
    start_store(a)
    idle(a)
    assert :ok = call(a, TestCluster.First, :put, [:key, :value])
    assert :ok = call(a, Supervisor, :terminate_child, [MnesiaStore.Supervisor, Coordinator])

    for {function, args} <- [
          {:init_table, []},
          {:all, []},
          {:fetch, [:key]},
          {:put, [:key, :changed]},
          {:delete, [:key]},
          {:expired, []},
          {:delete_table, []}
        ] do
      assert {:error, {:coordinator_unavailable, _reason}} =
               call(a, TestCluster.First, function, args)
    end

    assert {:error, {:coordinator_unavailable, _reason}} =
             call(a, MnesiaStore.Resource, :evict_expired, [TestCluster.First])

    # The legacy API keeps its original behavior regardless of supervisor state.
    assert {:ok, {TestCluster.First, :key, :value, :infinity}} =
             call(a, MnesiaStore, :fetch, [TestCluster.First, :key])
  end
end
