defmodule MnesiaStore.Supervisor do
  @moduledoc """
  Owns the lifecycle of one node's RAM database.

  Start this child after the discovery supervisor, with every resource that belongs
  to the database. Do not also start those resources separately. Startup is asynchronous;
  use `MnesiaStore.ready?/0` in the application's readiness probe.

      {MnesiaStore.Supervisor, resources: [Session, ApiKey]}

  Options:

    * `:resources` — resource modules, required.
    * `:nodes` — seed candidates, or a zero-argument function (default: visible nodes).
      The function is polled during startup and must return promptly.
    * `:discovery_timeout` — milliseconds to wait for a ready database before
      creating a local one, default 5,000. A ready seed ends discovery early;
      `0` skips initial discovery. This does not bound joining or loading tables.
    * `:check_interval` — discovery/healing interval in milliseconds, default 5,000;
      `:infinity` disables automatic checks.
    * `:rpc_timeout` — timeout for coordination and transfer calls, default 10,000.
    * `:table_timeout` — timeout for loading local tables, default 10,000.
    * `:conflict_resolver` — optional `{module, function}` called with table, current
      record, incoming record; must return `{:ok, record}` or `{:error, reason}`.
      Without it, different records at the same key prevent healing.

  Healing requires exclusive ownership of Mnesia and access through resources
  or `MnesiaStore.with_access/1`. Legacy low-level and direct Mnesia calls bypass
  the admission barrier. Tables not created by this library, disk-backed schemas,
  and disk-backed tables prevent automatic healing.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    definitions = resource_definitions(opts)
    opts = Keyword.put(opts, :table_definitions, definitions)
    discovery_timeout = Keyword.get(opts, :discovery_timeout, 5_000)

    unless is_integer(discovery_timeout) and discovery_timeout >= 0 do
      raise ArgumentError, ":discovery_timeout must be a non-negative integer"
    end

    children = [
      {Task.Supervisor, name: MnesiaStore.Workers},
      MnesiaStore.Resources,
      {MnesiaStore.Coordinator, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp resource_definitions(opts) do
    opts
    |> Keyword.fetch!(:resources)
    |> Enum.into(%{}, & &1.__mnesia_store__())
  end
end
