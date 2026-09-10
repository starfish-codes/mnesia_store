defmodule MnesiaStore.StartupTest do
  use MnesiaStore.ClusterCase, async: false

  alias MnesiaStore.{Coordinator, TestCluster}

  test "all four resources survive two successive node replacements with one join per node" do
    {a, an} = peer(:rolling_a)
    start_store(a)

    for resource <- TestCluster.resources() do
      assert :ok = call(a, resource, :put, [:before_roll, resource])
    end

    {b, bn} = peer(:rolling_b)
    call(b, :erlang, :trace_pattern, [{:mnesia, :change_config, 2}, true, [:call_count]])
    start_store(b, nodes: [an])

    for resource <- TestCluster.resources() do
      assert {:ok, ^resource} = call(b, resource, :fetch, [:before_roll])
      assert :ignore = call(b, resource, :init_table)
      assert :ok = call(a, resource, :put, [:after_copy, resource])
    end

    assert {:call_count, 1} =
             call(b, :erlang, :trace_info, [{:mnesia, :change_config, 2}, :call_count])

    :ok = :peer.stop(a)

    {c, _cn} = peer(:rolling_c)
    start_store(c, nodes: [bn])
    :ok = :peer.stop(b)

    for resource <- TestCluster.resources() do
      assert {:ok, ^resource} = call(c, resource, :fetch, [:before_roll])
      assert {:ok, ^resource} = call(c, resource, :fetch, [:after_copy])
    end
  end

  test "a blocked initial join leaves the coordinator responsive and readiness false" do
    {a, an} = peer(:blocked_a)
    start_store(a)
    {b, _bn} = peer(:blocked_b)
    call(a, :sys, :suspend, [:mnesia_controller])
    assert :ok = call(b, TestCluster, :start_store, [[nodes: [an]]])
    eventually(fn -> call(b, MnesiaStore, :status).phase == :joining end)
    refute call(b, MnesiaStore, :ready?)
    assert call(a, MnesiaStore, :ready?)
    assert %{phase: :admitting} = call(a, MnesiaStore, :status)
    assert :ok = call(a, TestCluster.First, :put, [:while_joining, :value])

    assert {:error, {:store_unavailable, :joining}} =
             call(b, TestCluster.First, :put, [:key, :value])

    call(a, :sys, :resume, [:mnesia_controller])
    assert :ok = call(b, MnesiaStore, :await_ready, [10_000])
    assert {:ok, :value} = call(b, TestCluster.First, :fetch, [:while_joining])
  end

  test "discovery waits for a visible seed to become ready without creating local tables" do
    {a, an} = peer(:seed_a)
    {b, _bn} = peer(:seed_b)
    call(b, :erlang, :trace_pattern, [{:mnesia, :change_config, 2}, true, [:call_count]])

    assert :ok =
             call(b, TestCluster, :start_store, [
               [nodes: [an], discovery_timeout: 2_000]
             ])

    assert %{phase: :booting, working: true, last_error: nil} = call(b, MnesiaStore, :status)
    refute call(b, MnesiaStore, :ready?)
    assert [:schema] = call(b, :mnesia, :system_info, [:tables])
    start_store(a)
    eventually(fn -> call(b, MnesiaStore, :ready?) end)

    assert {:call_count, 1} =
             call(b, :erlang, :trace_info, [{:mnesia, :change_config, 2}, :call_count])
  end

  test "the first node creates a local database after the discovery window expires" do
    {a, an} = peer(:first_node)
    call(a, :erlang, :trace_pattern, [{:mnesia, :change_config, 2}, true, [:call_count]])
    started = System.monotonic_time(:millisecond)
    assert :ok = call(a, TestCluster, :start_store, [[discovery_timeout: 300]])
    refute call(a, MnesiaStore, :ready?)
    assert [:schema] = call(a, :mnesia, :system_info, [:tables])

    assert {:error, {:store_unavailable, :booting}} =
             call(a, TestCluster.First, :put, [:early, :value])

    assert :ok = call(a, MnesiaStore, :await_ready, [2_000])
    assert System.monotonic_time(:millisecond) - started >= 300
    assert running(a) == [an]
    assert :ok = call(a, TestCluster.First, :put, [:local, :value])
    assert {:ok, :value} = call(a, TestCluster.First, :fetch, [:local])

    assert {:call_count, 0} =
             call(a, :erlang, :trace_info, [{:mnesia, :change_config, 2}, :call_count])
  end

  test "discovery rereads the nodes callback and copies a seed found during the window" do
    {a, an} = peer(:discovered_a)
    {b, bn} = peer(:discovered_b)
    start_store(a)
    assert :ok = call(a, TestCluster.First, :put, [:existing, :value])

    assert :ok =
             call(b, TestCluster, :start_store, [
               [nodes: &Node.list/0, discovery_timeout: 5_000]
             ])

    refute call(b, MnesiaStore, :ready?)
    assert [:schema] = call(b, :mnesia, :system_info, [:tables])
    assert true = call(b, Node, :connect, [an])
    assert :ok = call(b, MnesiaStore, :await_ready, [2_000])
    assert running(b) == Enum.sort([an, bn])
    assert {:ok, :value} = call(b, TestCluster.First, :fetch, [:existing])
  end

  test "unresponsive seed probes are bounded by discovery rather than the RPC timeout" do
    {a, an} = peer(:unresponsive_a)
    {b, bn} = peer(:unresponsive_b)
    {c, cn} = peer(:unresponsive_c)
    start_store(a)
    start_store(b)
    call(a, :sys, :suspend, [Coordinator])
    call(b, :sys, :suspend, [Coordinator])

    assert :ok =
             call(c, TestCluster, :start_store, [
               [nodes: [an, bn], discovery_timeout: 300, rpc_timeout: 10_000]
             ])

    assert :ok = call(c, MnesiaStore, :await_ready, [1_500])
    assert running(c) == [cn]
    call(a, :sys, :resume, [Coordinator])
    call(b, :sys, :resume, [Coordinator])
    assert running(a) == [an]
    assert running(b) == [bn]
  end
end
