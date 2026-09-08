defmodule Selecto.Telemetry.Stream do
  @moduledoc false

  defstruct [:enumerable, :metadata]

  def wrap(enumerable) do
    operation = Selecto.Telemetry.Context.current_operation() || %{}

    %__MODULE__{
      enumerable: enumerable,
      metadata: Map.take(operation, [:operation_id, :operation_kind, :adapter])
    }
  end
end

defimpl Enumerable, for: Selecto.Telemetry.Stream do
  def reduce(%{enumerable: enumerable, metadata: metadata}, accumulator, reducer) do
    ref = make_ref()
    started_at = System.monotonic_time()
    state = %{ref: ref, started_at: started_at, count: 0, metadata: metadata, reducer: reducer}
    put_state(state)

    Selecto.Telemetry.emit_for(
      [:selecto, :telemetry, :stream, :start],
      %{system_time: System.system_time(), monotonic_time: started_at},
      metadata
    )

    run(
      fn -> Enumerable.reduce(enumerable, accumulator, wrapped_reducer(ref, reducer)) end,
      state
    )
  end

  def member?(_stream, _value), do: {:error, __MODULE__}
  def count(_stream), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}

  defp run(fun, state) do
    case fun.() do
      {:done, accumulator} ->
        finish(state, :completed)
        {:done, accumulator}

      {:halted, accumulator} ->
        finish(state, :cancelled)
        {:halted, accumulator}

      {:suspended, accumulator, continuation} ->
        suspended_state = current_state(state)
        delete_state(state.ref)

        {:suspended, accumulator,
         fn next_accumulator ->
           put_state(suspended_state)

           run(
             fn -> continuation.(next_accumulator) end,
             suspended_state
           )
         end}
    end
  rescue
    exception ->
      fail(state, :error, exception.__struct__)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      fail(state, kind, reason_type(reason))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp wrapped_reducer(ref, reducer) do
    fn item, accumulator ->
      state = Process.get({__MODULE__, ref})
      put_state(%{state | count: state.count + 1})
      reducer.(item, accumulator)
    end
  end

  defp finish(state, result) do
    state = current_state(state)
    delete_state(state.ref)

    Selecto.Telemetry.emit_for(
      [:selecto, :telemetry, :stream, :stop],
      %{duration: System.monotonic_time() - state.started_at, row_count: state.count},
      Map.merge(state.metadata, %{
        outcome: if(result == :completed, do: :ok, else: :cancelled),
        stream_result: result
      })
    )
  end

  defp fail(state, kind, reason_type) do
    state = current_state(state)
    delete_state(state.ref)

    Selecto.Telemetry.emit_for(
      [:selecto, :telemetry, :stream, :exception],
      %{duration: System.monotonic_time() - state.started_at, row_count: state.count},
      Map.merge(state.metadata, %{
        outcome: :error,
        error_category: :internal,
        stream_result: normalize_kind(kind),
        status: normalize_reason(reason_type)
      })
    )
  end

  defp current_state(state), do: Process.get({__MODULE__, state.ref}, state)
  defp put_state(state), do: Process.put({__MODULE__, state.ref}, state)
  defp delete_state(ref), do: Process.delete({__MODULE__, ref})
  defp normalize_kind(kind) when kind in [:error, :exit, :throw], do: kind
  defp normalize_kind(_kind), do: :error
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_reason), do: :unknown
  defp reason_type(%{__struct__: module}) when is_atom(module), do: module
  defp reason_type(reason) when is_atom(reason), do: reason
  defp reason_type(_reason), do: :unknown
end
