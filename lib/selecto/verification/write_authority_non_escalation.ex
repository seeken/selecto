defmodule Selecto.Verification.WriteAuthorityNonEscalation do
  @moduledoc """
  Bounded event-trace verification of write-authority normalization.

  The finite model crosses absent, colocated, canonical, and duplicate
  colocated/canonical declarations for fields and relationships. It also
  crosses three operations, operation enablement, surface writability, tenant
  scope, filter requirements, and command predicate presence.

  The invariants prove that normalization and contract compilation never create
  a field or relationship grant that was not explicitly and unambiguously
  authored. They also prove that tenant-scope and filter-requirement metadata,
  and portable command predicates, survive their respective core boundaries.
  Enforcement of those compiled requirements during a database mutation belongs
  to the governed writer and adapter verification suites, not this core model.
  """

  alias Selecto.Domain
  alias Selecto.Domain.WriteContract
  alias Selecto.Verification.BoundedTraceModel
  alias Selecto.Write.{Command, Error}

  @locations [:none, :colocated, :canonical, :both]
  @surfaces [:field, :relationship]
  @operations [:insert, :update, :delete]

  @doc "Runs the built-in write-authority non-escalation event model."
  @spec verify() :: BoundedTraceModel.report()
  def verify do
    BoundedTraceModel.check(
      "selecto.write_authority_non_escalation.v1",
      initial_states(),
      events(),
      invariants(),
      max_depth: 3,
      state_key: &state_key/1,
      trace_state: &trace_state/1
    )
  end

  defp initial_states do
    for location <- @locations,
        surface <- @surfaces,
        operation <- @operations,
        surface_writable? <- [false, true],
        operation_enabled? <- [false, true],
        scope_required? <- [false, true],
        require_filter? <- [false, true],
        predicate_present? <- [false, true] do
      dimensions = %{
        location: location,
        surface: surface,
        operation: operation,
        surface_writable?: surface_writable?,
        operation_enabled?: operation_enabled?,
        scope_required?: scope_required?,
        require_filter?: require_filter?,
        predicate_present?: predicate_present?
      }

      %{
        phase: :authored,
        dimensions: dimensions,
        authored: authored_domain(dimensions),
        normalized: nil,
        normalization_diagnostics: nil,
        validation: nil,
        authored_compilation: nil,
        normalized_compilation: nil,
        command: nil
      }
    end
  end

  defp events do
    [
      {:normalize, &normalize/1},
      {:validate, &validate/1},
      {:compile, &compile/1}
    ]
  end

  defp normalize(%{phase: :authored} = state) do
    {:ok, normalized, diagnostics} = Domain.normalize(state.authored)

    {:next,
     %{
       state
       | phase: :normalized,
         normalized: normalized,
         normalization_diagnostics: diagnostics
     }, %{phase: :normalized}}
  end

  defp normalize(_state), do: :disabled

  defp validate(%{phase: :normalized} = state) do
    {:next, %{state | phase: :validated, validation: Domain.validate(state.authored)},
     %{phase: :validated}}
  end

  defp validate(_state), do: :disabled

  defp compile(%{phase: :validated} = state) do
    command = command(state.dimensions)

    {:next,
     %{
       state
       | phase: :compiled,
         authored_compilation: WriteContract.compile(state.authored),
         normalized_compilation: WriteContract.compile(state.normalized),
         command: command
     }, %{phase: :compiled}}
  end

  defp compile(_state), do: :disabled

  defp invariants do
    [
      {"normalization_never_invents_surface_authority", &normalization_non_escalation/1},
      {"duplicate_authority_fails_closed", &duplicate_authority_fails_closed/1},
      {"compiled_authority_matches_unambiguous_authoring", &compiled_authority/1},
      {"scope_filter_and_predicate_metadata_are_preserved", &metadata_preserved/1}
    ]
  end

  defp normalization_non_escalation(%{phase: phase} = state)
       when phase in [:normalized, :validated, :compiled] do
    dimensions = state.dimensions
    entry = normalized_surface_entry(state.normalized, dimensions.surface)
    expected_present? = dimensions.location in [:colocated, :canonical]

    cond do
      expected_present? and is_nil(entry) ->
        {:error, %{expected_surface_entry: dimensions}}

      not expected_present? and not is_nil(entry) ->
        {:error, %{invented_surface_entry: entry, dimensions: dimensions}}

      expected_present? and surface_authority?(entry, dimensions) != dimensions.surface_writable? ->
        {:error,
         %{
           expected_writable?: dimensions.surface_writable?,
           actual_entry: entry,
           dimensions: dimensions
         }}

      colocated_write_metadata_present?(state.normalized, dimensions.surface) ->
        {:error, %{colocated_metadata_survived_normalization: dimensions}}

      true ->
        :ok
    end
  end

  defp normalization_non_escalation(_state), do: :ok

  defp duplicate_authority_fails_closed(%{phase: phase} = state)
       when phase in [:normalized, :validated, :compiled] do
    duplicate? = state.dimensions.location == :both
    diagnostic? = duplicate_diagnostic?(state.normalization_diagnostics)

    cond do
      duplicate? and not diagnostic? ->
        {:error, %{missing_duplicate_diagnostic: state.dimensions}}

      not duplicate? and diagnostic? ->
        {:error, %{unexpected_duplicate_diagnostic: state.dimensions}}

      state.phase in [:validated, :compiled] and duplicate? and
          not match?({:error, %{errors: errors}} when is_list(errors), state.validation) ->
        {:error, %{duplicate_domain_validated: state.validation}}

      state.phase in [:validated, :compiled] and not duplicate? and
          not match?({:ok, _normalized, _diagnostics}, state.validation) ->
        {:error, %{unambiguous_domain_rejected: state.validation, dimensions: state.dimensions}}

      true ->
        :ok
    end
  end

  defp duplicate_authority_fails_closed(_state), do: :ok

  defp compiled_authority(%{phase: :compiled} = state) do
    dimensions = state.dimensions

    with :ok <- authored_compilation_expected(state),
         {:ok, contract} <- normalized_contract(state.normalized_compilation),
         :ok <- operation_authority_matches(contract, dimensions),
         :ok <- surface_authority_matches(contract, dimensions) do
      expected_end_to_end? =
        dimensions.operation_enabled? and authored_surface_granted?(dimensions)

      actual_end_to_end? =
        WriteContract.operation_enabled?(contract, dimensions.operation) and
          compiled_surface_granted?(contract, dimensions)

      if actual_end_to_end? == expected_end_to_end?,
        do: :ok,
        else:
          {:error,
           %{
             expected_end_to_end?: expected_end_to_end?,
             actual_end_to_end?: actual_end_to_end?,
             dimensions: dimensions
           }}
    end
  end

  defp compiled_authority(_state), do: :ok

  defp metadata_preserved(%{phase: :compiled} = state) do
    dimensions = state.dimensions

    with {:ok, contract} <- normalized_contract(state.normalized_compilation),
         {:ok, command} <- normalized_command(state.command) do
      scope_required? = match?(%{tenant: %{required: true}}, contract.scope)
      predicate_present? = not is_nil(command.predicate)

      filter_requirement =
        case Map.get(contract.operations, dimensions.operation) do
          %{require_filter: required?} -> required?
          nil -> :operation_disabled
          _spec -> false
        end

      expected_filter_requirement =
        if dimensions.operation_enabled?,
          do: dimensions.require_filter?,
          else: :operation_disabled

      cond do
        scope_required? != dimensions.scope_required? ->
          {:error, %{expected_scope?: dimensions.scope_required?, actual_scope?: scope_required?}}

        predicate_present? != dimensions.predicate_present? ->
          {:error,
           %{
             expected_predicate?: dimensions.predicate_present?,
             actual_predicate?: predicate_present?
           }}

        filter_requirement != expected_filter_requirement ->
          {:error,
           %{
             expected_filter_requirement: expected_filter_requirement,
             actual_filter_requirement: filter_requirement
           }}

        true ->
          :ok
      end
    end
  end

  defp metadata_preserved(_state), do: :ok

  defp authored_compilation_expected(%{dimensions: %{location: :both}} = state) do
    if match?({:error, %Error{type: :invalid_domain}}, state.authored_compilation),
      do: :ok,
      else: {:error, %{ambiguous_authored_domain_compiled: state.authored_compilation}}
  end

  defp authored_compilation_expected(state) do
    if match?({:ok, %WriteContract{}}, state.authored_compilation),
      do: :ok,
      else:
        {:error,
         %{
           unambiguous_authored_domain_failed: state.authored_compilation,
           dimensions: state.dimensions
         }}
  end

  defp normalized_contract({:ok, %WriteContract{} = contract}), do: {:ok, contract}
  defp normalized_contract(other), do: {:error, %{normalized_compilation_failed: other}}

  defp normalized_command({:ok, %Command{} = command}), do: {:ok, command}
  defp normalized_command(other), do: {:error, %{portable_command_failed: other}}

  defp operation_authority_matches(contract, dimensions) do
    actual = WriteContract.operation_enabled?(contract, dimensions.operation)

    if actual == dimensions.operation_enabled?,
      do: :ok,
      else:
        {:error,
         %{
           expected_operation_enabled?: dimensions.operation_enabled?,
           actual_operation_enabled?: actual,
           dimensions: dimensions
         }}
  end

  defp surface_authority_matches(contract, %{surface: :field} = dimensions) do
    expected =
      dimensions.location in [:colocated, :canonical] and
        dimensions.surface_writable? and dimensions.operation in [:insert, :update]

    actual = WriteContract.writable?(contract, dimensions.operation, :status)

    if actual == expected,
      do: :ok,
      else: {:error, %{expected_field_writable?: expected, actual_field_writable?: actual}}
  end

  defp surface_authority_matches(contract, %{surface: :relationship} = dimensions) do
    expected =
      dimensions.location in [:colocated, :canonical] and dimensions.surface_writable?

    actual = compiled_relationship_granted?(contract, dimensions.operation)

    if actual == expected,
      do: :ok,
      else:
        {:error,
         %{expected_relationship_writable?: expected, actual_relationship_writable?: actual}}
  end

  defp compiled_surface_granted?(contract, %{surface: :field} = dimensions),
    do: WriteContract.writable?(contract, dimensions.operation, :status)

  defp compiled_surface_granted?(contract, %{surface: :relationship} = dimensions),
    do: compiled_relationship_granted?(contract, dimensions.operation)

  defp authored_surface_granted?(%{surface: :field} = dimensions) do
    dimensions.location in [:colocated, :canonical] and
      dimensions.surface_writable? and dimensions.operation in [:insert, :update]
  end

  defp authored_surface_granted?(%{surface: :relationship} = dimensions) do
    dimensions.location in [:colocated, :canonical] and dimensions.surface_writable?
  end

  defp compiled_relationship_granted?(contract, operation) do
    case map_entry(contract.relationships, "items") do
      nil ->
        false

      spec ->
        (map_value(spec, :enabled) == true or map_value(spec, :writable) == true) and
          operation in List.wrap(map_value(spec, :allowed_ops))
    end
  end

  defp normalized_surface_entry(normalized, :field) do
    normalized.writes |> map_value(:fields, %{}) |> map_entry("status")
  end

  defp normalized_surface_entry(normalized, :relationship) do
    normalized.writes |> map_value(:relationships, %{}) |> map_entry("items")
  end

  defp surface_authority?(entry, %{surface: :field, operation: :insert}),
    do: map_value(entry, :insertable) == true

  defp surface_authority?(entry, %{surface: :field}),
    do: map_value(entry, :updatable) == true

  defp surface_authority?(entry, %{surface: :relationship, operation: operation}) do
    (map_value(entry, :enabled) == true or map_value(entry, :writable) == true) and
      operation in List.wrap(map_value(entry, :allowed_ops))
  end

  defp colocated_write_metadata_present?(normalized, :field) do
    normalized.source.columns |> map_entry("status") |> has_key?(:write)
  end

  defp colocated_write_metadata_present?(normalized, :relationship) do
    normalized.source.associations |> map_entry("items") |> has_key?(:write)
  end

  defp duplicate_diagnostic?(%{errors: errors}) do
    Enum.any?(errors, &(Map.get(&1, :code) == :duplicate_write_authoring))
  end

  defp duplicate_diagnostic?(_diagnostics), do: false

  defp authored_domain(dimensions) do
    writes = %{
      operations:
        %{
          upsert: %{enabled: true, require_filter: false}
        }
        |> Map.put(dimensions.operation, %{
          enabled: dimensions.operation_enabled?,
          require_filter: dimensions.require_filter?
        }),
      fields: %{id: %{immutable: true}}
    }

    writes =
      if dimensions.scope_required? do
        Map.put(writes, :scope, %{tenant: %{required: true, field: :tenant_id}})
      else
        writes
      end

    domain = base_domain() |> Map.put(:writes, writes)
    put_surface_authority(domain, dimensions)
  end

  defp put_surface_authority(domain, %{location: :none}), do: domain

  defp put_surface_authority(domain, %{location: :colocated} = dimensions) do
    put_colocated(domain, surface_spec(dimensions, dimensions.surface_writable?))
  end

  defp put_surface_authority(domain, %{location: :canonical} = dimensions) do
    put_canonical(domain, surface_spec(dimensions, dimensions.surface_writable?))
  end

  defp put_surface_authority(domain, %{location: :both} = dimensions) do
    domain
    |> put_colocated(surface_spec(dimensions, dimensions.surface_writable?))
    |> put_canonical(surface_spec(dimensions, not dimensions.surface_writable?))
  end

  defp put_colocated(domain, spec) do
    case spec do
      {:field, write} -> put_in(domain, [:source, :columns, :status, :write], write)
      {:relationship, write} -> put_in(domain, [:source, :associations, :items, :write], write)
    end
  end

  defp put_canonical(domain, spec) do
    case spec do
      {:field, write} ->
        update_in(domain, [:writes], fn writes ->
          Map.update(writes, :fields, %{"status" => write}, &Map.put(&1, "status", write))
        end)

      {:relationship, write} ->
        write = relationship_defaults(write)

        update_in(domain, [:writes], fn writes ->
          Map.update(
            writes,
            :relationships,
            %{"items" => write},
            &Map.put(&1, "items", write)
          )
        end)
    end
  end

  defp surface_spec(%{surface: :field, operation: :insert}, writable?),
    do: {:field, %{insertable: writable?, updatable: false}}

  defp surface_spec(%{surface: :field}, writable?),
    do: {:field, %{insertable: false, updatable: writable?}}

  defp surface_spec(%{surface: :relationship, operation: operation}, writable?) do
    {:relationship,
     %{
       enabled: writable?,
       writable: writable?,
       ownership: :owned,
       allowed_ops: if(writable?, do: [operation], else: [])
     }}
  end

  defp relationship_defaults(spec) do
    Map.merge(%{cardinality: :many, parent_key: :id, child_key: :account_id}, spec)
  end

  defp command(dimensions) do
    assignments =
      if dimensions.operation == :delete,
        do: [],
        else: [%{field: :status, value: {:literal, "ready"}}]

    predicate =
      if dimensions.predicate_present?,
        do: {:eq, {:field, :tenant_id}, {:context, :tenant_id}},
        else: nil

    Command.new(%{
      operation: dimensions.operation,
      relation: :accounts,
      assignments: assignments,
      predicate: predicate
    })
  end

  defp base_domain do
    %{
      source: %{
        source_table: "accounts",
        primary_key: :id,
        fields: [:id, :status, :tenant_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          status: %{type: :string},
          tenant_id: %{type: :integer}
        },
        associations: %{
          items: %{
            queryable: :items,
            field: :items,
            owner_key: :id,
            related_key: :account_id,
            cardinality: :many
          }
        }
      },
      schemas: %{
        items: %{
          source_table: "account_items",
          primary_key: :id,
          fields: [:id, :account_id],
          redact_fields: [],
          columns: %{id: %{type: :integer}, account_id: %{type: :integer}},
          associations: %{}
        }
      },
      joins: %{items: %{type: :left}}
    }
  end

  defp map_entry(map, normalized_id) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      if to_string(key) == normalized_id, do: value
    end)
  end

  defp map_entry(_map, _normalized_id), do: nil

  defp map_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp has_key?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_key?(_map, _key), do: false

  defp state_key(state), do: {state.dimensions, state.phase}

  defp trace_state(state) do
    %{phase: state.phase, dimensions: state.dimensions}
  end
end
