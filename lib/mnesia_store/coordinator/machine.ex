defmodule MnesiaStore.Coordinator.Machine do
  @moduledoc false
  @behaviour :gen_statem

  alias MnesiaStore.Coordinator.{Admission, Jobs, Lifecycle}
  alias MnesiaStore.Table

  @typep event_type :: :gen_statem.event_type() | :enter
  @typep result :: :gen_statem.event_handler_result(atom(), map())

  @impl :gen_statem
  def callback_mode do
    [:state_functions, :state_enter]
  end

  @impl :gen_statem
  def init(opts) do
    :net_kernel.monitor_nodes(true)
    {state, data} = Lifecycle.new(opts)
    {:ok, state, data, [{:next_event, :internal, :start}]}
  end

  @spec booting(event_type(), term(), map()) :: result()
  def booting(:internal, :start, data) do
    {:keep_state, Jobs.check(:booting, data)}
  end

  def booting(type, :check, data) when type in [:internal, {:timeout, :check}] do
    {:keep_state, Jobs.check(:booting, data)}
  end

  def booting({:call, from}, {:reserve, token, owner, :bootstrap}, %{lease: nil} = data) do
    reserved = Admission.reserve(data, token, owner, :bootstrap, :booting, nil)
    {:next_state, :joining, reserved, [{:reply, from, :ok}]}
  end

  def booting(type, event, data) do
    common(type, event, :booting, data)
  end

  @spec joining(event_type(), term(), map()) :: result()
  def joining({:call, from}, {:commit, token}, %{lease: %{token: token}} = data) do
    commit(data, from)
  end

  def joining({:call, from}, {:finish, token}, %{lease: %{token: token}} = data) do
    finish(data, from)
  end

  def joining({:call, from}, {:checkout, token}, %{lease: %{token: token}} = data) do
    checkout(data, from, token)
  end

  def joining(type, event, data) do
    common(type, event, :joining, data)
  end

  @spec ready(event_type(), term(), map()) :: result()
  def ready(:enter, _previous, data) do
    activated = Lifecycle.activate(data)
    {notified, actions} = Lifecycle.notify(activated, :ok)
    {:keep_state, notified, actions ++ Jobs.schedule(notified)}
  end

  def ready(type, :check, data) when type in [:internal, {:timeout, :check}] do
    current(data, fn -> {:keep_state, Jobs.check(:ready, data)} end)
  end

  def ready({:call, from}, {:reserve, token, owner, :admit}, %{lease: nil} = data) do
    current(data, fn ->
      reserved = Admission.reserve(data, token, owner, :admit, :ready, nil)
      {:next_state, :admitting, reserved, [{:reply, from, :ok}]}
    end)
  end

  def ready({:call, from}, {:reserve, token, owner, :heal}, %{lease: nil} = data) do
    current(data, fn ->
      reserved = Admission.reserve(data, token, owner, :heal, :ready, from)
      {:next_state, :draining, reserved, [{:next_event, :internal, :drain}]}
    end)
  end

  def ready({:call, from}, {:heal, nodes}, %{task: nil} = data) do
    current(data, fn -> {:keep_state, Jobs.heal(data, nodes), [{:reply, from, :ok}]} end)
  end

  def ready({:call, from}, :describe, data) do
    current(data, fn -> reply(from, {:ok, Table.describe()}) end)
  end

  def ready({:call, from}, :await_ready, data) do
    current(data, fn -> reply(from, :ok) end)
  end

  def ready({:call, from}, {:checkout, :client}, data) do
    current(data, fn -> checkout(data, from, :client) end)
  end

  def ready(type, event, data) do
    current(data, fn -> common(type, event, :ready, data) end)
  end

  @spec admitting(event_type(), term(), map()) :: result()
  def admitting(:enter, _previous, _data) do
    :keep_state_and_data
  end

  def admitting({:call, from}, {:commit, token}, %{lease: %{token: token}} = data) do
    current(data, fn -> commit(data, from) end)
  end

  def admitting({:call, from}, {:finish, token}, %{lease: %{token: token}} = data) do
    current(data, fn -> finish(data, from) end)
  end

  def admitting({:call, from}, :describe, data) do
    current(data, fn -> reply(from, {:ok, Table.describe()}) end)
  end

  def admitting({:call, from}, :await_ready, data) do
    current(data, fn -> reply(from, :ok) end)
  end

  def admitting({:call, from}, {:checkout, token}, %{lease: %{token: operation}} = data)
      when token == :client or token == operation do
    current(data, fn -> checkout(data, from, token) end)
  end

  def admitting(type, event, data) do
    current(data, fn -> common(type, event, :admitting, data) end)
  end

  @spec draining(event_type(), term(), map()) :: result()
  def draining(:enter, _previous, _data) do
    :keep_state_and_data
  end

  def draining(:internal, :drain, %{active: active, lease: lease} = data)
      when map_size(active) == 0 do
    current(data, fn ->
      {:next_state, :healing, %{data | lease: %{lease | waiting: nil}},
       [{:reply, lease.waiting, :ok}]}
    end)
  end

  def draining(type, event, data) do
    current(data, fn -> common(type, event, :draining, data) end)
  end

  @spec healing(event_type(), term(), map()) :: result()
  def healing({:call, from}, {:commit, token}, %{lease: %{token: token}} = data) do
    commit(data, from)
  end

  def healing({:call, from}, {:finish, token}, %{lease: %{token: token}} = data) do
    finish(data, from)
  end

  def healing({:call, from}, {:checkout, token}, %{lease: %{token: token}} = data) do
    checkout(data, from, token)
  end

  def healing(type, event, data) do
    common(type, event, :healing, data)
  end

  @spec failed(event_type(), term(), map()) :: result()
  def failed(:enter, _previous, data) do
    Lifecycle.remember(:failed)
    {notified, actions} = Lifecycle.notify(data, {:error, data.last_error || :recovery_required})
    {:keep_state, notified, [{{:timeout, :check}, :infinity, :check} | actions]}
  end

  def failed({:call, from}, :await_ready, data) do
    reply(from, {:error, data.last_error || :recovery_required})
  end

  def failed(type, event, data) do
    common(type, event, :failed, data)
  end

  defp common({:call, from}, {:reserve, _token, _owner, _purpose}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:busy, node()}}}]}
  end

  defp common({:call, from}, {:cancel, token}, state, %{lease: %{token: token}} = data) do
    rollback(state, data, [{:reply, from, :ok}])
  end

  defp common({:call, from}, {action, _token}, _state, _data)
       when action in [:commit, :finish, :cancel] do
    {:keep_state_and_data, [{:reply, from, {:error, :stale_operation}}]}
  end

  defp common({:call, from}, {:heal, _nodes}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  defp common(
         :info,
         {:DOWN, ref, :process, _pid, _reason},
         state,
         %{lease: %{monitor: ref}} = data
       ) do
    rollback(state, data, [])
  end

  defp common({:call, from}, :status, state, data) do
    status = %{phase: state, working: data.task != nil, last_error: data.last_error}
    {:keep_state_and_data, [{:reply, from, status}]}
  end

  defp common({:call, from}, :describe, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:not_ready, state}}}]}
  end

  defp common({:call, from}, :await_ready, _state, data) do
    {:keep_state, Lifecycle.wait(data, from)}
  end

  defp common({:call, from}, {:checkout, _token}, state, _data) do
    reply(from, {:error, {:store_unavailable, state}})
  end

  defp common({:call, from}, {:checkin, reference}, _state, data) do
    {:keep_state, Admission.checkin(data, reference),
     [{:reply, from, :ok}, {:next_event, :internal, :drain}]}
  end

  defp common(:info, {reference, result}, state, %{task: %{ref: reference}} = data) do
    Process.demonitor(reference, [:flush])

    error =
      case result do
        :ok -> nil
        {:error, reason} -> reason
      end

    completed = Jobs.completed(data, state, error)
    complete(state, completed)
  end

  defp common(:info, {:DOWN, ref, :process, _pid, reason}, state, %{task: %{ref: ref}} = data) do
    completed = Jobs.completed(data, state, {:worker_exit, reason})
    complete(state, completed)
  end

  defp common(:info, {:DOWN, reference, :process, _pid, _reason}, _state, data) do
    {:keep_state, Admission.checkin(data, reference), [{:next_event, :internal, :drain}]}
  end

  defp common(:info, {:nodeup, _node}, _state, _data) do
    {:keep_state_and_data, [{:next_event, :internal, :check}]}
  end

  defp common(:info, {:mnesia_system_event, _event}, _state, _data) do
    {:keep_state_and_data, [{:next_event, :internal, :check}]}
  end

  defp common(_type, _event, _state, _data) do
    :keep_state_and_data
  end

  # Stable generations must be checked before handling the event, including calls
  # already queued ahead of the controller's DOWN. Replay the event in failed so
  # the caller receives a reply without executing it against a new RAM database.
  defp current(data, fun) do
    if Lifecycle.current?(data) do
      fun.()
    else
      {:next_state, :failed, %{data | last_error: :mnesia_stopped}, [:postpone]}
    end
  end

  defp reply(from, result) do
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  defp checkout(data, {pid, _tag} = from, token) do
    {reference, admitted} = Admission.checkout(data, token, pid)
    {:keep_state, admitted, [{:reply, from, {:ok, reference}}]}
  end

  defp commit(data, from) do
    {:keep_state, %{data | lease: %{data.lease | committed: true}}, [{:reply, from, :ok}]}
  end

  defp finish(data, from) do
    if Admission.operation_active?(data) do
      {:keep_state_and_data, [{:reply, from, {:error, :operation_in_progress}}]}
    else
      {released, actions} = Admission.release(data)
      {:next_state, :ready, released, [{:reply, from, :ok} | actions]}
    end
  end

  defp rollback(state, data, replies) do
    next = Admission.rollback_state(state, data)
    {released, actions} = Admission.release(data)
    Lifecycle.remember(next)

    error =
      if next == :failed do
        data.last_error || :operation_interrupted
      else
        data.last_error
      end

    {:next_state, next, %{released | last_error: error},
     actions ++ replies ++ Jobs.schedule(released)}
  end

  defp complete(state, data) do
    result =
      if state in [:ready, :admitting] do
        :ok
      else
        {:error, data.last_error || :recovery_required}
      end

    {notified, actions} = Lifecycle.notify(data, result)
    {:keep_state, notified, actions ++ Jobs.schedule(notified)}
  end
end
