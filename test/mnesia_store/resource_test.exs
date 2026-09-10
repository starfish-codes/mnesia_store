defmodule MnesiaStore.ResourceTest do
  use ExUnit.Case, async: false

  alias MnesiaStore.ResourceFixtures.{
    AfterExpireCallback,
    BeforeExpireCallback,
    Session,
    SessionNoCleaner
  }

  setup do
    # Each test owns a fresh RAM database, independent of legacy API tests.
    :stopped = :mnesia.stop()
    :ok = :mnesia.start()

    start_supervised!(
      {MnesiaStore.Supervisor,
       resources: [Session, SessionNoCleaner, BeforeExpireCallback, AfterExpireCallback],
       nodes: [],
       discovery_timeout: 0,
       check_interval: :infinity}
    )

    assert :ok = MnesiaStore.await_ready()
    :ok
  end

  describe "resource API" do
    setup do
      sup = Process.whereis(Session)
      %{sup: sup}
    end

    test "inspect supervisor", %{sup: sup} do
      assert [
               {Session.Cleaner, cleaner, :worker, _cleaner_modules}
             ] = Supervisor.which_children(sup)

      assert Process.alive?(cleaner)
    end

    test "put/fetch/delete" do
      key = "some-unique-key"
      value = %{foo: :bar}

      assert {:error, :empty_key} = Session.put(nil, value)

      assert :ok = Session.put(key, value)
      assert {:ok, ^value} = Session.fetch(key)

      assert :ok = Session.delete(key)
      assert {:error, :not_found} = Session.fetch(key)
    end

    test "expired/0" do
      key = "expired-key"
      value = %{foo: :bar}
      :ok = Session.put_expired(key, value)
      assert {:ok, ^value} = Session.fetch(key)
      assert :ok = MnesiaStore.Resource.evict_expired(Session)
      assert {:error, :not_found} = Session.fetch(key), "Removes expired records"
    end
  end

  test "can be started without cleaner" do
    sup = Process.whereis(SessionNoCleaner)

    assert [] = Supervisor.which_children(sup)
  end

  describe "before_expire callback" do
    test "calls before_expire before expiration" do
      BeforeExpireCallback.put_expired(:foo, {self(), :ok})
      BeforeExpireCallback.put_expired(:bar, {self(), :skip})

      MnesiaStore.Resource.evict_expired(BeforeExpireCallback)

      assert_received {:before_expire_called, :foo}
      assert_received {:before_expire_called, :bar}

      assert {:error, :not_found} = BeforeExpireCallback.fetch(:foo)
      assert {:ok, _found} = BeforeExpireCallback.fetch(:bar)
    end
  end

  describe "after_expire callback" do
    test "calls after_expire after expiration" do
      AfterExpireCallback.put_expired(:foo, :bar)
      MnesiaStore.Resource.evict_expired(AfterExpireCallback)
      assert_received {:after_expire_called, :foo}
      assert {:error, :not_found} = AfterExpireCallback.fetch(:foo)
    end
  end
end
