defmodule Selecto.Write.CommittedEffectSink do
  @moduledoc """
  Transaction-local port for facts derived from an actually committed write.

  A configured sink runs after the adapter has obtained the normalized write
  result but before the database transaction commits. Returning an error or
  raising rolls the entire write back. The sink receives the adapter's active
  transaction connection; it must use that connection and must not perform an
  external side effect directly.
  """

  alias Selecto.Write.Error

  @type sink :: (term(), term(), map() -> :ok | {:ok, term()} | {:error, term()})

  @spec invoke(nil | sink(), term(), term(), map()) :: :ok | {:error, Error.t()}
  def invoke(nil, _connection, _result, _context), do: :ok

  def invoke(sink, connection, result, context) when is_function(sink, 3) do
    case sink.(connection, result, context) do
      :ok -> :ok
      {:ok, _evidence} -> :ok
      {:error, %Error{} = error} -> {:error, sink_error(error)}
      {:error, reason} -> {:error, sink_error(reason)}
      other -> {:error, sink_error({:invalid_return, other})}
    end
  rescue
    exception ->
      {:error, sink_error({:exception, exception.__struct__})}
  catch
    kind, _reason -> {:error, sink_error({:caught, kind})}
  end

  def invoke(_sink, _connection, _result, _context),
    do: {:error, sink_error(:invalid_sink)}

  defp sink_error(reason) do
    Error.new(
      :committed_effect_failed,
      "transaction-local committed effect sink failed",
      details: %{reason: sanitized_reason(reason)}
    )
  end

  defp sanitized_reason({:exception, module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp sanitized_reason({:caught, kind}) when is_atom(kind), do: "caught:" <> Atom.to_string(kind)
  defp sanitized_reason({:invalid_return, _other}), do: "invalid_return"
  defp sanitized_reason(%Error{type: type}), do: "write_error:" <> Atom.to_string(type)
  defp sanitized_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitized_reason(_reason), do: "sink_error"
end
