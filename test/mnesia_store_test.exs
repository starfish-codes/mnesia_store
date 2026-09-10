defmodule MnesiaStoreTest do
  use ExUnit.Case, async: false

  describe "distrubuted storage" do
    setup do
      nodes = HayCluster.start_nodes(:mnesia_store, 2, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes(nodes) end)

      tab_name = :person
      attrs = ~w[name age gender]a
      :erpc.multicall(nodes, MnesiaStore, :init_table, [tab_name, attrs])

      %{nodes: nodes, tab_name: tab_name, attrs: attrs}
    end

    test "can put on one node and fetch from the other one", %{
      nodes: [node1, node2],
      tab_name: tab_name,
      attrs: attrs
    } do
      person1 = {tab_name, "bob", 27, :male}

      assert :ok = :erpc.call(node1, MnesiaStore, :put, [person1])
      assert {:ok, ^person1} = :erpc.call(node1, MnesiaStore, :fetch, [tab_name, "bob"])
      assert {:ok, ^person1} = :erpc.call(node2, MnesiaStore, :fetch, [tab_name, "bob"])

      [node3] = HayCluster.start_nodes(:mnesia_extra, 1, applications: [:mnesia])
      assert :ok = :erpc.call(node3, MnesiaStore, :init_table, [tab_name, attrs])
      person2 = {tab_name, "alice", 47, :female}

      :ok = :erpc.call(node3, MnesiaStore, :put, [person2])
      HayCluster.stop_nodes([node3])

      assert {:ok, ^person2} = :erpc.call(node2, MnesiaStore, :fetch, [tab_name, "alice"]),
             "Keeps the data even if the original node is off"

      assert :ok = :erpc.call(node1, MnesiaStore, :remove, [tab_name, "alice"])
      assert {:error, :not_found} = :erpc.call(node2, MnesiaStore, :fetch, [tab_name, "alice"])
    end
  end

  describe "cluster join" do
    test "starts the table locally when a peer never completes the schema merge" do
      # A peer whose mnesia_controller does not answer makes
      # :mnesia.change_config(:extra_db_nodes, _) block inside the schema merge.
      [peer] = HayCluster.start_nodes(:mnesia_stuck, 1, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes([peer]) end)
      :ok = :erpc.call(peer, :sys, :suspend, [:mnesia_controller])

      tab_name = :stuck_peer
      assert :ok = MnesiaStore.init_table(tab_name, ~w[name age]a)

      assert [node()] == :mnesia.table_info(tab_name, :ram_copies)
      assert :ok = MnesiaStore.put({tab_name, "bob", 27})
      assert {:ok, {^tab_name, "bob", 27}} = MnesiaStore.fetch(tab_name, "bob")
    end

    test "comes up when peers hold divergent schemas of the table" do
      # Two peers created the table independently, so their
      # schema cookies conflict and the merge with the second peer fails.
      nodes = HayCluster.start_nodes(:mnesia_split, 2, applications: [:mnesia])
      on_exit(fn -> HayCluster.stop_nodes(nodes) end)

      tab_name = :split_brain
      attrs = ~w[name age]a

      for remote_node <- nodes do
        opts = [ram_copies: [remote_node], attributes: attrs]
        {:atomic, :ok} = :erpc.call(remote_node, :mnesia, :create_table, [tab_name, opts])
      end

      assert :ok = MnesiaStore.init_table(tab_name, attrs)

      assert node() in :mnesia.table_info(tab_name, :ram_copies)
      assert :ok = MnesiaStore.put({tab_name, "alice", 47})
      assert {:ok, {^tab_name, "alice", 47}} = MnesiaStore.fetch(tab_name, "alice")
    end
  end

  describe "search" do
    setup do
      attrs = ~w[name calories price group]a
      :ok = MnesiaStore.init_table(:food, attrs)
      :ok = MnesiaStore.put({:food, :salmon, 88, 4.00, :meat})
      :ok = MnesiaStore.put({:food, :cereals, 178, 2.79, :bread})
      :ok = MnesiaStore.put({:food, :milk, 150, 3.23, :dairy})
      :ok = MnesiaStore.put({:food, :cake, 650, 7.21, :delicious})
      :ok = MnesiaStore.put({:food, :bacon, 800, 6.32, :meat})
      :ok = MnesiaStore.put({:food, :sandwich, 550, 5.78, :whatever})
    end

    test "match/1" do
      assert {:ok, []} = MnesiaStore.match({:food, :_, :_, :_, :veggie})
      assert {:ok, records} = MnesiaStore.match({:food, :_, :_, :_, :meat})

      assert [
               {:food, :bacon, 800, 6.32, :meat},
               {:food, :salmon, 88, 4.00, :meat}
             ] = Enum.sort(records)
    end

    test "match_one/1" do
      assert {:error, :not_found} = MnesiaStore.match_one({:food, :_, :_, :_, :veggie})
      assert {:ok, sandwich} = MnesiaStore.match_one({:food, :_, :_, :_, :whatever})
      assert {:food, :sandwich, 550, 5.78, :whatever} = sandwich
    end

    test "select/2" do
      spec = [
        {
          {:"$1", :"$2", :"$3", :"$4", :"$5"},
          [
            {:andalso, {:>, :"$3", 80}, {:<, :"$3", 500}},
            {:orelse, {:==, :"$5", :meat}, {:==, :"$5", :dairy}}
          ],
          [:"$2"]
        }
      ]

      {:ok, result} = MnesiaStore.select(:food, spec)
      assert [:milk, :salmon] = Enum.sort(result)
    end
  end
end
