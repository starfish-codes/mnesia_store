defmodule MnesiaStore.Coordinator.Admission do
  @moduledoc false

  alias MnesiaStore.Coordinator.Lifecycle

  @spec reserve(map(), reference(), pid(), atom(), atom(), term()) :: map()
  def reserve(data, token, owner, purpose, original, waiting) do
    lease = %{
      token: token,
      monitor: Process.monitor(owner),
      purpose: purpose,
      original: original,
      committed: false,
      waiting: waiting
    }

    Lifecycle.remember(:reserved)
    %{data | lease: lease}
  end

  @spec checkout(map(), reference() | :client, pid()) :: {reference(), map()}
  def checkout(data, token, pid) do
    reference = Process.monitor(pid)
    access = %{pid: pid, token: token}
    {reference, %{data | active: Map.put(data.active, reference, access)}}
  end

  @spec checkin(map(), reference()) :: map()
  def checkin(data, reference) do
    Process.demonitor(reference, [:flush])

    %{
      data
      | active: Map.delete(data.active, reference),
        waiters: Map.delete(data.waiters, reference)
    }
  end

  @spec operation_active?(map()) :: boolean()
  def operation_active?(data) do
    Enum.any?(data.active, fn {_reference, access} -> access.token != :client end)
  end

  @spec rollback_state(atom(), map()) :: atom()
  def rollback_state(:failed, _data) do
    :failed
  end

  def rollback_state(_state, data) do
    if data.lease.committed or operation_active?(data) do
      :failed
    else
      data.lease.original
    end
  end

  @spec release(map()) :: {map(), [term()]}
  def release(data) do
    Process.demonitor(data.lease.monitor, [:flush])

    actions =
      if data.lease.waiting do
        [{:reply, data.lease.waiting, {:error, :cancelled}}]
      else
        []
      end

    {%{data | lease: nil}, actions}
  end
end
