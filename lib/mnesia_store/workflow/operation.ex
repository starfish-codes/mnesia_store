defmodule MnesiaStore.Workflow.Operation do
  @moduledoc false

  alias MnesiaStore.{Backend, Coordinator}

  @spec run((-> term())) :: term()
  def run(fun) do
    fun.()
  catch
    :throw, {:workflow_error, reason} -> {:error, reason}
    kind, reason -> {:error, {:operation_failed, kind, reason}}
  end

  @spec session([node()], keyword(), (reference() -> term()), atom()) :: term()
  def session(nodes, opts, fun, purpose \\ :heal) do
    token = make_ref()

    try do
      Enum.each(nodes, fn member ->
        intent = reservation_purpose(member, purpose)
        rpc!(member, Coordinator, :reserve, [token, self(), intent], opts)
      end)

      fun.(token)
    after
      # Include nodes whose reservation reply might have been lost. Tokens
      # prevent this cleanup from releasing another operation's reservation.
      Enum.each(nodes, fn member ->
        safe_rpc(member, Coordinator, :cancel, [token], opts)
      end)
    end
  end

  defp reservation_purpose(member, :bootstrap) when member != node() do
    :admit
  end

  defp reservation_purpose(_member, purpose) do
    purpose
  end

  @spec commit([node()], reference(), keyword()) :: :ok
  def commit(nodes, token, opts) do
    Enum.each(nodes, &rpc!(&1, Coordinator, :commit, [token], opts))
  end

  @spec finish([node()], reference(), keyword()) :: :ok
  def finish(nodes, token, opts) do
    Enum.each(nodes, &rpc!(&1, Coordinator, :finish, [token], opts))
    :ok
  end

  @spec ensure_tables(node(), reference(), map(), keyword()) :: :ok
  def ensure_tables(member, token, definitions, opts) do
    timeout = Keyword.get(opts, :table_timeout, 10_000)
    backend(member, token, {:ensure, definitions, timeout}, opts)
  end

  @spec backend(node(), reference(), term(), keyword()) :: term()
  def backend(member, token, action, opts) do
    rpc!(member, Backend, :execute, [token, action], opts)
  end

  @spec rpc!(node(), module(), atom(), [term()], keyword()) :: term()
  def rpc!(member, module, function, args, opts) do
    case rpc(member, module, function, args, opts) do
      :ok -> :ok
      {:ok, result} -> result
      {:error, reason} -> fail(reason)
    end
  end

  defp rpc(member, module, function, args, _opts) when member == node() do
    apply(module, function, args)
  end

  defp rpc(member, module, function, args, opts) do
    :erpc.call(member, module, function, args, Keyword.get(opts, :rpc_timeout, 10_000))
  end

  @spec safe_rpc(node(), module(), atom(), [term()], keyword()) :: term()
  def safe_rpc(member, module, function, args, opts) do
    rpc(member, module, function, args, opts)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec fail(term()) :: no_return()
  def fail(reason) do
    throw({:workflow_error, reason})
  end
end
