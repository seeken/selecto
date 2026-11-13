defmodule SelectoUpdato.Verification.TenantNonInterferenceSafety do
  @moduledoc """
  Bounded verification that untrusted tenant values cannot influence the final
  flat, nested-graph, or atomic-batch data plane.

  The model exhaustively crosses operation-bound, execution-time, and caller
  tenant values with atom, string, and ambiguous normalized spellings. It
  inspects the actual portable commands and graph rows emitted by Updato.
  """

  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.{Command, Graph}

  @surfaces [:flat, :nested, :batch]
  @operations [:insert, :update]
  @operation_tenants [:absent, :tenant_a]
  @execution_tenants [:absent, :tenant_a, :tenant_b]
  @caller_tenants [:absent, :tenant_a, :tenant_b]
  @spellings [:atom, :string, :both]
  @batch_contexts [:same, :conflicting]
  @source_forms [
    :canonical,
    :opts_source_conflict,
    :duplicate_execution_opts,
    :operation_key_conflict,
    :execution_key_conflict,
    :execution_field_conflict,
    :context_tenant_id_conflict,
    :context_tenant_key_conflict,
    :context_nested_field_conflict
  ]

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check(
      "selecto_updato.tenant_non_interference.v1",
      states(),
      invariants()
    )
  end

  @doc false
  def states do
    for surface <- @surfaces,
        operation <- @operations,
        operation_tenant <- @operation_tenants,
        execution_tenant <- @execution_tenants,
        caller_tenant <- @caller_tenants,
        spelling <- @spellings,
        batch_context <- @batch_contexts,
        source_form <- @source_forms do
      %{
        surface: surface,
        operation: operation,
        operation_tenant: operation_tenant,
        execution_tenant: execution_tenant,
        caller_tenant: caller_tenant,
        spelling: spelling,
        batch_context: batch_context,
        source_form: source_form,
        result:
          compile(
            surface,
            operation,
            operation_tenant,
            execution_tenant,
            caller_tenant,
            spelling,
            batch_context,
            source_form
          )
      }
    end
  end

  defp invariants do
    [
      {"invalid_tenant_states_fail_before_dispatch", &invalid_states_fail_closed/1},
      {"valid_tenant_states_reach_the_portable_data_plane", &valid_states_compile/1},
      {"trusted_tenant_is_the_only_emitted_tenant", &trusted_tenant_is_exclusive/1},
      {"operation_and_execution_tenant_sources_agree", &trusted_sources_agree/1},
      {"normalized_tenant_ambiguity_fails_closed", &ambiguity_fails_closed/1},
      {"batch_context_cannot_mix_tenants", &batch_context_agrees/1}
    ]
  end

  defp compile(
         :flat,
         operation,
         operation_tenant,
         execution_tenant,
         caller,
         spelling,
         _batch_context,
         source_form
       ) do
    operation
    |> flat_operation(operation_tenant, caller, spelling, source_form)
    |> apply_execution_tenant(execution_tenant, source_form)
    |> compile_portable(source_form)
  end

  defp compile(
         :nested,
         operation,
         operation_tenant,
         execution_tenant,
         caller,
         spelling,
         _batch_context,
         source_form
       ) do
    nested_domain()
    |> SelectoUpdato.new()
    |> build_nested_operation(operation, caller, spelling)
    |> maybe_attach_tenant(operation_tenant)
    |> apply_operation_source_form(source_form)
    |> apply_execution_tenant(execution_tenant, source_form)
    |> compile_portable(source_form)
  end

  defp compile(
         :batch,
         operation,
         operation_tenant,
         execution_tenant,
         caller,
         spelling,
         batch_context,
         source_form
       ) do
    first = flat_operation(operation, operation_tenant, caller, spelling, source_form)

    second_operation_tenant =
      if batch_context == :same,
        do: operation_tenant,
        else: opposite_tenant(effective_tenant(operation_tenant, execution_tenant))

    second = flat_operation(operation, second_operation_tenant, :absent, :atom, source_form)
    compile_batch([first, second], execution_tenant, source_form)
  end

  defp compile_batch(operations, execution_tenant, source_form) do
    Enum.reduce_while(operations, {:ok, [], %{}}, fn operation, {:ok, commands, context} ->
      operation = apply_execution_tenant(operation, execution_tenant, source_form)

      case compile_portable(operation, source_form) do
        {:ok, command, operation_context} ->
          case merge_context(context, operation_context) do
            {:ok, context} -> {:cont, {:ok, commands ++ [command], context}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, commands, context} ->
        case Selecto.Write.Batch.new(commands) do
          {:ok, batch} -> {:ok, batch, context}
          {:error, error} -> {:error, error}
        end

      error ->
        error
    end
  end

  defp merge_context(left, right) do
    conflicts =
      left
      |> Map.keys()
      |> Enum.filter(&(Map.has_key?(right, &1) and Map.fetch!(left, &1) != Map.fetch!(right, &1)))

    if conflicts == [], do: {:ok, Map.merge(left, right)}, else: {:error, :batch_context_conflict}
  end

  defp flat_operation(operation, trusted, caller, spelling, source_form) do
    flat_domain()
    |> SelectoUpdato.new()
    |> build_flat_operation(operation, caller, spelling)
    |> maybe_attach_tenant(trusted)
    |> apply_operation_source_form(source_form)
  end

  defp build_flat_operation(operation, :insert, caller, spelling),
    do:
      SelectoUpdato.insert(
        operation,
        caller_attrs(caller, spelling) |> Map.put(:name, "item")
      )

  defp build_flat_operation(operation, :update, caller, spelling) do
    operation
    |> SelectoUpdato.update(%{name: "updated"})
    |> SelectoUpdato.filter({:id, 7})
    |> add_caller_tenant_filters(caller, spelling)
  end

  defp build_nested_operation(operation, :insert, caller, spelling),
    do: SelectoUpdato.insert(operation, nested_attrs(:insert, caller, spelling))

  defp build_nested_operation(operation, :update, caller, spelling) do
    operation
    |> SelectoUpdato.update(nested_attrs(:update, caller, spelling))
    |> SelectoUpdato.filter({:id, 7})
    |> add_caller_tenant_filters(caller, spelling)
  end

  defp add_caller_tenant_filters(operation, :absent, _spelling), do: operation

  defp add_caller_tenant_filters(operation, tenant, :atom),
    do: SelectoUpdato.filter(operation, {:tenant_id, tenant_value(tenant)})

  defp add_caller_tenant_filters(operation, tenant, :string),
    do: SelectoUpdato.filter(operation, {"tenant_id", tenant_value(tenant)})

  defp add_caller_tenant_filters(operation, tenant, :both) do
    SelectoUpdato.filters(operation, [
      {:tenant_id, tenant_value(tenant)},
      {"tenant_id", tenant_value(tenant)}
    ])
  end

  defp caller_attrs(:absent, _spelling), do: %{}
  defp caller_attrs(tenant, :atom), do: %{tenant_id: tenant_value(tenant)}
  defp caller_attrs(tenant, :string), do: %{"tenant_id" => tenant_value(tenant)}

  defp caller_attrs(tenant, :both),
    do: %{"tenant_id" => tenant_value(tenant), tenant_id: tenant_value(tenant)}

  defp nested_attrs(_operation, caller, spelling) do
    root = %{name: "parent"}
    child = caller_attrs(caller, spelling) |> Map.put(:name, "child")
    Map.put(root, :children, [child])
  end

  defp maybe_attach_tenant(operation, :tenant_a),
    do: SelectoUpdato.with_tenant(operation, %{tenant_id: "tenant-a"})

  defp maybe_attach_tenant(operation, :tenant_b),
    do: SelectoUpdato.with_tenant(operation, %{tenant_id: "tenant-b"})

  defp maybe_attach_tenant(operation, :absent), do: operation

  defp apply_operation_source_form(operation, :operation_key_conflict),
    do:
      SelectoUpdato.with_tenant(operation, %{
        "tenant_id" => "tenant-b",
        tenant_id: "tenant-a"
      })

  defp apply_operation_source_form(operation, _source_form), do: operation

  defp apply_execution_tenant(operation, _tenant, :opts_source_conflict),
    do:
      SelectoUpdato.Tenant.apply_execution_scope(operation,
        tenant: %{tenant_id: "tenant-a"},
        tenant_id: "tenant-b"
      )

  defp apply_execution_tenant(operation, _tenant, :duplicate_execution_opts),
    do:
      SelectoUpdato.Tenant.apply_execution_scope(operation,
        tenant_id: "tenant-a",
        tenant_id: "tenant-b"
      )

  defp apply_execution_tenant(operation, _tenant, :execution_key_conflict),
    do:
      SelectoUpdato.Tenant.apply_execution_scope(operation,
        tenant: %{"tenant_id" => "tenant-b", tenant_id: "tenant-a"}
      )

  defp apply_execution_tenant(operation, _tenant, :execution_field_conflict),
    do:
      SelectoUpdato.Tenant.apply_execution_scope(operation,
        tenant: %{
          "tenant_field" => "other_tenant_id",
          tenant_field: "tenant_id",
          tenant_id: "tenant-a"
        }
      )

  defp apply_execution_tenant(operation, :absent, _source_form),
    do: SelectoUpdato.Tenant.apply_execution_scope(operation)

  defp apply_execution_tenant(operation, tenant, _source_form),
    do:
      SelectoUpdato.Tenant.apply_execution_scope(operation,
        tenant: %{tenant_id: tenant_value(tenant)}
      )

  defp compile_portable(operation, source_form) do
    SelectoUpdato.PortableCommand.compile(operation, context_opts(source_form))
  end

  defp context_opts(:context_tenant_id_conflict),
    do: [context: %{"tenant_id" => "tenant-b", tenant_id: "tenant-a"}]

  defp context_opts(:context_tenant_key_conflict),
    do: [
      context: %{
        "tenant" => %{tenant_id: "tenant-b"},
        tenant: %{tenant_id: "tenant-a"}
      }
    ]

  defp context_opts(:context_nested_field_conflict),
    do: [
      context: %{
        tenant: %{tenant_id: "tenant-a", tenant_field: "account_id"},
        tenant_field: "tenant_id"
      }
    ]

  defp context_opts(_source_form), do: []

  defp invalid_states_fail_closed(state) do
    if valid_state?(state) or error_result?(state.result),
      do: :ok,
      else: {:error, %{dispatchable_invalid_tenant_state: state}}
  end

  defp valid_states_compile(state) do
    if not valid_state?(state) or match?({:ok, _portable, %{}}, state.result),
      do: :ok,
      else: {:error, %{valid_tenant_state_failed: state}}
  end

  defp trusted_tenant_is_exclusive(state) do
    case state.result do
      {:ok, portable, _context} ->
        emitted = emitted_tenants(portable)
        expected = state |> effective_tenant() |> tenant_value()

        if emitted != [] and Enum.all?(emitted, &(&1 == expected)),
          do: :ok,
          else:
            {:error, %{unexpected_emitted_tenants: emitted, state: Map.drop(state, [:result])}}

      {:error, _error} ->
        :ok
    end
  end

  defp trusted_sources_agree(state) do
    if (not trusted_source_conflict?(state) and state.source_form == :canonical) or
         error_result?(state.result),
       do: :ok,
       else: {:error, %{conflicting_trusted_tenant_sources_were_accepted: state.result}}
  end

  defp ambiguity_fails_closed(%{caller_tenant: caller, spelling: :both} = state)
       when caller != :absent do
    if error_result?(state.result),
      do: :ok,
      else: {:error, %{normalized_ambiguity_was_accepted: state.result}}
  end

  defp ambiguity_fails_closed(_state), do: :ok

  defp batch_context_agrees(%{surface: :batch, batch_context: :conflicting} = state) do
    if error_result?(state.result),
      do: :ok,
      else: {:error, %{mixed_tenant_batch_was_accepted: state.result}}
  end

  defp batch_context_agrees(_state), do: :ok

  defp valid_state?(state) do
    effective_tenant = effective_tenant(state)

    not trusted_source_conflict?(state) and
      state.source_form == :canonical and
      effective_tenant != :absent and
      state.caller_tenant in [:absent, effective_tenant] and
      (state.caller_tenant == :absent or state.spelling != :both) and
      (state.surface != :batch or state.batch_context == :same)
  end

  defp trusted_source_conflict?(state) do
    state.operation_tenant != :absent and
      state.execution_tenant != :absent and
      state.operation_tenant != state.execution_tenant
  end

  defp effective_tenant(%{operation_tenant: operation, execution_tenant: execution}),
    do: effective_tenant(operation, execution)

  defp effective_tenant(_operation, execution) when execution != :absent, do: execution
  defp effective_tenant(operation, :absent), do: operation

  defp opposite_tenant(:tenant_a), do: :tenant_b
  defp opposite_tenant(:tenant_b), do: :tenant_a
  defp opposite_tenant(:absent), do: :tenant_b

  defp error_result?({:error, _error}), do: true
  defp error_result?(_result), do: false

  defp emitted_tenants(%Command{} = command), do: command_tenants(command)

  defp emitted_tenants(%Graph{} = graph) do
    for node <- graph.nodes,
        row <- node.rows,
        tenant <- command_tenants(row.command),
        do: tenant
  end

  defp emitted_tenants(%Selecto.Write.Batch{} = batch),
    do: Enum.flat_map(batch.commands, &command_tenants/1)

  defp command_tenants(command) do
    assignments =
      for %{field: field, value: {:literal, value}} <- command.assignments,
          to_string(field) == "tenant_id",
          do: value

    assignments ++ predicate_tenants(command.predicate)
  end

  defp predicate_tenants({:and, predicates}), do: Enum.flat_map(predicates, &predicate_tenants/1)

  defp predicate_tenants({:eq, {:field, field}, {:literal, value}}) do
    if to_string(field) == "tenant_id", do: [value], else: []
  end

  defp predicate_tenants(_predicate), do: []

  defp tenant_value(:tenant_a), do: "tenant-a"
  defp tenant_value(:tenant_b), do: "tenant-b"
  defp tenant_value(:absent), do: nil

  defp flat_domain, do: domain("items", [:id, :tenant_id, :name])

  defp nested_domain do
    child = domain("children", [:id, :tenant_id, :parent_id, :name])

    domain("parents", [:id, :tenant_id, :name])
    |> put_in([:writes, :relationships], %{
      children: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: child,
        child_key: :parent_id,
        identity_fields: [:id],
        strategy: :sync,
        delete_missing: true
      }
    })
  end

  defp domain(relation, fields) do
    %{
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{insertable: true, updatable: true, required_on: [:insert]}
        },
        scope: %{
          tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
        },
        relationships: %{}
      }
    }
  end
end
