defmodule SelectoUpdato.Verification.PortableCommandSafety do
  @moduledoc """
  Bounded-exhaustive verification of the domain-to-command boundary.

  The model crosses every portable operation with trusted context presence,
  required insert-field presence, and absent/matching/mismatched foreign-key
  input. It verifies the compiler without selecting or invoking a database
  adapter.
  """

  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.Command

  @operations [:insert, :update, :upsert, :delete]
  @foreign_key_inputs [:absent, :matching, :mismatched]

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.portable_command.v1", states(), invariants())
  end

  @doc false
  def states do
    for operation <- @operations,
        trusted_context? <- [false, true],
        required_field? <- [false, true],
        foreign_key_input <- @foreign_key_inputs do
      updato_operation =
        domain()
        |> SelectoUpdato.new()
        |> build_operation(operation, required_field?, foreign_key_input)
        |> maybe_attach_tenant(trusted_context?)
        |> SelectoUpdato.expected_cardinality({:exactly, 1})
        |> SelectoUpdato.returning(:all)

      compile_opts =
        if trusted_context?, do: [context: %{account_id: 42}], else: []

      %{
        operation: operation,
        trusted_context?: trusted_context?,
        required_field?: required_field?,
        foreign_key_input: foreign_key_input,
        result: SelectoUpdato.PortableCommand.compile(updato_operation, compile_opts)
      }
    end
  end

  defp invariants do
    [
      {"invalid_states_fail_closed", &invalid_states_fail_closed/1},
      {"valid_states_compile", &valid_states_compile/1},
      {"required_insert_fields_are_enforced", &required_insert_fields_are_enforced/1},
      {"trusted_foreign_keys_cannot_be_overridden", &trusted_foreign_keys_cannot_be_overridden/1},
      {"tenant_scope_is_compiled", &tenant_scope_is_compiled/1},
      {"upsert_conflict_is_tenant_scoped", &upsert_conflict_is_tenant_scoped/1},
      {"foreign_key_guards_are_preserved", &foreign_key_guards_are_preserved/1},
      {"cardinality_and_returning_are_preserved", &cardinality_and_returning_are_preserved/1},
      {"command_is_adapter_neutral", &command_is_adapter_neutral/1}
    ]
  end

  defp invalid_states_fail_closed(state) do
    if valid_state?(state) or match?({:error, %SelectoUpdato.Error{}}, state.result),
      do: :ok,
      else: {:error, %{unexpected_result: state.result}}
  end

  defp valid_states_compile(state) do
    if not valid_state?(state) or match?({:ok, %Command{}, %{}}, state.result),
      do: :ok,
      else: {:error, %{expected_command: state.result}}
  end

  defp required_insert_fields_are_enforced(
         %{operation: operation, required_field?: false} = state
       )
       when operation in [:insert, :upsert] do
    case state.result do
      {:error, %SelectoUpdato.Error{type: :validation, details: %{fields: fields}}} ->
        if "name" in fields, do: :ok, else: {:error, %{missing_required_field: fields}}

      other ->
        {:error, %{required_field_was_not_rejected: other}}
    end
  end

  defp required_insert_fields_are_enforced(_state), do: :ok

  defp trusted_foreign_keys_cannot_be_overridden(
         %{operation: operation, trusted_context?: true, foreign_key_input: :mismatched} = state
       )
       when operation in [:insert, :update, :upsert] do
    if operation in [:insert, :upsert] and not state.required_field? do
      :ok
    else
      case state.result do
        {:error, %SelectoUpdato.Error{type: :foreign_key_source_mismatch}} -> :ok
        other -> {:error, %{foreign_key_override_was_not_rejected: other}}
      end
    end
  end

  defp trusted_foreign_keys_cannot_be_overridden(_state), do: :ok

  defp tenant_scope_is_compiled(state) do
    with true <- valid_state?(state),
         {:ok, %Command{} = command, _context} <- state.result do
      tenant_predicate? = predicate_contains?(command.predicate, "tenant_id", "tenant-a")

      tenant_assignment? =
        state.operation not in [:insert, :upsert] or
          Enum.any?(
            command.assignments,
            &(&1 == %{field: "tenant_id", value: {:literal, "tenant-a"}})
          )

      tenant_scope? =
        if state.operation in [:insert, :upsert], do: tenant_assignment?, else: tenant_predicate?

      if tenant_scope?,
        do: :ok,
        else: {:error, %{predicate: command.predicate, assignments: command.assignments}}
    else
      false -> :ok
      other -> {:error, %{unexpected_result: other}}
    end
  end

  defp upsert_conflict_is_tenant_scoped(%{operation: :upsert} = state) do
    case state.result do
      {:ok, %Command{metadata: metadata}, _context} ->
        target = Map.get(metadata, :conflict_target, [])

        if Enum.any?(target, &(to_string(&1) == "tenant_id")),
          do: :ok,
          else: {:error, %{conflict_target: target}}

      {:error, _error} ->
        :ok
    end
  end

  defp upsert_conflict_is_tenant_scoped(_state), do: :ok

  defp foreign_key_guards_are_preserved(state) do
    with true <- valid_state?(state),
         true <- state.operation in [:insert, :upsert],
         {:ok, %Command{} = command, _context} <- state.result do
      expected = %{field: "account_id", relation: "accounts", target_field: "id"}
      guards = Map.get(command.metadata, :foreign_key_guards, [])

      if expected in guards, do: :ok, else: {:error, %{missing_guard: guards}}
    else
      false -> :ok
      other -> {:error, %{unexpected_result: other}}
    end
  end

  defp cardinality_and_returning_are_preserved(state) do
    case state.result do
      {:ok, %Command{expected_cardinality: {:exactly, 1}, returning: :all}, _context} -> :ok
      {:ok, %Command{} = command, _context} -> {:error, %{command: command}}
      {:error, _error} -> :ok
    end
  end

  defp command_is_adapter_neutral(state) do
    case state.result do
      {:ok, %Command{} = command, _context} ->
        forbidden = [:adapter, :connection, :repo, :driver, :dialect]
        present = Enum.filter(forbidden, &Map.has_key?(command.metadata, &1))
        if present == [], do: :ok, else: {:error, %{adapter_metadata: present}}

      {:error, _error} ->
        :ok
    end
  end

  defp valid_state?(state) do
    required_valid? = state.operation not in [:insert, :upsert] or state.required_field?
    foreign_key_valid? = state.operation == :delete or state.foreign_key_input != :mismatched

    state.trusted_context? and required_valid? and foreign_key_valid?
  end

  defp predicate_contains?({:and, predicates}, field, value) when is_list(predicates),
    do: Enum.any?(predicates, &predicate_contains?(&1, field, value))

  defp predicate_contains?({:eq, {:field, field}, {:literal, value}}, field, value), do: true
  defp predicate_contains?(_predicate, _field, _value), do: false

  defp build_operation(operation, :insert, required_field?, foreign_key_input) do
    SelectoUpdato.insert(operation, attrs(required_field?, foreign_key_input))
  end

  defp build_operation(operation, :upsert, required_field?, foreign_key_input) do
    SelectoUpdato.upsert(operation, attrs(required_field?, foreign_key_input))
  end

  defp build_operation(operation, :update, _required_field?, foreign_key_input) do
    operation
    |> SelectoUpdato.update(update_attrs(foreign_key_input))
    |> SelectoUpdato.filter({"id", 7})
  end

  defp build_operation(operation, :delete, _required_field?, _foreign_key_input) do
    operation |> SelectoUpdato.delete() |> SelectoUpdato.filter({"id", 7})
  end

  defp attrs(required_field?, foreign_key_input) do
    %{}
    |> maybe_put(required_field?, :name, "item")
    |> maybe_put_foreign_key(foreign_key_input)
  end

  defp update_attrs(:absent), do: %{quantity: 2}
  defp update_attrs(:matching), do: %{quantity: 2, account_id: 42}
  defp update_attrs(:mismatched), do: %{quantity: 2, account_id: 7}

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map
  defp maybe_put_foreign_key(map, :absent), do: map
  defp maybe_put_foreign_key(map, :matching), do: Map.put(map, :account_id, 42)
  defp maybe_put_foreign_key(map, :mismatched), do: Map.put(map, :account_id, 7)

  defp maybe_attach_tenant(operation, true),
    do: SelectoUpdato.with_tenant(operation, %{tenant_id: "tenant-a"})

  defp maybe_attach_tenant(operation, false), do: operation

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :account_id, :name, :quantity],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :string},
          account_id: %{type: :integer},
          name: %{type: :string},
          quantity: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, returning: :all},
          update: %{enabled: true, returning: :all},
          upsert: %{
            enabled: true,
            returning: :all,
            conflict_targets: [[:tenant_id, :name]]
          },
          delete: %{enabled: true, returning: :all}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          account_id: %{insertable: true, updatable: true},
          name: %{insertable: true, required_on: [:insert]},
          quantity: %{insertable: true, updatable: true}
        },
        scope: %{
          tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
        },
        constraints: %{
          foreign_keys: %{
            account_id: %{
              source: {:context, :account_id},
              references: %{relation: "accounts", field: :id},
              required: true
            }
          }
        }
      }
    }
  end
end
