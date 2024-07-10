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

  defmacro __using__(opts) do
    record_name = Keyword.get(opts, :record_name, :entry)
    expires_in_minutes = Keyword.get(opts, :expires_in_minutes, 15)

    quote do
      use Supervisor

      require Record

      @tab_name __MODULE__
      @attributes [key: nil, value: nil, expires_at: nil]
      @expires_in_minutes unquote(expires_in_minutes)

      Record.defrecord(unquote(record_name), @tab_name, @attributes)

      def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg)

      @impl Supervisor
      def init(init_arg) do
        basic = [resource_spec(init_arg)]

        children =
          if is_integer(@expires_in_minutes) and @expires_in_minutes > 0 do
            [{Highlander, cleaner_spec()} | basic]
          else
            basic
          end

        Supervisor.init(children, strategy: :one_for_one)
      end

      @spec init_table(Keyword.t()) :: :ignore | {:error, term()}
      def init_table(_init_arg) do
        with :ok <- MnesiaStore.init_table(@tab_name, Keyword.keys(@attributes)) do
          :ignore
        end
      end

      @spec fetch(term()) :: {:ok, term()} | {:error, term()}
      def fetch(key) do
        with {:ok, unquote(record_name)(value: value)} <- MnesiaStore.fetch(@tab_name, key) do
          {:ok, value}
        end
      end

      @spec put(term(), term()) :: {:ok, term()} | {:error, term()}
      def put(nil, _value) do
        {:error, :empty_key}
      end

      def put(key, value) do
        expires_at = unquote(__MODULE__).calc_expires_at(@expires_in_minutes)

        [key: key, value: value, expires_at: expires_at]
        |> unquote(record_name)()
        |> MnesiaStore.put()
      end

      @spec evict_expired() :: :ok
      def evict_expired() do
        now = DateTime.to_unix(DateTime.utc_now())
        pattern = unquote(record_name)(key: :"$1", value: :_, expires_at: :"$3")
        conditions = [{:<, :"$3", now}]
        return = [:"$1"]

        with {:ok, keys} <- MnesiaStore.select(@tab_name, [{pattern, conditions, return}]) do
          Enum.each(keys, fn key -> MnesiaStore.remove(@tab_name, key) end)
        end
      end

      defp resource_spec(init_arg) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :init_table, [init_arg]}
        }
      end

      defp cleaner_spec do
        %{
          id: __MODULE__.Cleaner,
          start: {MnesiaStore.Cleaner, :start_link, [__MODULE__]}
        }
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
end
