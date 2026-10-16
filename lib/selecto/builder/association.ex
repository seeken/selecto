defmodule Selecto.Builder.Association do
  @moduledoc false

  alias Selecto.Builder.ExactCompare

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
        type when type in [:string, "string"] -> key_cast(selecto, target_key, "string")
        type when type in [:integer, "integer"] -> key_cast(selecto, target_key, "integer")
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

  # MySQL and MariaDB have no TEXT or INTEGER cast target; their dialects
  # render the canonical computed-value cast instead.
  defp key_cast(selecto, key, type) do
    if Selecto.AdapterSupport.adapter_name(selecto.adapter) in [:mysql, :mariadb] do
      fragment = %Selecto.Dialect.ComputedValue{operation: :cast, expression: key, type: type}

      case Selecto.DialectSupport.render_computed_value(selecto.adapter, fragment, selecto) do
        {:ok, sql} -> sql
        {:error, %Selecto.Error{} = error} -> raise Selecto.Error.to_exception(error)
        {:error, reason} -> raise ArgumentError, "unsupported key cast: #{inspect(reason)}"
      end
    else
      ["CAST(", key, if(type == "string", do: " AS TEXT)", else: " AS INTEGER)")]
    end
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
  # A scoped root that declares tenant_field pairs the target with the root
  # row: with the root's tenant_field in a one-column domain, by name in a
  # two-column domain. A retargeted query of a scoped origin binds the target
  # to the origin's admitted values of that column. A scoped query that can do
  # neither is refused.
  def carried_tenant(selecto, target_alias, field) do
    field = to_string(field)

    cond do
      Selecto.Tenant.unprovable_scope?(selecto) ->
        raise Selecto.PolicyViolation,
          type: :missing_tenant_scope,
          message:
            "relation tenant field #{inspect(field)} is reached across an untenanted hop " <>
              "and the query's tenant predicate cannot be carried onto it"

      not Selecto.Tenant.scoped?(selecto) ->
        []

      column = Selecto.Tenant.source_tenant_column(selecto, field) ->
        ExactCompare.eq(
          column(selecto, target_alias, field),
          column(selecto, "selecto_root", column),
          ExactCompare.column?(selecto, field) or ExactCompare.column?(selecto, column)
        )

      match?({:ok, _}, Selecto.Retarget.origin_column_query(selecto, field)) ->
        {:ok, query} = Selecto.Retarget.origin_column_query(selecto, field)

        exact? = ExactCompare.column?(selecto, field)

        ExactCompare.in_subquery(
          column(selecto, target_alias, field),
          ["(", Selecto.Builder.Sql.Where.subquery_iodata(query), ")"],
          if(exact?, do: Selecto.Builder.Sql.Where.exact_subquery_iodata(query)),
          exact?
        )

      true ->
        raise Selecto.PolicyViolation,
          type: :missing_tenant_scope,
          message:
            "relation tenant field #{inspect(field)} is reached across an untenanted hop " <>
              "and the query tenant scope cannot be carried onto it"
    end
  end

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
        ExactCompare.eq(
          column(selecto, alias_name, field),
          {:param, value},
          ExactCompare.column?(selecto, field)
        )

      _ ->
        raise ArgumentError, "association policy requires scalar equality values"
    end)
  end

  defp policies(_selecto, _alias_name, _policy),
    do: raise(ArgumentError, "association where policy must be a map")

  # Tenant/site columns pair exactly on MySQL and MariaDB
  # (Selecto.Builder.ExactCompare); other columns and adapters as before.
  defp equality(selecto, left_alias, left, right_alias, right),
    do:
      ExactCompare.eq(
        column(selecto, left_alias, left),
        column(selecto, right_alias, right),
        ExactCompare.column?(selecto, left) or ExactCompare.column?(selecto, right)
      )

  defp column(selecto, alias_name, field) when is_atom(field) or is_binary(field),
    do: [to_string(alias_name), ".", selecto.adapter.quote_identifier(to_string(field))]

  defp column(_selecto, _alias_name, _field),
    do: raise(ArgumentError, "association keys must name declared fields")

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
