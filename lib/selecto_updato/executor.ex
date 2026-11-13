defmodule SelectoUpdato.Executor do
  @moduledoc false

  alias SelectoUpdato.{Error, GovernedWrite, Operation, PortableCommand}

  @execute_event [:selecto_updato, :execute]
  @dry_run_event [:selecto_updato, :dry_run]

  @spec execute(Operation.t(), Selecto.t() | term(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def execute(operation, selecto, opts \\ [])

  def execute(%Operation{} = operation, %Selecto{} = selecto, opts) do
    case engine_tenant_opts(operation, selecto, opts) do
      {:ok, opts} -> do_execute(operation, selecto, opts)
      {:error, _error} = error -> error
    end
  end

  def execute(%Operation{}, _target, _opts) do
    {:error,
     Error.new(
       :configured_selecto_required,
       "Updato writes require a configured Selecto value with a write-capable adapter"
     )}
  end

  # A trusted engine tenant attached to the target Selecto bounds the write
  # like an execution-context tenant (lesson 47). It must name the domain's
  # declared tenant_field and agree with any execution-context tenant.
  @doc false
  def engine_tenant_opts(%Operation{} = operation, %Selecto{} = selecto, opts) do
    engine = Selecto.Tenant.tenant(selecto) || %{}
    tenant_id = Map.get(engine, :tenant_id)
    declared = declared_tenant_field(operation)
    context = Keyword.get(opts, :context, %{})
    context_tenant = Map.get(context, :tenant_id, Map.get(context, "tenant_id"))

    cond do
      is_nil(tenant_id) or is_nil(declared) ->
        {:ok, opts}

      to_string(Map.get(engine, :tenant_field) || "tenant_id") != to_string(declared) ->
        {:error,
         Error.new(:missing_tenant_scope, "the engine tenant does not name the tenant field",
           details: %{field: declared}
         )}

      is_nil(context_tenant) ->
        {:ok, Keyword.put(opts, :context, Map.put(context, :tenant_id, tenant_id))}

      context_tenant == tenant_id ->
        {:ok, opts}

      true ->
        {:error,
         Error.new(:tenant_mismatch, "Trusted tenant sources do not agree",
           details: %{code: :conflicting_trusted_tenant_context}
         )}
    end
  end

  defp declared_tenant_field(%Operation{domain: %{} = domain}) do
    source = Map.get(domain, :source, Map.get(domain, "source")) || %{}
    Map.get(source, :tenant_field, Map.get(source, "tenant_field"))
  end

  defp declared_tenant_field(_operation), do: nil

  defp do_execute(%Operation{} = operation, %Selecto{} = selecto, opts) do
    operation = SelectoUpdato.Tenant.apply_execution_scope(operation, opts)

    compile_opts =
      opts
      |> Keyword.put(:action_phase, :execute)
      |> Keyword.put(:storage_backend, Selecto.AdapterSupport.adapter_name(selecto.adapter))

    telemetry_span(@execute_event, operation, fn ->
      SelectoUpdato.ColumnCatalog.scoped(fn ->
        do_execute_scoped(operation, selecto, compile_opts, opts)
      end)
    end)
  end

  # One execute is one write transaction: one catalog scope.
  defp do_execute_scoped(operation, selecto, compile_opts, opts) do
    capabilities = write_capabilities(selecto)

    with :ok <- ensure_native_rule_support(operation, selecto, capabilities),
         {:ok, result} <- execute_write(operation, selecto, capabilities, compile_opts, opts) do
      {:ok, envelope(result, operation, opts)}
    else
      {:error, %Selecto.Write.Error{} = error} -> {:error, from_write_error(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp execute_write(operation, selecto, capabilities, compile_opts, opts) do
    prepared? = prepared_candidate_write?(operation, selecto, capabilities, opts)

    compile_opts =
      SelectoUpdato.ColumnCatalog.options(compile_opts, operation, selecto, prepared?)

    if prepared? do
      # The capability flags are bound here, before the adapter opens its
      # transaction: a probe through `selecto.connection` from inside the
      # preparation would check out a second pool connection while the
      # transaction holds one (a deadlock at pool size 1).
      protected_upsert? = protected_upsert_candidates?(capabilities)
      native_candidates? = native_rule_candidates?(capabilities)

      prepare = fn protected_state_loader ->
        # The protected loader also serves nested child rows whose own domain
        # rules need prior record state, even when the root does not.
        prepared_opts =
          compile_opts
          |> Keyword.put(:candidate_state_provider, protected_state_loader)
          |> Keyword.put(:record_state_provider, protected_state_loader)
          |> Keyword.put(:rule_candidate_provider, protected_state_loader)
          |> Keyword.put(:upsert_candidate_provider, protected_state_loader)
          |> Keyword.put(:protected_upsert_candidates?, protected_upsert?)
          |> Keyword.put(:native_rule_candidate?, native_candidates?)

        prepared_opts =
          if PortableCommand.requires_prepared_record_state?(operation) do
            Keyword.put(prepared_opts, :require_protected_record_state, true)
          else
            prepared_opts
          end

        # Governance runs inside the adapter's transaction against the
        # protected state; only then does the write get its authorization.
        with {:ok, write, context} <- PortableCommand.compile(operation, prepared_opts) do
          GovernedWrite.prepared(write, context)
        else
          {:error, %Error{} = error} ->
            {:error, Selecto.Write.Error.new(error.type, error.message, details: error.details)}

          other ->
            other
        end
      end

      # The preparation returns its own authorization; one supplied by the
      # caller is never forwarded.
      Selecto.Write.execute_prepared(
        selecto,
        prepare,
        Keyword.drop(opts, [:candidate_state_provider, :authorization])
      )
    else
      if PortableCommand.requires_prepared_record_state?(operation) do
        {:error,
         Error.new(
           :unsupported_operation,
           "required upsert data rules need an adapter-owned protected branch strategy",
           details: %{code: :upsert_rule_strategy_unsupported}
         )}
      else
        with {:ok, command, context} <- PortableCommand.compile(operation, compile_opts) do
          write_opts =
            opts |> Keyword.delete(:candidate_state_provider) |> Keyword.put(:context, context)

          GovernedWrite.execute(selecto, command, write_opts)
        end
      end
    end
  end

  defp prepared_candidate_write?(operation, %Selecto{adapter: adapter}, capabilities, opts) do
    native = native_rule_candidates?(capabilities)

    required_native =
      native and
        case Selecto.Domain.WriteContract.compile(operation.domain) do
          {:ok, contract} ->
            SelectoUpdato.NestedGraph.nested?(operation) or
              SelectoUpdato.RuleValidation.requires_storage_candidate?(operation.type, contract)

          _ ->
            false
        end

    (required_native or
       (not Keyword.has_key?(opts, :candidate_state_provider) and
          not Keyword.has_key?(opts, :record_state_provider))) and
      (required_native or SelectoUpdato.NestedGraph.nested?(operation) or
         PortableCommand.requires_prepared_record_state?(operation)) and
      is_atom(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :execute_prepared_write, 3)
  end

  # Probes the adapter once per operation, outside any adapter transaction.
  # `selecto.connection` is the pool, so this must never run inside a
  # prepared-write callback.
  defp write_capabilities(%Selecto{adapter: adapter, connection: connection}) do
    with true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :write_capabilities, 1),
         capabilities when is_map(capabilities) <- adapter.write_capabilities(connection) do
      capabilities
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp native_rule_candidates?(capabilities),
    do: Map.get(capabilities, :native_rule_candidates, false) == true

  defp protected_upsert_candidates?(capabilities),
    do: Map.get(capabilities, :protected_upsert_candidates, false) == true

  defp ensure_native_rule_support(operation, %Selecto{adapter: adapter}, capabilities) do
    sqlite? =
      is_atom(adapter) and Code.ensure_loaded?(adapter) and
        function_exported?(adapter, :name, 0) and adapter.name() == :sqlite

    cond do
      operation.type == :upsert and PortableCommand.requires_prepared_record_state?(operation) and
          not protected_upsert_candidates?(capabilities) ->
        {:error,
         Error.new(
           :unsupported_operation,
           "Required upsert data rules need an adapter-owned protected branch strategy",
           details: %{code: :upsert_rule_strategy_unsupported}
         )}

      sqlite? and not native_rule_candidates?(capabilities) and
          required_domain_rules?(operation.domain, operation.type) ->
        {:error,
         Error.new(
           :unsupported_operation,
           "SQLite cannot establish a protected native rule candidate",
           details: %{code: :native_rule_candidates_unsupported}
         )}

      true ->
        :ok
    end
  end

  defp required_domain_rules?(domain, operation) do
    case Selecto.Domain.WriteContract.compile(domain) do
      {:ok, contract} ->
        SelectoUpdato.RuleValidation.requires_storage_candidate?(operation, contract) or
          Enum.any?(contract.relationships, fn {_name, relationship} ->
            child = Map.get(relationship, :domain, Map.get(relationship, "domain"))

            is_map(child) and
              Enum.any?([:insert, :update, :delete], &required_domain_rules?(child, &1))
          end)

      _ ->
        false
    end
  end

  @spec execute_in_transaction(Operation.t(), Selecto.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def execute_in_transaction(operation, selecto, opts \\ [])

  def execute_in_transaction(%Operation{} = operation, %Selecto{} = selecto, opts) do
    execute(operation, selecto, opts)
  end

  def execute_in_transaction(%Operation{}, _target, _opts) do
    {:error,
     Error.new(
       :configured_selecto_required,
       "Updato writes require a configured Selecto value with a write-capable adapter"
     )}
  end

  @spec preview(Operation.t(), Selecto.t(), keyword()) ::
          {:ok, Selecto.Write.Preview.t()} | {:error, Error.t()}
  def preview(%Operation{} = operation, %Selecto{} = selecto, opts \\ []) do
    case engine_tenant_opts(operation, selecto, opts) do
      {:ok, opts} -> do_preview(operation, selecto, opts)
      {:error, _error} = error -> error
    end
  end

  defp do_preview(%Operation{} = operation, %Selecto{} = selecto, opts) do
    operation = SelectoUpdato.Tenant.apply_execution_scope(operation, opts)

    compile_opts =
      opts
      |> Keyword.put(:action_phase, :preview)
      |> Keyword.put(:storage_backend, Selecto.AdapterSupport.adapter_name(selecto.adapter))

    capabilities = write_capabilities(selecto)

    result =
      with :ok <- ensure_native_rule_support(operation, selecto, capabilities),
           do: preview_write(operation, selecto, capabilities, compile_opts, opts)

    case result do
      {:error, %Selecto.Write.Error{} = error} -> {:error, from_write_error(error)}
      other -> other
    end
  end

  defp preview_write(operation, selecto, capabilities, compile_opts, opts) do
    prepared? =
      prepared_candidate_write?(operation, selecto, capabilities, opts) and
        function_exported?(selecto.adapter, :preview_prepared_write, 3)

    compile_opts =
      SelectoUpdato.ColumnCatalog.options(compile_opts, operation, selecto, prepared?)

    if prepared? do
      protected_upsert? = protected_upsert_candidates?(capabilities)
      native_candidates? = native_rule_candidates?(capabilities)

      prepare = fn loader ->
        prepared_opts =
          compile_opts
          |> Keyword.put(:candidate_state_provider, loader)
          |> Keyword.put(:record_state_provider, loader)
          |> Keyword.put(:rule_candidate_provider, loader)
          |> Keyword.put(:upsert_candidate_provider, loader)
          |> Keyword.put(:protected_upsert_candidates?, protected_upsert?)
          |> Keyword.put(:native_rule_candidate?, native_candidates?)

        PortableCommand.compile(operation, prepared_opts)
      end

      selecto.adapter.preview_prepared_write(selecto.connection, prepare, opts)
    else
      with {:ok, command, context} <- PortableCommand.compile(operation, compile_opts),
           write_opts =
             opts |> Keyword.delete(:candidate_state_provider) |> Keyword.put(:context, context) do
        Selecto.Write.preview(selecto, command, write_opts)
      end
    end
  end

  @spec dry_run(Operation.t(), Selecto.t()) :: {:ok, term()} | {:error, Error.t()}
  def dry_run(%Operation{} = operation, %Selecto{} = selecto) do
    telemetry_span(@dry_run_event, operation, fn -> preview(operation, selecto) end)
  end

  def dry_run(%Operation{}, _target) do
    {:error,
     Error.new(:configured_selecto_required, "dry runs require a configured Selecto value")}
  end

  @spec dry_run_result(Operation.t(), Selecto.t()) ::
          {:ok, Selecto.Write.Preview.t()} | {:error, Error.t()}
  def dry_run_result(operation, selecto), do: dry_run(operation, selecto)

  @spec build_write_plan(Operation.t(), Selecto.t()) ::
          {:ok, Selecto.Write.Command.t() | Selecto.Write.Graph.t()} | {:error, Error.t()}
  def build_write_plan(%Operation{} = operation, %Selecto{} = selecto) do
    # Inspection follows execution: the target's engine tenant and the trusted
    # execution scope apply (lesson 47).
    with {:ok, opts} <- engine_tenant_opts(operation, selecto, []),
         operation = SelectoUpdato.Tenant.apply_execution_scope(operation, opts),
         {:ok, command, _context} <- PortableCommand.compile(operation, opts),
         do: {:ok, command}
  end

  def build_write_plan(%Operation{}, _target) do
    {:error,
     Error.new(:configured_selecto_required, "write planning requires a configured Selecto value")}
  end

  defp envelope(result, operation, opts) do
    if Keyword.get(opts, :result) == :envelope do
      %{operation: operation.type, data: result, meta: %{portable?: true}}
    else
      result
    end
  end

  defp from_write_error(error), do: Error.new(error.type, error.message, details: error.details)

  defp telemetry_span(event, operation, fun) do
    Selecto.Telemetry.span_for(
      [:selecto_updato, :telemetry, :operation],
      %{operation_kind: List.last(event)},
      fn ->
        :telemetry.span(event, %{operation: operation.type}, fn ->
          case fun.() do
            {:ok, result} -> {{:ok, result}, %{status: :ok}}
            {:error, error} -> {{:error, error}, %{status: :error}}
          end
        end)
      end
    )
  end
end
