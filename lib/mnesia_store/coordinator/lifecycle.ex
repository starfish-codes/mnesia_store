defmodule MnesiaStore.Coordinator.Lifecycle do
  @moduledoc false

  # The marker identifies the Mnesia generation and survives coordinator crashes.
  # It is separate from the state held by gen_statem and grants no API bypass.
  @marker {MnesiaStore.Coordinator, :database_state}

  @spec new(keyword()) :: {atom(), map()}
  def new(opts) do
    state = initial_state(opts)

    data = %{
      opts: opts,
      lease: nil,
      active: %{},
      waiters: %{},
      task: nil,
      last_error: nil,
      generation: nil,
      generation_monitor: nil
    }

    {state, monitor_generation(data)}
  end

  @spec activate(map()) :: map()
  def activate(data) do
    remember(:ready)
    :mnesia.subscribe(:system)
    resources = Keyword.fetch!(data.opts, :resources)
    MnesiaStore.Resources.ensure_started(resources)
    monitor_generation(data)
  end

  @spec current?(map()) :: boolean()
  def current?(data) do
    data.generation != nil and data.generation == Process.whereis(:mnesia_controller)
  end

  @spec wait(map(), :gen_statem.from()) :: map()
  def wait(data, {pid, _tag} = from) do
    reference = Process.monitor(pid)
    %{data | waiters: Map.put(data.waiters, reference, from)}
  end

  @spec notify(map(), term()) :: {map(), [term()]}
  def notify(data, result) do
    actions =
      Enum.map(data.waiters, fn {reference, from} ->
        Process.demonitor(reference, [:flush])
        {:reply, from, result}
      end)

    {%{data | waiters: %{}}, actions}
  end

  @spec remember(atom()) :: :ok
  def remember(state) do
    :persistent_term.put(@marker, {Process.whereis(:mnesia_controller), state})
  end

  defp initial_state(opts) do
    generation = Process.whereis(:mnesia_controller)

    case :persistent_term.get(@marker, nil) do
      {^generation, :ready} when generation != nil -> ready_state(opts)
      {_generation, state} when state in [:reserved, :failed] -> :failed
      _marker -> :booting
    end
  end

  defp ready_state(opts) do
    if resources_loaded?(opts) do
      :ready
    else
      :failed
    end
  end

  defp resources_loaded?(opts) do
    opts
    |> Keyword.fetch!(:table_definitions)
    |> Enum.all?(fn {table, attributes} ->
      :mnesia.table_info(table, :storage_type) == :ram_copies and
        :mnesia.table_info(table, :where_to_read) == node() and
        :mnesia.table_info(table, :attributes) == attributes
    end)
  catch
    :exit, _reason -> false
  end

  defp monitor_generation(data) do
    if data.generation_monitor do
      Process.demonitor(data.generation_monitor, [:flush])
    end

    generation = Process.whereis(:mnesia_controller)

    reference =
      if generation do
        Process.monitor(generation)
      end

    %{data | generation: generation, generation_monitor: reference}
  end
end
