defmodule Selecto.Query.Runtime do
  @moduledoc "Validated source execution shared by independently injected query adapters."
  alias Selecto.Query.{CapabilityProfile, Plan, Result}

  def compile(plan, adapter, connection, opts \\ []) do
    with :ok <- Plan.validate(plan, opts),
         :ok <- adapter_contract(adapter),
         {:ok, profile} <- adapter.capabilities(connection, %{source: plan.source}),
         :ok <- CapabilityProfile.preflight(profile, plan),
         {:ok, compiled} <- adapter.compile_query(connection, plan, opts) do
      {:ok, compiled}
    end
  rescue
    _ ->
      {:error,
       Selecto.Error.configuration_error("Source query adapter failed to compile the plan")}
  catch
    _, _ ->
      {:error,
       Selecto.Error.configuration_error("Source query adapter failed to compile the plan")}
  end

  def execute(plan, adapter, connection, opts \\ []) do
    with {:ok, compiled} <- compile(plan, adapter, connection, opts),
         {:ok, result} <- adapter.execute_query(connection, compiled, opts),
         :ok <- Result.validate(result, plan) do
      {:ok, result}
    end
  rescue
    _ -> {:error, Selecto.Error.query_error("Source query execution failed")}
  catch
    _, _ -> {:error, Selecto.Error.query_error("Source query execution failed")}
  end

  def preview(plan, adapter, connection, opts \\ []) do
    with {:ok, compiled} <- compile(plan, adapter, connection, opts) do
      adapter.preview_query(connection, compiled, opts)
    end
  rescue
    _ -> {:error, Selecto.Error.query_error("Source query preview failed")}
  end

  defp adapter_contract(adapter) do
    callbacks = [
      contract_version: 0,
      capabilities: 2,
      compile_query: 3,
      execute_query: 3,
      preview_query: 3
    ]

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end) and
         adapter.contract_version() == 1,
       do: :ok,
       else:
         {:error, Selecto.Error.configuration_error("Unsupported source query adapter contract")}
  end
end
