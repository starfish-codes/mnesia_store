defmodule MnesiaStore.HealerTest do
  use ExUnit.Case, async: false

  alias MnesiaStore.TestResource

  defmodule MissingCopy do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  describe "missing local copy" do
    test "adds a copy of a table that is in the schema but not on this node" do
      [peer] = HayCluster.start_nodes(:mnesia_copy, 1, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes([peer]) end)

      opts = [ram_copies: [peer], attributes: ~w[key value expires_at]a]
      {:atomic, :ok} = :erpc.call(peer, :mnesia, :create_table, [MissingCopy, opts])
      {:ok, _nodes} = :mnesia.change_config(:extra_db_nodes, [peer])

      assert MissingCopy in :mnesia.system_info(:tables)
      refute MissingCopy in :mnesia.system_info(:local_tables)

      pid = start_link_supervised!({MnesiaStore.Healer, MissingCopy})
      assert MissingCopy = :sys.get_state(pid)

      assert MissingCopy in :mnesia.system_info(:local_tables)
    end
  end

  describe "healing" do
    @attrs ~w[key value expires_at]a

    test "a lone node rejoins the larger group and keeps its rows" do
      {TestResource.Healer, pid, :worker, [MnesiaStore.Healer]} =
        TestResource
        |> start_link_supervised!()
        |> Supervisor.which_children()
        |> List.keyfind!(TestResource.Healer, 0)

      # Mnesia on this node persists across tests.
      {:atomic, :ok} = :mnesia.clear_table(TestResource)
      assert :ok = TestResource.put(:apple, 1)
      assert :ok = TestResource.put(:banana, 2)

      # Two peers share one independently created copy: they form the larger group.
      nodes = [node1, node2] = HayCluster.start_nodes(:mnesia_store, 2, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes(nodes) end)
      {:ok, _nodes} = :erpc.call(node1, :mnesia, :change_config, [:extra_db_nodes, [node2]])
      opts = [ram_copies: nodes, attributes: @attrs]
      {:atomic, :ok} = :erpc.call(node1, :mnesia, :create_table, [TestResource, opts])
      :ok = :erpc.call(node1, TestResource, :put, [:cherry, 3])
      :ok = :erpc.call(node2, TestResource, :put, [:banana, :from_winner])

      send(pid, :check)
      assert TestResource = :sys.get_state(pid)

      assert node() in :mnesia.table_info(TestResource, :ram_copies)
      assert node1 in :mnesia.table_info(TestResource, :ram_copies)

      assert {:ok, records} = TestResource.all()

      assert [
               {TestResource, :apple, 1, _apple_expires_at},
               {TestResource, :banana, :from_winner, _banana_expires_at},
               {TestResource, :cherry, 3, _cherry_expires_at}
             ] = Enum.sort(records),
             "loser's rows are added, the winner's row is kept on conflict"
    end

    test "the winner leaves a divergent peer alone" do
      {TestResource.Healer, pid, :worker, [MnesiaStore.Healer]} =
        TestResource
        |> start_link_supervised!()
        |> Supervisor.which_children()
        |> List.keyfind!(TestResource.Healer, 0)

      # Mnesia on this node persists across tests.
      {:atomic, :ok} = :mnesia.clear_table(TestResource)
      assert :ok = TestResource.put(:apple, 1)

      # One peer with its own copy: a 1-vs-1 tie, won by the smaller node name.
      [peer] = HayCluster.start_nodes(:mnesia_store, 1, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes([peer]) end)
      assert node() < peer
      opts = [ram_copies: [peer], attributes: @attrs]
      {:atomic, :ok} = :erpc.call(peer, :mnesia, :create_table, [TestResource, opts])
      :ok = :erpc.call(peer, TestResource, :put, [:cherry, 3])

      send(pid, :check)
      assert TestResource = :sys.get_state(pid)

      assert {:ok, [{TestResource, :apple, 1, _apple_expires_at}]} = TestResource.all()

      assert {:ok, [{TestResource, :cherry, 3, _cherry_expires_at}]} =
               :erpc.call(peer, TestResource, :all, [])

      assert [^peer] = :erpc.call(peer, :mnesia, :table_info, [TestResource, :ram_copies])
    end
  end
end
