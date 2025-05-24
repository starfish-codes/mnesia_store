defmodule MnesiaStore.HealerTest do
  use ExUnit.Case, async: false

  alias MnesiaStore.TestResource

  describe "healing" do
    test "recreates the table if cookie on other node doesn't match" do
      {TestResource.Healer, pid, :worker, [MnesiaStore.Healer]} =
        TestResource
        |> start_link_supervised!()
        |> Supervisor.which_children()
        |> List.keyfind!(TestResource.Healer, 0)

      assert :ok = TestResource.put(:apple, 1)
      assert :ok = TestResource.put(:banana, 2)

      [remote_node] = nodes = HayCluster.start_nodes(:mnesia_store, 1, applications: [:mnesia])
      opts = [ram_copies: nodes, attributes: ~w[key value expires_at]a]
      {:atomic, :ok} = :erpc.call(remote_node, :mnesia, :create_table, [TestResource, opts])
      :ok = :erpc.call(remote_node, TestResource, :put, [:cherry, 3])
      :ok = :erpc.call(remote_node, TestResource, :put, [:date, 4])

      assert {:ok, records} = TestResource.all()

      assert [
               {TestResource, :apple, 1, _apple_expires_at},
               {TestResource, :banana, 2, _banana_expires_at}
             ] = Enum.sort(records)

      send(pid, :check)
      assert TestResource = :sys.get_state(pid)

      assert {:ok, records} = TestResource.all()

      assert [
               {TestResource, :apple, 1, _apple_expires_at},
               {TestResource, :banana, 2, _banana_expires_at},
               {TestResource, :cherry, 3, _cherry_expires_at},
               {TestResource, :date, 4, _date_expires_at}
             ] = Enum.sort(records)

      HayCluster.stop_nodes(nodes)
    end
  end
end
