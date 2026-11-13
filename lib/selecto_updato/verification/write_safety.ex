defmodule SelectoUpdato.Verification.WriteSafety do
  @moduledoc """
  Bounded-exhaustive verification of Updato write-scope invariants.

  The model enumerates every primary write operation across absent,
  trusted-row tenant contexts, with and without unrelated
  caller filters. Canonical execution scope is applied exactly as the executor
  applies it before validation and planning.

  The resulting proof covers this explicit finite model. It does not claim
  correctness for arbitrary host adapters or custom callbacks.
  """

  alias Selecto.Verification.BoundedModel
  alias SelectoUpdato.Operation

  @write_types [:insert, :update, :upsert, :delete]
  @contexts [:none, :tenant_id]

  @doc """
  Runs the built-in write-scope safety model.
  """
  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.write_scope.v1", states(), invariants())
  end

  @doc false
  def states do
    for type <- @write_types,
        context <- @contexts,
        unrelated_filter? <- [false, true] do
      operation =
        tenant_domain()
        |> SelectoUpdato.new()
        |> build_operation(type)
        |> attach_context(context)
        |> maybe_add_unrelated_filter(unrelated_filter?)

      %{
        type: type,
        context: context,
        unrelated_filter?: unrelated_filter?,
        before_scope: operation,
        after_scope: SelectoUpdato.Tenant.apply_execution_scope(operation)
      }
    end
  end

  defp invariants do
    [
      {"required_scope_fails_closed", &required_scope_fails_closed/1},
      {"trusted_context_becomes_targeting_filter", &trusted_context_becomes_targeting_filter/1},
      {"unrelated_filters_cannot_satisfy_scope", &unrelated_filters_cannot_satisfy_scope/1},
      {"scope_application_preserves_operation", &scope_application_preserves_operation/1},
      {"applied_scope_is_auditable", &applied_scope_is_auditable/1}
    ]
  end

  defp required_scope_fails_closed(state) do
    expected_valid? = state.context == :tenant_id
    actual_valid? = SelectoUpdato.validate_tenant_scope(state.after_scope) == :ok

    if actual_valid? == expected_valid?,
      do: :ok,
      else: {:error, %{expected_valid?: expected_valid?, actual_valid?: actual_valid?}}
  end

  defp trusted_context_becomes_targeting_filter(%{context: :tenant_id} = state) do
    filters = state.after_scope.filters || []

    cond do
      {"account_id", "tenant-a"} not in filters ->
        {:error, %{missing_trusted_scope_filter: filters}}

      Enum.count(filters, &(&1 == {"account_id", "tenant-a"})) != 1 ->
        {:error, %{duplicate_trusted_scope_filter: filters}}

      true ->
        :ok
    end
  end

  defp trusted_context_becomes_targeting_filter(_state), do: :ok

  defp unrelated_filters_cannot_satisfy_scope(
         %{
           context: :none,
           unrelated_filter?: true
         } = state
       ) do
    case SelectoUpdato.validate_tenant_scope(state.after_scope) do
      {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} -> :ok
      other -> {:error, %{unrelated_filter_satisfied_scope: other}}
    end
  end

  defp unrelated_filters_cannot_satisfy_scope(_state), do: :ok

  defp scope_application_preserves_operation(state) do
    before = state.before_scope
    after_scope = state.after_scope

    preserved? =
      before.type == after_scope.type and
        before.attrs == after_scope.attrs and
        before.changes == after_scope.changes

    if preserved?,
      do: :ok,
      else:
        {:error,
         %{before: operation_payload(before), after_scope: operation_payload(after_scope)}}
  end

  defp applied_scope_is_auditable(%{context: :none} = state) do
    if SelectoUpdato.Tenant.applied_scope(state.after_scope) == nil,
      do: :ok,
      else: {:error, :scope_reported_without_a_satisfying_source}
  end

  defp applied_scope_is_auditable(%{context: context} = state) do
    applied = SelectoUpdato.Tenant.applied_scope(state.after_scope)
    expected_source = if context == :tenant_id, do: :trusted_context

    case applied do
      %{tenant: %{required: true, field: "account_id", sources: sources}} ->
        if Enum.any?(sources, &(Map.get(&1, :source) == expected_source)),
          do: :ok,
          else: {:error, %{missing_applied_source: expected_source, applied_scope: applied}}

      other ->
        {:error, %{invalid_applied_scope: other}}
    end
  end

  defp build_operation(operation, :insert) do
    SelectoUpdato.insert(operation, %{name: "item", quantity: 1})
  end

  defp build_operation(operation, :update) do
    operation
    |> SelectoUpdato.update(%{quantity: 2})
    |> SelectoUpdato.filter({"id", 7})
  end

  defp build_operation(operation, :upsert) do
    SelectoUpdato.upsert(operation, %{name: "item", quantity: 1})
  end

  defp build_operation(operation, :delete) do
    operation
    |> SelectoUpdato.delete()
    |> SelectoUpdato.filter({"id", 7})
  end

  defp attach_context(operation, :none), do: operation

  defp attach_context(operation, :tenant_id) do
    SelectoUpdato.with_tenant(operation, %{tenant_id: "tenant-a"})
  end

  defp maybe_add_unrelated_filter(operation, true) do
    SelectoUpdato.filter(operation, {"status", "active"})
  end

  defp maybe_add_unrelated_filter(operation, false), do: operation

  defp operation_payload(%Operation{} = operation) do
    Map.take(operation, [:type, :attrs, :changes])
  end

  defp tenant_domain do
    %{
      source: "items",
      columns: %{
        "id" => %{type: :integer},
        "account_id" => %{type: :string},
        "name" => %{type: :string},
        "quantity" => %{type: :integer},
        "status" => %{type: :string}
      },
      readonly: ["id", "account_id"],
      writable: ["name", "quantity", "status"],
      writes: %{
        scope: %{
          tenant: %{
            required: true,
            field: :account_id,
            satisfied_by: [:trusted_context]
          }
        }
      }
    }
  end
end
