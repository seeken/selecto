defmodule Selecto.Telemetry.Context do
  @moduledoc false

  @operation_key {__MODULE__, :operation}

  def current_operation, do: Process.get(@operation_key)

  def with_operation(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = Process.get(@operation_key)
    Process.put(@operation_key, context)

    try do
      fun.()
    after
      restore(@operation_key, previous)
    end
  end

  def capture do
    %{
      operation: current_operation(),
      logger: Logger.metadata(),
      provider: capture_provider()
    }
  end

  def run(captured, fun) when is_map(captured) and is_function(fun, 0) do
    previous_operation = Process.get(@operation_key)
    previous_logger = Logger.metadata()
    Process.put(@operation_key, captured.operation)
    Logger.metadata(captured.logger)
    provider_token = attach_provider(captured.provider)

    try do
      fun.()
    after
      detach_provider(provider_token)
      Logger.reset_metadata(previous_logger)
      restore(@operation_key, previous_operation)
    end
  end

  defp capture_provider do
    case provider() do
      nil -> nil
      module -> {module, safe_apply(module, :capture, [], nil)}
    end
  end

  defp attach_provider(nil), do: nil
  defp attach_provider({module, value}), do: {module, safe_apply(module, :attach, [value], nil)}
  defp detach_provider(nil), do: :ok
  defp detach_provider({module, token}), do: safe_apply(module, :detach, [token], :ok)

  defp provider do
    case Application.get_env(:selecto, :telemetry_context_provider) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> nil
    end
  end

  defp safe_apply(module, function, args, fallback) do
    if function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      fallback
    end
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)
end
