defmodule Selecto.Telemetry do
  @moduledoc """
  Vendor-neutral, privacy-safe telemetry for Selecto's Elixir runtime.

  Canonical events use the `[:selecto, :telemetry, ...]` namespace and schema
  version 1. SQL, parameters, result data, connection configuration, and raw
  error values are deliberately excluded.
  """

  alias Selecto.Telemetry.Context

  @schema_version 1
  @spec operation(atom(), Selecto.t(), (-> result)) :: result when result: term()
  def operation(kind, selecto, fun) when is_atom(kind) and is_function(fun, 0) do
    context = %{
      operation_id: operation_id(),
      operation_kind: kind,
      adapter: adapter_name(selecto),
      schema_version: @schema_version
    }

    span([:operation], context, fun)
  end

  @spec span([atom()], map(), (-> result)) :: result when result: term()
  def span(suffix, metadata, fun)
      when is_list(suffix) and is_map(metadata) and is_function(fun, 0) do
    span_for([:selecto, :telemetry] ++ suffix, metadata, fun)
  end

  @doc "Emits a safe span in another Selecto Elixir package namespace."
  def span_for(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    inherited = Context.current_operation() || %{}

    metadata =
      inherited |> Map.merge(sanitize_metadata(metadata)) |> Map.put_new(:schema_version, 1)

    started_at = System.monotonic_time()
    span_context = make_ref()
    metadata = Map.put(metadata, :telemetry_span_context, span_context)

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time(), monotonic_time: started_at},
      metadata
    )

    Context.with_operation(metadata, fn ->
      try do
        result = fun.()
        stop = Map.merge(metadata, result_metadata(result))

        :telemetry.execute(
          event ++ [:stop],
          %{
            duration: System.monotonic_time() - started_at,
            monotonic_time: System.monotonic_time()
          },
          stop
        )

        result
      rescue
        exception ->
          emit_exception(event, started_at, metadata, :error, exception.__struct__)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          emit_exception(event, started_at, metadata, kind, reason_type(reason))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  def emit(suffix, measurements, metadata \\ %{}) do
    emit_for([:selecto, :telemetry] ++ suffix, measurements, metadata)
  end

  @doc "Emits a safe single event in another Selecto Elixir package namespace."
  def emit_for(event, measurements, metadata \\ %{}) do
    inherited = Context.current_operation() || %{}

    :telemetry.execute(
      event,
      sanitize_measurements(measurements),
      inherited |> Map.merge(sanitize_metadata(metadata)) |> Map.put_new(:schema_version, 1)
    )
  end

  def result_metadata({:ok, {rows, _columns, _aliases}}) when is_list(rows),
    do: %{outcome: :ok, row_count: length(rows)}

  def result_metadata({:ok, count, _metadata}) when is_integer(count) and count >= 0,
    do: %{outcome: :ok, row_count: count}

  def result_metadata({:ok, _result, _metadata}), do: %{outcome: :ok}
  def result_metadata({:ok, _result}), do: %{outcome: :ok}
  def result_metadata(:ok), do: %{outcome: :ok}

  def result_metadata({:error, %Selecto.Error{type: type}}) do
    %{outcome: outcome(type), error_category: error_category(type)}
  end

  def result_metadata({:error, %{__struct__: _module, type: type}}) when is_atom(type) do
    %{outcome: outcome(type), error_category: error_category(type)}
  end

  def result_metadata({:error, _reason}), do: %{outcome: :error, error_category: :unknown}
  def result_metadata(_result), do: %{outcome: :ok}

  defp emit_exception(event, started_at, metadata, kind, reason_type) do
    :telemetry.execute(
      event ++ [:exception],
      %{duration: System.monotonic_time() - started_at, monotonic_time: System.monotonic_time()},
      Map.merge(metadata, %{
        outcome: :error,
        error_category: :internal,
        kind: normalize_kind(kind),
        reason_type: normalize_reason_type(reason_type)
      })
    )
  end

  defp outcome(type) when type in [:validation_error, :no_results, :multiple_results],
    do: :rejected

  defp outcome(:timeout_error), do: :timeout
  defp outcome(_type), do: :error

  defp error_category(type) when type in [:validation_error, :no_results, :multiple_results],
    do: :validation

  defp error_category(:connection_error), do: :connection
  defp error_category(:timeout_error), do: :connection
  defp error_category(:query_error), do: :query
  defp error_category(:transformation_error), do: :transformation
  defp error_category(:configuration_error), do: :configuration
  defp error_category(_type), do: :unknown

  defp adapter_name(%{adapter: adapter}) when is_atom(adapter) do
    if function_exported?(adapter, :name, 0), do: normalize_atom(adapter.name()), else: :unknown
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp adapter_name(_), do: :unknown

  defp sanitize_metadata(metadata) do
    allowed = [
      :adapter,
      :attempt,
      :cache_result,
      :error_category,
      :operation_id,
      :operation_kind,
      :outcome,
      :parent_span_id,
      :schema_version,
      :stream_result,
      :authoritative,
      :result,
      :status
    ]

    metadata
    |> Map.take(allowed)
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, key, sanitize_value(value)) end)
  end

  defp sanitize_value(value) when is_atom(value), do: normalize_atom(value)
  defp sanitize_value(value) when is_integer(value) or is_boolean(value), do: value
  defp sanitize_value(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp sanitize_value(_value), do: :unknown

  defp sanitize_measurements(measurements) when is_map(measurements) do
    Enum.reduce(measurements, %{}, fn
      {key, value}, acc when is_atom(key) and (is_integer(value) or is_float(value)) ->
        Map.put(acc, key, value)

      _entry, acc ->
        acc
    end)
  end

  defp sanitize_measurements(_measurements), do: %{}

  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom(_value), do: :unknown
  defp normalize_kind(kind) when kind in [:error, :exit, :throw], do: kind
  defp normalize_kind(_kind), do: :error
  defp normalize_reason_type(value) when is_atom(value), do: value
  defp normalize_reason_type(_value), do: :unknown
  defp reason_type(%{__struct__: module}) when is_atom(module), do: module
  defp reason_type(reason) when is_atom(reason), do: reason
  defp reason_type(_reason), do: :unknown
  defp operation_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
