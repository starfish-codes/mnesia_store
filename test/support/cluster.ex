defmodule MnesiaStore.TestCluster do
  @moduledoc false

  defmodule First do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  defmodule Second do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  defmodule Third do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  defmodule Fourth do
    @moduledoc false
    use MnesiaStore.Resource, expires_in_minutes: false
  end

  @spec resources() :: [module()]
  def resources do
    [First, Second, Third, Fourth]
  end

  @spec start_store(keyword()) :: :ok
  def start_store(opts) do
    defaults = [
      resources: resources(),
      nodes: [],
      discovery_timeout: 100,
      check_interval: :infinity
    ]

    opts = Keyword.merge(defaults, opts)
    {:ok, pid} = MnesiaStore.Supervisor.start_link(opts)
    Process.unlink(pid)
    :ok
  end

  @spec resolve(atom(), tuple(), tuple()) :: {:ok, tuple()}
  def resolve(_table, _left, right) do
    {:ok, right}
  end

  @spec wait() :: :ok
  def wait do
    receive do
      :stop -> :ok
    end
  end

  @spec hold_access(pid()) :: :ok | {:error, term()}
  def hold_access(recipient) do
    MnesiaStore.with_access(fn ->
      send(recipient, {:entered, self()})

      receive do
        :release -> :ok
      end
    end)
  end
end
