defmodule MnesiaStore.Resource do
  @moduledoc """

  The simplest way to use MnesiaStore is to declare a Resource

  ## Examples

      defmodule Session do
        use MnesiaStore.Resource
      end

  Don't forget to put it to your application supervisor

      children = [
        Session
      ]

  It will ensure that the corresonding table is created on all the nodes and
  a special cleaner process is started to evict expired records.

  """

  @doc """
  This function will be called before deleting an expired record from the mnesia table.
  Could be helpful if you want to notify some subsystem about expiration event or
  to perform any cleanup actions related to the resource

  It also allows you to prevent or postpone the deletion of particular key
  by returning a `:skip` atom.
  """
  @callback before_expire(term()) :: :ok | :skip
  @optional_callbacks before_expire: 1

  defmacro __using__(opts) do
    record_name = Keyword.get(opts, :record_name, :entry)
    expires_in_minutes = Keyword.get(opts, :expires_in_minutes, 15)

    quote do
      use Supervisor

      require Record

      @behaviour unquote(__MODULE__)

      @tab_name __MODULE__
      @attributes [key: nil, value: nil, expires_at: nil]
      @expires_in_minutes unquote(expires_in_minutes)

      Record.defrecord(unquote(record_name), @tab_name, @attributes)

      def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg)

      @impl Supervisor
      def init(_init_arg) do
        children = unquote(__MODULE__).child_specs(__MODULE__, @expires_in_minutes)
        Supervisor.init(children, strategy: :one_for_one)
      end

      @spec init_table() :: :ignore | {:error, term()}
      def init_table do
        with :ok <- MnesiaStore.init_table(@tab_name, Keyword.keys(@attributes)) do
          :ignore
        end
      end

      @spec all() :: {:ok, [term()]} | {:error, term()}
      def all, do: MnesiaStore.all(@tab_name)

      @spec fetch(term()) :: {:ok, term()} | {:error, term()}
      def fetch(key) do
        with {:ok, unquote(record_name)(value: value)} <- MnesiaStore.fetch(@tab_name, key) do
          {:ok, value}
        end
      end

      @spec put(term(), term()) :: :ok | {:error, term()}
      def put(nil, _value) do
        {:error, :empty_key}
      end

      def put(key, value) do
        expires_at = unquote(__MODULE__).calc_expires_at(@expires_in_minutes)

        [key: key, value: value, expires_at: expires_at]
        |> unquote(record_name)()
        |> MnesiaStore.put()
      end

      @spec delete(term) :: :ok | {:error, term()}
      def delete(key), do: MnesiaStore.remove(@tab_name, key)

      @spec delete_table() :: :ok | {:error, term()}
      def delete_table do
        case :mnesia.delete_table(@tab_name) do
          {:atomic, :ok} -> :ok
          {:aborted, reason} -> {:error, reason}
        end
      end

      @spec expired :: {:ok, list()} | {:error, term()}
      def expired do
        now = DateTime.to_unix(DateTime.utc_now())
        pattern = unquote(record_name)(key: :"$1", value: :_, expires_at: :"$3")
        conditions = [{:<, :"$3", now}]
        return = [:"$1"]
        MnesiaStore.select(@tab_name, [{pattern, conditions, return}])
      end
    end
  end

  @spec calc_expires_at(term()) :: timeout()
  def calc_expires_at(minutes) when is_integer(minutes) and minutes > 0 do
    DateTime.utc_now()
    |> DateTime.add(minutes, :minute)
    |> DateTime.to_unix()
  end

  def calc_expires_at(_minutes), do: :infinity

  @spec evict_expired(module()) :: :ok | {:error, term()}
  def evict_expired(mod) do
    with {:ok, keys} <- mod.expired() do
      Enum.each(keys, &evict_expired(mod, &1))
    end
  end

  defp evict_expired(mod, key) do
    if function_exported?(mod, :before_expire, 1) do
      call_before_expire(mod, key)
    else
      mod.delete(key)
    end
  end

  defp call_before_expire(mod, key) do
    case mod.before_expire(key) do
      :ok -> mod.delete(key)
      :skip -> :ok
    end
  end

  @spec child_specs(module(), term()) :: [Supervisor.module_spec()]
  def child_specs(mod, expires_in) do
    basic = [resource_spec(mod), healer_spec(mod)]

    if is_integer(expires_in) and expires_in > 0 do
      [{Highlander, cleaner_spec(mod)} | basic]
    else
      basic
    end
  end

  defp resource_spec(mod),
    do: %{id: mod, start: {mod, :init_table, []}}

  defp healer_spec(mod),
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    do: %{id: Module.concat(mod, "Healer"), start: {MnesiaStore.Healer, :start_link, [mod]}}

  defp cleaner_spec(mod),
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    do: %{id: Module.concat(mod, "Cleaner"), start: {MnesiaStore.Cleaner, :start_link, [mod]}}
end
