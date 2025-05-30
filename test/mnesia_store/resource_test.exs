defmodule MnesiaStore.ResourceTest do
  use ExUnit.Case, async: false

  defmodule Session do
    use MnesiaStore.Resource, record_name: :session

    @spec put_expired(String.t(), term()) :: :ok
    def put_expired(key, value) do
      expires_at = DateTime.to_unix(DateTime.utc_now()) - 1

      [key: key, value: value, expires_at: expires_at]
      |> session()
      |> MnesiaStore.put()
    end
  end

  defmodule SessionNoCleaner do
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  describe "resource API" do
    setup do
      sup = start_link_supervised!(Session)
      %{sup: sup}
    end

    test "inspect supervisor", %{sup: sup} do
      assert [
               {Session.Healer, healer, :worker, _healer_modules},
               {Session, :undefined, :worker, _resource_modules},
               {Session.Cleaner, cleaner, :worker, _cleaner_modules}
             ] = Supervisor.which_children(sup)

      assert Process.alive?(healer)
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

    test "evict_expired/0" do
      key = "expired-key"
      value = %{foo: :bar}
      :ok = Session.put_expired(key, value)
      assert {:ok, ^value} = Session.fetch(key)
      assert :ok = Session.evict_expired()
      assert {:error, :not_found} = Session.fetch(key), "Removes expired records"
    end
  end

  test "can be started without cleaner" do
    sup = start_link_supervised!(SessionNoCleaner)

    assert [
             {SessionNoCleaner.Healer, _pid, :worker, [MnesiaStore.Healer]},
             {SessionNoCleaner, :undefined, :worker, [SessionNoCleaner]}
           ] = Supervisor.which_children(sup)
  end
end
