defmodule MnesiaStore.ResourceFixtures do
  @moduledoc false

  defmodule Session do
    @moduledoc false
    use MnesiaStore.Resource, record_name: :session

    @spec put_expired(String.t(), term()) :: :ok
    def put_expired(key, value) do
      expires_at = DateTime.to_unix(DateTime.utc_now()) - 1

      MnesiaStore.with_access(fn ->
        [key: key, value: value, expires_at: expires_at]
        |> session()
        |> MnesiaStore.put()
      end)
    end
  end

  defmodule SessionNoCleaner do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  defmodule BeforeExpireCallback do
    @moduledoc false
    use MnesiaStore.Resource, record_name: :session

    @spec put_expired(String.t(), term()) :: :ok
    def put_expired(key, value) do
      expires_at = DateTime.to_unix(DateTime.utc_now()) - 1

      MnesiaStore.with_access(fn ->
        [key: key, value: value, expires_at: expires_at]
        |> session()
        |> MnesiaStore.put()
      end)
    end

    @impl MnesiaStore.Resource
    def before_expire(key) do
      {:ok, {pid, result}} = fetch(key)
      send(pid, {:before_expire_called, key})
      result
    end
  end

  defmodule AfterExpireCallback do
    @moduledoc false
    use MnesiaStore.Resource, record_name: :session

    @spec put_expired(String.t(), term()) :: :ok
    def put_expired(key, value) do
      expires_at = DateTime.to_unix(DateTime.utc_now()) - 1

      MnesiaStore.with_access(fn ->
        [key: key, value: value, expires_at: expires_at]
        |> session()
        |> MnesiaStore.put()
      end)
    end

    @impl MnesiaStore.Resource
    def after_expire(key) do
      send(self(), {:after_expire_called, key})
    end
  end
end
