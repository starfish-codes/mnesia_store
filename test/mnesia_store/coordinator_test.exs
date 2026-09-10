defmodule MnesiaStore.CoordinatorTest do
  use MnesiaStore.ClusterCase, async: false

  alias MnesiaStore.{Coordinator, TestCluster}

  test "a queued checkout cannot access a replacement database before the controller DOWN" do
    {a, _an} = peer(:queued_checkout)
    start_store(a)
    idle(a)
    coordinator = call(a, Process, :whereis, [Coordinator])
    call(a, :sys, :suspend, [coordinator])
    pending = Task.async(fn -> call(a, Coordinator, :checkout) end)

    eventually(fn ->
      {:messages, messages} = call(a, Process, :info, [coordinator, :messages])

      Enum.any?(messages, fn
        {:"$gen_call", _from, {:checkout, :client}} -> true
        _message -> false
      end)
    end)

    assert :stopped = call(a, :mnesia, :stop)
    assert :ok = call(a, :mnesia, :start)
    call(a, :sys, :resume, [coordinator])
    assert {:error, {:store_unavailable, :failed}} = Task.await(pending)
    refute call(a, MnesiaStore, :ready?)
  end

  test "a caller death finishes draining and a pre-mutation cancellation reopens access" do
    {a, _an} = peer(:drain_caller)
    start_store(a)
    token = make_ref()
    owner = self()
    call(a, :erlang, :spawn, [TestCluster, :hold_access, [owner]])
    assert_receive {:entered, caller}, 2_000
    reservation = Task.async(fn -> call(a, Coordinator, :reserve, [token, owner, :heal]) end)
    eventually(fn -> call(a, MnesiaStore, :status).phase == :draining end)
    refute call(a, MnesiaStore, :ready?)
    call(a, Process, :exit, [caller, :kill])
    assert :ok = Task.await(reservation)
    assert %{phase: :healing} = call(a, MnesiaStore, :status)
    assert :ok = call(a, Coordinator, :cancel, [token])
    assert call(a, MnesiaStore, :ready?)
    assert :ok = call(a, TestCluster.First, :put, [:after_cancel, :value])
  end

  test "late reservation messages cannot reopen a failed database" do
    {a, _an} = peer(:failed_lease)
    start_store(a)
    token = make_ref()
    assert :ok = call(a, Coordinator, :reserve, [token, self(), :admit])
    assert :stopped = call(a, :mnesia, :stop)
    assert %{phase: :failed} = call(a, MnesiaStore, :status)
    assert {:error, :stale_operation} = call(a, Coordinator, :finish, [token])
    assert {:error, :stale_operation} = call(a, Coordinator, :commit, [token])
    assert :ok = call(a, Coordinator, :cancel, [token])
    assert {:error, :mnesia_stopped} = call(a, MnesiaStore, :await_ready)
    refute call(a, MnesiaStore, :ready?)
  end

  test "healing drains admitted calls and rejects new calls until the transfer completes" do
    {a, _an} = peer(:barrier_a)
    {b, bn} = peer(:barrier_b)
    start_store(a)
    start_store(b)
    recipient = self()
    caller = Task.async(fn -> call(b, TestCluster, :hold_access, [recipient]) end)
    assert_receive {:entered, remote_caller}, 2_000
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    eventually(fn -> call(b, MnesiaStore, :status).phase == :draining end)

    assert {:error, {:store_unavailable, :draining}} =
             call(b, TestCluster.First, :put, [:during, 1])

    assert call(a, MnesiaStore, :status).working
    send(remote_caller, :release)
    assert :ok = Task.await(caller)
    idle(a)
    assert %{phase: :ready, last_error: nil} = call(a, MnesiaStore, :status)
  end

  test "restarting the coordinator adopts the ready instance without another join" do
    {a, _an} = peer(:restart)
    start_store(a)
    idle(a)
    generation = generation(a)
    coordinator = call(a, Process, :whereis, [Coordinator])
    call(a, Process, :exit, [coordinator, :kill])
    eventually(fn -> call(a, Process, :whereis, [Coordinator]) not in [nil, coordinator] end)
    assert :ok = call(a, MnesiaStore, :await_ready)
    assert generation(a) == generation
    assert %{active: 4} = call(a, DynamicSupervisor, :count_children, [MnesiaStore.Resources])
  end

  test "an export RPC timeout never permits a source reset" do
    {a, _an} = peer(:timeout_a)
    {b, bn} = peer(:timeout_b)
    start_store(a, rpc_timeout: 150)
    start_store(b)
    assert :ok = call(b, TestCluster.First, :put, [:retained, :value])
    ga = generation(a)
    gb = generation(b)
    call(b, :sys, :suspend, [:mnesia_tm])
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    idle(a)
    refute call(a, MnesiaStore, :status).last_error == nil
    assert generation(a) == ga
    assert generation(b) == gb
    call(b, :sys, :resume, [:mnesia_tm])

    assert [{TestCluster.First, :retained, :value, :infinity}] =
             call(b, :mnesia, :dirty_read, [TestCluster.First, :retained])
  end

  test "an unexpected Mnesia restart revokes readiness and does not trigger another join" do
    {a, _an} = peer(:generation)
    start_store(a)
    assert :stopped = call(a, :mnesia, :stop)
    assert :ok = call(a, :mnesia, :start)
    refute call(a, MnesiaStore, :ready?)
    assert %{phase: :failed, last_error: :mnesia_stopped} = call(a, MnesiaStore, :status)

    assert {:error, {:store_unavailable, :failed}} =
             call(a, TestCluster.First, :put, [:key, :value])
  end

  test "a delayed destructive request is rejected after its owner has died" do
    {a, _an} = peer(:fencing)
    start_store(a)
    token = make_ref()
    owner = call(a, :erlang, :spawn, [TestCluster, :wait, []])
    generation = generation(a)
    assert :ok = call(a, Coordinator, :reserve, [token, owner, :heal])
    assert :ok = call(a, Coordinator, :commit, [token])
    call(a, Process, :exit, [owner, :kill])
    eventually(fn -> call(a, MnesiaStore, :status).phase == :failed end)

    assert {:error, {:store_unavailable, :failed}} =
             call(a, MnesiaStore.Backend, :execute, [token, :stop])

    assert generation(a) == generation
  end

  test "a coordinator restart during healing cannot re-admit calls or start a second join" do
    {a, _an} = peer(:interrupted_a)
    {b, bn} = peer(:interrupted_b)
    start_store(a)
    start_store(b)
    ga = generation(a)
    gb = generation(b)
    recipient = self()
    caller = Task.async(fn -> call(b, TestCluster, :hold_access, [recipient]) end)
    assert_receive {:entered, remote_caller}, 2_000
    assert :ok = call(a, MnesiaStore, :heal, [[bn]])
    eventually(fn -> call(b, MnesiaStore, :status).phase == :draining end)
    coordinator = call(a, Process, :whereis, [Coordinator])
    call(a, Process, :exit, [coordinator, :kill])
    eventually(fn -> call(a, Process, :whereis, [Coordinator]) not in [nil, coordinator] end)
    assert %{phase: :failed} = call(a, MnesiaStore, :status)
    send(remote_caller, :release)
    assert :ok = Task.await(caller)
    eventually(fn -> call(b, MnesiaStore, :ready?) end)
    assert generation(a) == ga
    assert generation(b) == gb
    refute call(a, MnesiaStore, :ready?)
  end
end
