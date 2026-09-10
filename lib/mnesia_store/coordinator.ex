defmodule MnesiaStore.Coordinator do
  @moduledoc false

  alias MnesiaStore.Coordinator.Machine

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    :gen_statem.start_link({:local, __MODULE__}, Machine, opts, [])
  end

  @spec status() :: map()
  def status do
    :gen_statem.call(__MODULE__, :status)
  end

  @spec describe() :: {:ok, map()} | {:error, term()}
  def describe do
    :gen_statem.call(__MODULE__, :describe)
  end

  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout) do
    :gen_statem.call(__MODULE__, :await_ready, timeout)
  end

  @spec heal([node()]) :: :ok | {:error, term()}
  def heal(nodes) do
    :gen_statem.call(__MODULE__, {:heal, nodes})
  end

  @spec checkout(reference() | :client) :: {:ok, reference()} | {:error, term()}
  def checkout(token \\ :client) do
    :gen_statem.call(__MODULE__, {:checkout, token})
  end

  @spec checkin(reference()) :: :ok
  def checkin(reference) do
    :gen_statem.call(__MODULE__, {:checkin, reference})
  end

  @spec reserve(reference(), pid(), :bootstrap | :admit | :heal) :: :ok | {:error, term()}
  def reserve(token, owner, purpose) do
    :gen_statem.call(__MODULE__, {:reserve, token, owner, purpose}, :infinity)
  end

  @spec commit(reference()) :: :ok | {:error, term()}
  def commit(token) do
    :gen_statem.call(__MODULE__, {:commit, token})
  end

  @spec finish(reference()) :: :ok | {:error, term()}
  def finish(token) do
    :gen_statem.call(__MODULE__, {:finish, token})
  end

  @spec cancel(reference()) :: :ok | {:error, term()}
  def cancel(token) do
    :gen_statem.call(__MODULE__, {:cancel, token})
  end
end
