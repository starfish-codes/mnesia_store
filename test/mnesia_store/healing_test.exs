defmodule MnesiaStore.HealingTest do
  use MnesiaStore.ClusterCase, async: false

  alias MnesiaStore.TestCluster

  test "four conflicting table cookies heal together without losing either side's records" do
    {a, an} = peer(:healing_a)
    {b, bn} = peer(:healing_b)
    start_store(a)
    start_store(b)

    for resource <- TestCluster.resources() do
      assert :ok = call(a, resource, :put, [:from_a, 1])
      assert :ok = call(b, resource, :put, [:from_b, 2])

      refute call(a, :mnesia, :table_info, [resource, :cookie]) ==
               call(b, :mnesia, :table_info, [resource, :cookie])
    end

    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)
    assert %{phase: :ready, last_error: nil} = call(a, MnesiaStore, :status)
    assert call(b, MnesiaStore, :ready?)
    assert running(a) == Enum.sort([an, bn])
    assert running(b) == Enum.sort([an, bn])

    for resource <- TestCluster.resources(), member <- [a, b] do
      assert {:ok, 1} = call(member, resource, :fetch, [:from_a])
      assert {:ok, 2} = call(member, resource, :fetch, [:from_b])
    end

    :ok = :peer.stop(a)

    for resource <- TestCluster.resources() do
      assert({:ok, 1} = call(b, resource, :fetch, [:from_a]))
    end
  end

  test "a record conflict leaves every source intact and does not restart Mnesia" do
    {a, _an} = peer(:conflict_a)
    {b, bn} = peer(:conflict_b)
    start_store(a)
    start_store(b)
    ga = generation(a)
    gb = generation(b)
    resource = TestCluster.Fourth
    assert :ok = call(a, resource, :put, [:same_key, :a])
    assert :ok = call(b, resource, :put, [:same_key, :b])

    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)

    assert %{phase: :ready, last_error: {:record_conflict, ^resource}} =
             call(a, MnesiaStore, :status)

    assert generation(a) == ga
    assert generation(b) == gb
    assert {:ok, :a} = call(a, resource, :fetch, [:same_key])
    assert {:ok, :b} = call(b, resource, :fetch, [:same_key])
  end

  test "restoring connectivity triggers automatic healing of independent databases" do
    {a, an} = peer(:automatic_a)
    {b, bn} = peer(:automatic_b)
    start_store(a, nodes: &Node.list/0, check_interval: 50)
    start_store(b, nodes: &Node.list/0, check_interval: 50)
    assert :ok = call(a, TestCluster.First, :put, [:from_a, 1])
    assert :ok = call(b, TestCluster.Fourth, :put, [:from_b, 2])
    assert true = call(a, Node, :connect, [bn])

    eventually(fn ->
      call(a, MnesiaStore, :ready?) and call(b, MnesiaStore, :ready?) and
        running(a) == Enum.sort([an, bn]) and running(b) == Enum.sort([an, bn])
    end)

    assert {:ok, 1} = call(b, TestCluster.First, :fetch, [:from_a])
    assert {:ok, 2} = call(a, TestCluster.Fourth, :fetch, [:from_b])
  end

  test "a shared-history partition is reported instead of resurrecting deleted records" do
    {a, an} = peer(:history_a)
    {b, bn} = peer(:history_b)
    start_store(a)
    start_store(b, nodes: [an])
    assert :ok = call(a, TestCluster.First, :put, [:deleted, :value])
    assert true = call(a, Node, :disconnect, [bn])
    eventually(fn -> running(a) == [an] and running(b) == [bn] end)
    assert :ok = call(a, TestCluster.First, :delete, [:deleted])
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)

    assert %{last_error: {:shared_history_requires_reconciliation, _table}} =
             call(a, MnesiaStore, :status)

    assert {:error, :not_found} = call(a, TestCluster.First, :fetch, [:deleted])
    assert {:ok, :value} = call(b, TestCluster.First, :fetch, [:deleted])
  end

  test "healing reserves an entire multi-node source component" do
    {a, an} = peer(:component_a)
    {b, bn} = peer(:component_b)
    {c, cn} = peer(:component_c)
    start_store(a)
    start_store(b)
    start_store(c, nodes: [bn])
    assert :ok = call(a, TestCluster.First, :put, [:from_a, 1])
    assert :ok = call(c, TestCluster.Fourth, :put, [:from_c, 3])
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)
    assert %{phase: :ready, last_error: nil} = call(a, MnesiaStore, :status)

    for member <- [a, b, c] do
      assert running(member) == Enum.sort([an, bn, cn])
      assert {:ok, 1} = call(member, TestCluster.First, :fetch, [:from_a])
      assert {:ok, 3} = call(member, TestCluster.Fourth, :fetch, [:from_c])
    end
  end

  test "simultaneous healing requests cannot reset both databases" do
    {a, an} = peer(:simultaneous_a)
    {b, bn} = peer(:simultaneous_b)
    start_store(a)
    start_store(b)
    assert :ok = call(a, TestCluster.First, :put, [:a, 1])
    assert :ok = call(b, TestCluster.First, :put, [:b, 2])
    ga = generation(a)

    requests = [
      Task.async(fn -> call(a, MnesiaStore, :heal, [[bn]]) end),
      Task.async(fn -> call(b, MnesiaStore, :heal, [[an]]) end)
    ]

    Enum.each(requests, &Task.await/1)

    idle(a)
    idle(b)
    assert generation(a) == ga
    assert running(a) == Enum.sort([an, bn])

    for member <- [a, b] do
      assert {:ok, 1} = call(member, TestCluster.First, :fetch, [:a])
      assert {:ok, 2} = call(member, TestCluster.First, :fetch, [:b])
    end
  end

  test "an application resolver reconciles conflicting records before resetting the source" do
    {a, _an} = peer(:resolver_a)
    {b, bn} = peer(:resolver_b)
    start_store(a, conflict_resolver: {TestCluster, :resolve})
    start_store(b, conflict_resolver: {TestCluster, :resolve})
    assert :ok = call(a, TestCluster.First, :put, [:key, :left])
    assert :ok = call(b, TestCluster.First, :put, [:key, :right])
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)
    assert %{phase: :ready, last_error: nil} = call(a, MnesiaStore, :status)
    assert {:ok, :right} = call(a, TestCluster.First, :fetch, [:key])
    assert {:ok, :right} = call(b, TestCluster.First, :fetch, [:key])
  end

  test "unmanaged tables prevent a database reset" do
    {a, _an} = peer(:unmanaged_a)
    {b, bn} = peer(:unmanaged_b)
    start_store(a)
    start_store(b)
    generation = generation(b)
    assert {:atomic, :ok} = call(b, :mnesia, :create_table, [:foreign, []])
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)
    assert %{last_error: :unmanaged_database} = call(a, MnesiaStore, :status)
    assert generation(b) == generation
    assert :foreign in call(b, :mnesia, :system_info, [:tables])
  end
end
