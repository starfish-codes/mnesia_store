# MnesiaStore

A RAM-only Mnesia store for applications running on multiple Erlang nodes.
New nodes that discover an existing database load its replicas before becoming
ready, so data can survive a Kubernetes rolling update while a source replica
remains alive until copying completes.

- Uses `:ram_copies` only
- Copies all managed tables to joining nodes
- Reconciles independently initialized databases after connectivity returns

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `mnesia_store` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mnesia_store, "~> 2.0"}
  ]
end
```

## Managed database

```elixir
defmodule Session do
  use MnesiaStore.Resource, expires_in_minutes: 15
end

defmodule ApiKey do
  use MnesiaStore.Resource, expires_in_minutes: :infinity
end

children = [
  # Start your node-discovery supervisor here first.
  {MnesiaStore.Supervisor, resources: [Session, ApiKey]},
  MyApp.Endpoint
]
```

Start one `MnesiaStore.Supervisor` per node. Declare every resource there instead
of starting the resource supervisors separately. The resource API (`put`, `fetch`,
`delete`, `all`, expiration callbacks) is unchanged.

The supervisor starts immediately. Its coordinator discovers a ready database in
a supervised worker and joins it once, then creates missing tables and waits for
local replicas of all tables. If discovery expires without a ready seed, it creates
a local database. Resource cleaners start after initialization. Resource `init_table/0`
uses `MnesiaStore.managed_init_table/2` to create a table or add its local replica;
it never joins databases.
Joining reserves membership changes on seed nodes, but keeps their readiness and
normal reads/writes enabled. Only healing pauses access to existing databases.

**Wire `MnesiaStore.ready?/0` into your readiness endpoint.** Starting the supervisor
does not make the node ready. With working discovery and connectivity, a rolling
deployment should keep old pods alive until the new pod reports ready (for example,
`maxUnavailable: 0`, `maxSurge: 1`). Waiting for the endpoint process to start alone
does not establish this guarantee. The discovery fallback described below also
means readiness alone cannot guarantee preservation during a network partition.

```elixir
MnesiaStore.ready?()
# => true | false

MnesiaStore.status()
# => %{phase: :ready, working: false, last_error: nil}

MnesiaStore.await_ready(10_000)
# => :ok | {:error, reason}; a caller timeout does not abort the worker
```

Every node uses the same startup configuration for initial deployment and rolling
updates. It waits up to `discovery_timeout` milliseconds (default: 5,000) for a ready
seed, polling the `nodes` callback as discovery changes. A ready seed ends the wait
early. If none responds within the window, the node creates a local database and
becomes ready after its tables load. Set `discovery_timeout: 0` to skip initial
discovery. This timeout bounds seed discovery, not the subsequent join or table load;
a failed or hung join never falls back to creating an empty database.

Background discovery and healing continue after startup. If connectivity returns,
independently created databases can be reconciled under the rules below. Expiring
the discovery window cannot distinguish an absent cluster from an unreachable one:
during a partition, a new node may become ready with an independent database. Old
data survives only if a source remains alive until replication or healing completes.

See `MnesiaStore.Supervisor` for discovery and timeout options. Seed nodes must run
this coordinator protocol. A new node joins a single existing component; joining
multiple incompatible databases is deferred to the healing protocol.

## Coordinator states

The coordinator uses `:gen_statem` with `state_functions` and `state_enter`.
Each state has its own callback with its allowed events and transitions; shared
handlers live in the same module. OTP stores the state separately from worker,
reservation and caller-monitor data. Periodic checks use a named timeout.
Blocking Mnesia operations run under the task supervisor, so a stuck join leaves
the coordinator responsive. A timeout does not cancel a Mnesia operation.

| State | Meaning | Resource reads/writes |
| --- | --- | --- |
| `booting` | Discovering a seed | Closed |
| `joining` | Initializing and loading local replicas | Closed |
| `ready` | Local replicas are ready | Open |
| `admitting` | Serving as a source for a joining node | Open |
| `draining` | Waiting for admitted calls before healing | Closed to new calls |
| `healing` | Reconciling databases | Closed |
| `failed` | Recovery requires investigation | Closed |

A normal startup follows `booting → joining → ready`. A source follows
`ready → admitting → ready`; healing follows `ready → draining → healing → ready`.
Pre-mutation cancellation restores the previous state. An interrupted mutation
leaves the node in `failed`.

There is no global flag selecting legacy or managed API behavior. A separate
persistent recovery marker records the Mnesia process generation and completed
or interrupted operations, so a coordinator restart cannot forget an unfinished join.

## Healing independent databases

The coordinator checks connected peers periodically and when nodes connect. One
worker reserves all participating coordinators, including every running member of
each Mnesia component. Reservations are acquired in node-name order. Each node
accepts only one reservation, and every backend request carries its operation token.

Healing performs these steps across **all tables**, rather than once per resource:

1. Close admission through the resource API and drain already admitted calls.
2. Snapshot every participating database and resolve all record conflicts.
3. Import the combined data into the component with the smallest node name and
   verify the complete imported snapshot.
4. Stop Mnesia on the other components, start empty RAM schemas and join them to
   the retained component. A multi-node source component is stopped as a group.
5. Load and verify all local replicas before reopening admission.

The source is never reset after an unconfirmed transfer. No remote `delete_table`
calls are used. The resource API returns `{:error, {:store_unavailable, :draining}}`
while admitted calls finish, then `{:error, {:store_unavailable, :healing}}` during
reconciliation. Resource reads, writes and cleaner database calls all pass through
the same admission barrier.

Different keys are preserved from both sides. Identical records are deduplicated.
Different records at the same key stop healing with `{:record_conflict, table}`
before either database is changed. An application can supply a deterministic
`conflict_resolver: {Module, :resolve}` callback:

```elixir
def resolve(table, current_record, incoming_record) do
  # Apply the application's conflict policy; retain the table name and key.
  {:ok, choose_record(table, current_record, incoming_record)}
end
```

The callback runs while writes are paused, so it must not call the public store API.
It may return `{:error, reason}` to cancel reconciliation. Every node should use the
same policy. A manual attempt can be requested with `MnesiaStore.heal([peer_node])`;
`:ok` means the operation was started, and `status/0` reports its outcome.

## Boundaries and failure behavior

- The managed supervisor owns the entire Mnesia instance. Healing refuses schemas
  or tables stored on disk, unsupported table types and tables without this
  library's ownership property. It never deletes disk files.
- Managed data must be accessed through resources or `MnesiaStore.with_access/1`.
  The legacy low-level API (`MnesiaStore.put/1`, `fetch/2`, etc.) and direct Mnesia
  calls bypass the barrier and invalidate the healing guarantees when used on
  managed data without `with_access/1`.
- Independently created tables have different cookies. If two components share
  a table cookie, they have shared history: a missing record might represent a
  deletion. Healing reports `{:shared_history_requires_reconciliation, table}`
  and preserves both databases. Automatic reconciliation of that case requires a
  deletion/version protocol; a simple union would resurrect deleted records.
- Snapshots and their combined result are held in RAM, and admission remains
  closed during copying. This implementation targets small stores and caches.
- A failure before mutation preserves the databases and normally restores
  admission. An interrupted mutation, an outstanding RPC or a coordinator restart
  during healing leaves affected nodes unavailable, requiring investigation and
  explicit operational recovery. Do not restart all pods: the retained component
  may hold the only complete copy. There are no automatic destructive retries.
- A coordinator restart adopts a completed join only for the same live Mnesia
  instance. An unexpected Mnesia stop removes readiness. A hung join keeps its
  worker and keeps admission closed; the coordinator remains responsive. Workers
  do not kill Mnesia's internal schema coordinators to simulate cancellation.

## Migration from per-resource supervision

This changes the supervision API. Replace individual resource children with one
`MnesiaStore.Supervisor`, add the readiness check, and use compatible coordinators
on all participating nodes. Tables created by older versions do not carry the
ownership property; this implementation does not automatically claim or reset
them. Plan the initial migration separately from normal rolling replacements.

Resources require `MnesiaStore.Supervisor`; starting them as standalone children
is no longer supported. Their database calls fail when the coordinator is unavailable.

The existing low-level API remains available without a coordinator. In particular,
`MnesiaStore.init_table/2` keeps its per-call `change_config` and table-copy behavior.
These legacy calls do not use managed discovery or healing. Use the resource API
for the coordinated lifecycle described above.

## Verification

```sh
mix test
mix credo --strict
mix format --check-formatted
```
