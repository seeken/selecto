defmodule SelectoUpdato.Multi do
  @moduledoc false

  alias SelectoUpdato.{Error, GovernedWrite, Operation, PortableCommand}

  defstruct operations: []

  def multi, do: %__MODULE__{}

  def multi_insert(%__MODULE__{} = multi, name, domain, attrs),
    do: append(multi, name, SelectoUpdato.insert(SelectoUpdato.new(domain), attrs))

  def multi_update(%__MODULE__{} = multi, name, domain, opts) do
    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filters(Keyword.get(opts, :filters, []))
      |> SelectoUpdato.update(Keyword.fetch!(opts, :changes))

    append(multi, name, operation)
  end

  def run(multi, selecto, opts \\ [])

  def run(%__MODULE__{operations: operations}, %Selecto{} = selecto, opts) do
    compile_opts =
      opts
      |> Keyword.put(:action_phase, :execute)
      |> Keyword.put(:storage_backend, Selecto.AdapterSupport.adapter_name(selecto.adapter))

    # The batch is one write transaction: one catalog scope, so each table's
    # catalog is read at most once for all of its operations.
    SelectoUpdato.ColumnCatalog.scoped(fn ->
      with :ok <- validate_operation_names(operations),
           {:ok, results} <- execute_operations(operations, selecto, compile_opts, opts),
           {:ok, named_results} <- map_results(operations, results) do
        {:ok, named_results}
      else
        {:error, %Selecto.Write.Error{} = error} ->
          {:error, Error.new(error.type, error.message, details: error.details)}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  def run(%__MODULE__{}, _target, _opts),
    do:
      {:error, Error.new(:configured_selecto_required, "multi writes require configured Selecto")}

  defp execute_operations(operations, selecto, compile_opts, opts) do
    protected? =
      Enum.any?(operations, fn {_name, operation} ->
        PortableCommand.requires_prepared_record_state?(operation) or
          native_storage_rules?(operation, compile_opts)
      end)

    capabilities = prepared_capabilities(selecto)
    prepared? = protected? and capabilities != nil

    compile_opts =
      SelectoUpdato.ColumnCatalog.options(
        compile_opts,
        Enum.map(operations, &elem(&1, 1)),
        selecto,
        prepared?
      )

    if prepared? do
      prepare = fn loader ->
        prepared_opts =
          compile_opts
          |> Keyword.put(:candidate_state_provider, loader)
          |> Keyword.put(:record_state_provider, loader)
          |> Keyword.put(:rule_candidate_provider, loader)
          |> Keyword.put(:upsert_candidate_provider, loader)
          |> Keyword.put(
            :native_rule_candidate?,
            Map.get(capabilities, :native_rule_candidates) == true
          )
          |> Keyword.put(
            :protected_upsert_candidates?,
            Map.get(capabilities, :protected_upsert_candidates) == true
          )
          |> Keyword.put(:require_protected_record_state, true)

        with {:ok, commands, context} <-
               compile_operations(operations, selecto, prepared_opts, true),
             {:ok, batch} <- Selecto.Write.Batch.new(commands) do
          GovernedWrite.prepared(batch, context)
        else
          {:error, %Error{} = error} ->
            {:error, Selecto.Write.Error.new(error.type, error.message, details: error.details)}

          other ->
            other
        end
      end

      Selecto.Write.execute_prepared(
        selecto,
        prepare,
        Keyword.drop(opts, [
          :authorization,
          :candidate_state_provider,
          :record_state_provider,
          :rule_candidate_provider,
          :upsert_candidate_provider
        ])
      )
    else
      with {:ok, commands, context} <-
             compile_operations(operations, selecto, compile_opts, false),
           {:ok, batch} <- Selecto.Write.Batch.new(commands) do
        GovernedWrite.execute(selecto, batch, Keyword.put(opts, :context, context))
      end
    end
  end

  defp prepared_capabilities(%Selecto{adapter: adapter, connection: connection}) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :execute_prepared_write, 3) and
         function_exported?(adapter, :write_capabilities, 1) do
      capabilities = adapter.write_capabilities(connection)
      if Map.get(capabilities, :prepared_candidate_state) == true, do: capabilities, else: nil
    end
  rescue
    _ -> nil
  end

  defp append(%__MODULE__{operations: operations} = multi, name, %Operation{} = operation)
       when is_atom(name),
       do: %{multi | operations: operations ++ [{name, operation}]}

  defp validate_operation_names(operations) do
    duplicates =
      operations
      |> Enum.map(&elem(&1, 0))
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case duplicates do
      [] ->
        :ok

      names ->
        {:error,
         Error.new(:invalid_operation, "Atomic write batch operation names must be unique",
           details: %{code: :duplicate_batch_operation_name, names: names}
         )}
    end
  end

  defp map_results(operations, results) when is_list(results) do
    names = Enum.map(operations, &elem(&1, 0))

    if length(names) == length(results) do
      {:ok, names |> Enum.zip(results) |> Map.new()}
    else
      batch_result_count_mismatch(length(names), length(results))
    end
  end

  defp map_results(operations, _results) do
    batch_result_count_mismatch(length(operations), :invalid)
  end

  defp batch_result_count_mismatch(expected, actual) do
    {:error,
     Error.new(:adapter_failure, "Atomic write batch returned an unexpected result count",
       details: %{
         code: :batch_result_count_mismatch,
         expected_result_count: expected,
         actual_result_count: actual
       }
     )}
  end

  defp compile_operations(operations, selecto, opts, protected?) do
    operations
    |> Enum.reduce_while({:ok, [], %{}}, fn {name, operation}, {:ok, commands, context} ->
      # A trusted engine tenant on the target bounds every batch member
      # (lesson 47).
      case SelectoUpdato.Executor.engine_tenant_opts(operation, selecto, opts) do
        {:ok, opts} ->
          operation = SelectoUpdato.Tenant.apply_execution_scope(operation, opts)
          compile_member(name, operation, opts, protected?, commands, context)

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp compile_member(name, operation, opts, protected?, commands, context) do
    case compile_batch_operation(name, operation, opts, protected?) do
      {:ok, command, operation_context} ->
        case merge_context(context, operation_context) do
          {:ok, context} -> {:cont, {:ok, commands ++ [command], context}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  # Only our prepared callback can select this path. Caller-supplied providers
  # cannot claim that a batch has an adapter-owned protected loader.
  defp compile_batch_operation(_name, operation, opts, true),
    do: PortableCommand.compile(operation, opts)

  defp compile_batch_operation(name, operation, opts, false) do
    if PortableCommand.requires_prepared_record_state?(operation) or
         native_storage_rules?(operation, opts) do
      {:error,
       Error.new(
         :unsupported_operation,
         "atomic write batches cannot establish the protected storage these data rules require",
         details: %{
           code: :batch_rule_strategy_unsupported,
           name: name,
           operation: operation.type
         }
       )}
    else
      PortableCommand.compile(operation, opts)
    end
  end

  defp native_storage_rules?(operation, opts) do
    Keyword.get(opts, :storage_backend) == :sqlite and
      case Selecto.Domain.WriteContract.compile(operation.domain) do
        {:ok, contract} ->
          SelectoUpdato.RuleValidation.requires_storage_candidate?(operation.type, contract)

        _ ->
          false
      end
  end

  defp merge_context(left, right) when is_map(left) and is_map(right) do
    conflicts =
      left
      |> Map.keys()
      |> Enum.filter(&(Map.has_key?(right, &1) and Map.fetch!(left, &1) != Map.fetch!(right, &1)))
      |> Enum.sort()

    case conflicts do
      [] ->
        {:ok, Map.merge(left, right)}

      keys ->
        # Each operation is governed against its own domain, so a batch may
        # span domains, but only under one trusted context.
        type =
          if Enum.any?(keys, &(&1 in [:tenant_id, "tenant_id", :tenant, "tenant"])),
            do: :tenant_mismatch,
            else: :invalid_operation

        {:error,
         Error.new(type, "Atomic write batch has conflicting trusted context",
           details: %{code: :batch_context_conflict, keys: keys}
         )}
    end
  end
end
