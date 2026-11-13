defmodule SelectoUpdato.Upsert do
  @moduledoc """
  Upsert (insert or update on conflict) operation building for SelectoUpdato.
  """

  alias SelectoUpdato.Operation
  alias SelectoUpdato.Error
  alias SelectoUpdato.KeyNormalizer
  alias SelectoUpdato.WriteContract

  @doc """
  Set up an upsert operation with the given attributes.
  """
  @spec upsert(Operation.t(), map()) :: Operation.t()
  def upsert(%Operation{} = op, attrs) when is_map(attrs) do
    %{op | type: :upsert, attrs: attrs}
  end

  @doc """
  Choose one of the field targets declared by the domain.

  Portable writes require
  `writes.operations.upsert.conflict_targets`. If the domain declares one
  target, it is derived automatically and callers should omit this function.
  If it declares multiple targets, use this function to select one. Constraint
  names and raw fragments are not accepted by the portable write path.

  ## Examples

      # Both targets must already be allowed by the domain
      |> conflict_target(["external_id"])
      |> conflict_target(["tenant_id", "external_id"])
  """
  @spec conflict_target(Operation.t(), [atom() | String.t()]) :: Operation.t()
  def conflict_target(%Operation{} = op, target) when is_list(target) do
    %{op | conflict_target: target}
  end

  @doc """
  Apply domain-owned upsert conflict target policy.

  When `writes.operations.upsert.conflict_targets` declares one allowed target,
  the target becomes the default. When it declares multiple targets, callers
  must choose one explicitly.
  """
  @spec apply_domain_conflict_policy(Operation.t()) :: {:ok, Operation.t()} | {:error, Error.t()}
  def apply_domain_conflict_policy(%Operation{type: :upsert} = op) do
    allowed_targets = WriteContract.conflict_targets(op.domain, :upsert)

    result =
      cond do
        allowed_targets == [] ->
          {:error,
           Error.new(
             :invalid_operation,
             "Upsert requires at least one domain-declared conflict target",
             details: %{
               code: :conflict_target_not_declared,
               operation: :upsert,
               required: [:writes, :operations, :upsert, :conflict_targets]
             }
           )}

        is_nil(op.conflict_target) and length(allowed_targets) == 1 ->
          {:ok, %{op | conflict_target: hd(allowed_targets)}}

        is_nil(op.conflict_target) ->
          {:error,
           Error.new(
             :invalid_operation,
             "Upsert conflict target must be explicit when domain declares multiple conflict targets",
             details: %{
               code: :conflict_target_not_declared,
               operation: :upsert,
               allowed_conflict_targets: allowed_targets
             }
           )}

        true ->
          validate_requested_conflict_target(op, allowed_targets)
      end

    with {:ok, resolved} <- result,
         :ok <- validate_tenant_conflict_target(resolved) do
      {:ok, resolved}
    end
  end

  def apply_domain_conflict_policy(%Operation{} = op), do: {:ok, op}

  defp validate_tenant_conflict_target(%Operation{} = op) do
    case WriteContract.tenant_scope(op.domain) do
      %{field: tenant_field} when not is_nil(tenant_field) ->
        target = List.wrap(op.conflict_target)

        if Enum.any?(target, &(to_string(&1) == to_string(tenant_field))) do
          :ok
        else
          {:error,
           Error.new(
             :invalid_operation,
             "Tenant-scoped upsert conflict targets must include the tenant field",
             details: %{
               code: :tenant_conflict_target_missing,
               tenant_field: tenant_field,
               conflict_target: target
             }
           )}
        end

      _scope ->
        :ok
    end
  end

  defp validate_requested_conflict_target(
         %Operation{conflict_target: target} = op,
         allowed_targets
       ) do
    case normalize_requested_conflict_target(target, op.domain) do
      {:ok, normalized_target} ->
        if normalized_target in allowed_targets do
          {:ok, %{op | conflict_target: normalized_target}}
        else
          {:error,
           Error.new(
             :invalid_operation,
             "Upsert conflict target is not allowed by domain write contract",
             details: %{
               code: :conflict_target_not_declared,
               operation: op.type,
               conflict_target: normalized_target,
               allowed_conflict_targets: allowed_targets
             }
           )}
        end

      {:error, :non_field_target} ->
        {:error,
         Error.new(
           :invalid_operation,
           "Upsert conflict target must use a declared field target from the domain write contract",
           details: %{
             code: :conflict_target_not_declared,
             operation: op.type,
             conflict_target: target,
             allowed_conflict_targets: allowed_targets
           }
         )}

      {:error, :unknown_field} ->
        {:error,
         Error.new(
           :invalid_operation,
           "Upsert conflict target must reference known fields",
           details: %{
             code: :conflict_target_not_declared,
             operation: op.type,
             conflict_target: target
           }
         )}
    end
  end

  defp normalize_requested_conflict_target(target, domain) when is_list(target) do
    normalized =
      target
      |> Enum.map(&normalize_field_ref(&1, domain))
      |> Enum.reject(&is_nil/1)

    if length(normalized) == length(target) and normalized != [] do
      {:ok, normalized}
    else
      {:error, :unknown_field}
    end
  end

  defp normalize_requested_conflict_target({kind, _value}, _domain)
       when kind in [:constraint, :unsafe_fragment],
       do: {:error, :non_field_target}

  defp normalize_requested_conflict_target(_target, _domain), do: {:error, :unknown_field}

  defp normalize_field_ref(field, domain) when is_atom(field) or is_binary(field) do
    source = Selecto.Domain.Contract.Shared.Core.map_value(domain, :source)
    columns = Selecto.Domain.Contract.Shared.Core.map_value(source, :columns) || %{}
    columns = if is_map(columns), do: columns, else: %{}
    declared = Enum.find(Map.keys(columns), &(to_string(&1) == to_string(field)))

    case declared || KeyNormalizer.normalize_field(field, domain) do
      nil when is_atom(field) -> field
      nil when is_binary(field) -> existing_atom(field)
      normalized -> normalized
    end
  end

  defp normalize_field_ref(_field, _domain), do: nil

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
