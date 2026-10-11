defmodule Selecto.Builder.Association do
  @moduledoc false

  # Association predicates are domain-owned. Keep policy values bound while
  # sharing exactly the same relation boundary for flat joins and collections.
  def predicate(selecto, association, target_alias, source_alias) do
    key =
      case value(association, :through) do
        through when is_map(through) ->
          bridge(selecto, association, through, target_alias, source_alias)

        _ ->
          equality(
            selecto,
            target_alias,
            value(association, :related_key),
            source_alias,
            value(association, :owner_key)
          )
      end

    conditions =
      [key] ++
        direct_scope(selecto, association, target_alias, source_alias) ++
        tenant_scope(selecto, association, target_alias, source_alias) ++
        carried(selecto, value(association, :carry_tenant_field), target_alias) ++
        policies(selecto, target_alias, value(association, :where, %{}))

    Enum.intersperse(conditions, " AND ")
  end

  defp bridge(selecto, association, through, target_alias, source_alias) do
    bridge_alias = target_alias <> "_bridge"
    target_key = column(selecto, target_alias, value(association, :related_key))

    target_key =
      case value(through, :target_key_cast) do
        nil -> target_key
        type when type in [:string, "string"] -> ["CAST(", target_key, " AS TEXT)"]
        type when type in [:integer, "integer"] -> ["CAST(", target_key, " AS INTEGER)"]
        other -> raise ArgumentError, "unsupported association target key cast: #{inspect(other)}"
      end

    table = value(through, :table)

    unless is_binary(table) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, table),
      do: raise(ArgumentError, "association through table must be a declared relation name")

    conditions =
      [
        equality(
          selecto,
          bridge_alias,
          value(through, :owner_key),
          source_alias,
          value(association, :owner_key)
        ),
        [column(selecto, bridge_alias, value(through, :related_key)), " = ", target_key]
      ] ++
        bridge_scope(selecto, through, bridge_alias, target_alias, source_alias) ++
        policies(selecto, bridge_alias, value(through, :where, %{}))

    [
      "EXISTS (SELECT 1 FROM ",
      selecto.adapter.quote_identifier(table),
      " ",
      bridge_alias,
      " WHERE ",
      Enum.intersperse(conditions, " AND "),
      ")"
    ]
  end

  defp direct_scope(selecto, association, target_alias, source_alias) do
    case {value(association, :source_scope_key), value(association, :target_scope_key)} do
      {nil, nil} ->
        []

      {source, target} when not is_nil(source) and not is_nil(target) ->
        [equality(selecto, target_alias, target, source_alias, source)]

      _ ->
        raise ArgumentError,
              "association scope requires both :source_scope_key and :target_scope_key"
    end
  end

  # The tenant pair resolved by Selecto.Schema.Join.association_boundary!/5
  # whenever both relations declare tenant_field. It is ANDed in addition to any
  # authored scope keys, for direct and through associations alike.
  defp tenant_scope(selecto, association, target_alias, source_alias) do
    case value(association, :tenant_scope) do
      nil -> []
      {source, target} -> [equality(selecto, target_alias, target, source_alias, source)]
    end
  end

  defp carried(_selecto, nil, _target_alias), do: []

  defp carried(selecto, field, target_alias) do
    case carried_tenant(selecto, target_alias, field) do
      [] -> []
      condition -> [condition]
    end
  end

  @doc false
  # The condition binding a tenant relation reached across an untenanted hop
  # to the query's admitted tenants (lesson 41b), or [] for an unscoped query.
  #
  # A scoped root that declares tenant_field (a trusted engine tenant or a
  # required tenant conjunct, or a retargeted root bounded by its context)
  # pairs the target with the root row: by name in a two-column domain, else
  # with the root's tenant_field. A retargeted untenanted root carries its
  # origin's admitted tenant set by value onto the same-named field. A target
  # neither can reach is refused.
  def carried_tenant(selecto, target_alias, field) do
    field = to_string(field)
    root_field = Selecto.Tenant.domain_tenant_field(selecto)
    columns = Selecto.Tenant.domain_tenant_columns(selecto)
    carry = Selecto.Tenant.tenant_carry(selecto)

    root_column =
      cond do
        is_nil(root_field) or not anchored?(selecto, root_field) -> nil
        length(columns) < 2 -> root_field
        field in columns and root_declares?(selecto, field) -> field
        true -> :unpaired
      end

    cond do
      is_binary(root_column) ->
        [
          column(selecto, target_alias, field),
          " = ",
          column(selecto, "selecto_root", root_column)
        ]

      carry != nil and carry.field == field ->
        values(selecto, target_alias, field, carry.conditions)

      root_column == :unpaired or carry != nil ->
        raise Selecto.PolicyViolation,
          type: :missing_tenant_scope,
          message:
            "relation tenant field #{inspect(field)} is reached across an untenanted hop " <>
              "and the query tenant scope cannot be carried onto it"

      true ->
        []
    end
  end

  defp anchored?(selecto, root_field) do
    match?({:ok, _}, Selecto.Tenant.carry_conditions(selecto, root_field)) or
      Selecto.Retarget.has_retarget?(selecto)
  end

  defp root_declares?(selecto, field) do
    selecto
    |> Selecto.domain()
    |> Map.get(:source, %{})
    |> value(:fields, [])
    |> Enum.any?(&(to_string(&1) == field))
  end

  defp values(selecto, target_alias, field, conditions) do
    target = column(selecto, target_alias, field)

    conditions
    |> Enum.map(fn
      {_field, {:in, list}} when is_list(list) -> in_list(target, list)
      {_field, list} when is_list(list) -> in_list(target, list)
      {_field, scalar} -> [target, " = ", {:param, scalar}]
    end)
    |> Enum.intersperse(" AND ")
    |> then(&["(", &1, ")"])
  end

  defp in_list(target, list),
    do: [target, " IN (", Enum.intersperse(Enum.map(list, &{:param, &1}), ", "), ")"]

  defp bridge_scope(selecto, through, bridge_alias, target_alias, source_alias) do
    case {value(through, :source_scope_key), value(through, :through_scope_key),
          value(through, :target_scope_key)} do
      {nil, nil, nil} ->
        []

      {source, bridge, target}
      when not is_nil(source) and not is_nil(bridge) and not is_nil(target) ->
        [
          equality(selecto, bridge_alias, bridge, source_alias, source),
          equality(selecto, target_alias, target, source_alias, source)
        ]

      _ ->
        raise ArgumentError,
              "through association scope requires source, through, and target scope keys"
    end
  end

  defp policies(selecto, alias_name, policy) when is_map(policy) do
    policy
    |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
    |> Enum.map(fn
      {field, nil} ->
        [column(selecto, alias_name, field), " IS NULL"]

      {field, value} when is_binary(value) or is_number(value) or is_boolean(value) ->
        [column(selecto, alias_name, field), " = ", {:param, value}]

      _ ->
        raise ArgumentError, "association policy requires scalar equality values"
    end)
  end

  defp policies(_selecto, _alias_name, _policy),
    do: raise(ArgumentError, "association where policy must be a map")

  defp equality(selecto, left_alias, left, right_alias, right),
    do: [column(selecto, left_alias, left), " = ", column(selecto, right_alias, right)]

  defp column(selecto, alias_name, field) when is_atom(field) or is_binary(field),
    do: [to_string(alias_name), ".", selecto.adapter.quote_identifier(to_string(field))]

  defp column(_selecto, _alias_name, _field),
    do: raise(ArgumentError, "association keys must name declared fields")

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
