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
