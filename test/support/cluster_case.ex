defmodule MnesiaStore.ClusterCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias MnesiaStore.TestCluster

  using do
    quote do
      import MnesiaStore.ClusterCase
    end
  end

  @spec peer(atom()) :: {pid(), node()}
  def peer(label) do
    {:ok, pid, name} =
      :peer.start(%{
        name: :peer.random_name(label),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"+S", ~c"2"]
      })

    on_exit(fn ->
      if Process.alive?(pid) do
        :peer.stop(pid)
      end
    end)

    :ok = :peer.call(pid, :code, :add_paths, [:code.get_path()])
    :ok = :peer.call(pid, Application, :put_env, [:mnesia, :schema_location, :ram])
    {:ok, _applications} = :peer.call(pid, Application, :ensure_all_started, [:mnesia_store])
    {pid, name}
  end

  @spec start_store(pid(), keyword()) :: :ok
  def start_store(pid, opts \\ []) do
    assert :ok = call(pid, TestCluster, :start_store, [opts])
    assert :ok = call(pid, MnesiaStore, :await_ready, [10_000])
  end

  @spec call(pid(), module(), atom(), [term()]) :: term()
  def call(pid, module, function, args \\ []) do
    :peer.call(pid, module, function, args, 15_000)
  end

  @spec eventually((-> boolean()), non_neg_integer()) :: :ok
  def eventually(fun, attempts \\ 500)

  def eventually(fun, 0) do
    assert(fun.())
    :ok
  end

  def eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  @spec idle(pid()) :: :ok
  def idle(pid) do
    eventually(fn -> not call(pid, MnesiaStore, :status).working end)
  end

  @spec generation(pid()) :: pid() | nil
  def generation(pid) do
    call(pid, Process, :whereis, [:mnesia_controller])
  end

  @spec running(pid()) :: [node()]
  def running(pid) do
    pid
    |> call(:mnesia, :system_info, [:running_db_nodes])
    |> Enum.sort()
  end
end
