defmodule Selecto.AssociationAggregate do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M
  alias Selecto.Domain.Contract.ComputedValues, as: V
  alias Selecto.Builder.OwnerKey

  def errors(source, schemas, field, column, spec) do
    association = get(M.map_value(source, :associations), M.map_value(spec, :association))
    target = get(schemas, M.map_value(association, :queryable))
    function = M.map_value(spec, :function) |> to_string()
    value = Selecto.ComputedOwnerKeys.column(target, M.map_value(spec, :field))

    options =
      ~w(kind association function field where default through_owner_keys through_exclude_owner_field)

    valid =
      Enum.all?(Map.keys(spec), &(to_string(&1) in options)) and is_map(association) and
        M.map_value(association, :cardinality) in [:many, "many"] and
        function in ~w(sum count min max) and
        is_map(value) and is_nil(M.map_value(value, :computed)) and
        (function == "count" or Selecto.Analytics.Unit.numeric_type?(M.map_value(value, :type))) and
        if(function == "count",
          do: V.category(M.map_value(column, :type)) == :integer,
          else: Selecto.Analytics.Unit.numeric_type?(M.map_value(column, :type))
        ) and
        (not match?({:ok, _}, M.fetch_key(spec, :default)) or
           is_number(M.map_value(spec, :default))) and
        valid_filter?(target, schemas, M.map_value(spec, :where)) and
        valid_bridge?(source, schemas, association, spec)

    if valid,
      do: [],
      else: [
        %{
          code: :invalid_computed_value,
          path: [:source, :columns, field, :computed],
          message:
            "association aggregate requires governed physical fields and direct to-one filters"
        }
      ]
  end

  defp valid_filter?(_, _, nil), do: true

  defp valid_filter?(target, schemas, filter) do
    with {:ok, _, dependencies} <- V.validate(["case", [filter, ["literal", 1]]]) do
      Enum.all?(dependencies, &physical_path?(target, schemas, String.split(&1, ".")))
    else
      _ -> false
    end
  end

  defp physical_path?(relation, _schemas, [field]),
    do:
      is_map(Selecto.ComputedOwnerKeys.column(relation, field)) and
        is_nil(M.map_value(Selecto.ComputedOwnerKeys.column(relation, field), :computed))

  defp physical_path?(relation, schemas, [name | rest]) do
    association = get(M.map_value(relation, :associations), name)
    target = get(schemas, M.map_value(association, :queryable))

    one =
      M.map_value(association, :cardinality) in [:one, "one"] or
        (is_nil(M.map_value(association, :cardinality)) and
           to_string(M.map_value(association, :related_key)) ==
             to_string(M.map_value(target, :primary_key)))

    is_map(target) and one and is_nil(M.map_value(association, :through)) and
      physical_path?(target, schemas, rest)
  end

  defp valid_bridge?(source, schemas, association, spec) do
    keys = M.map_value(spec, :through_owner_keys)
    exclude = M.map_value(spec, :through_exclude_owner_field)

    if is_nil(keys) and is_nil(exclude) do
      true
    else
      through = M.map_value(association, :through)
      table = M.map_value(through, :table)
      relations = [source | Map.values(schemas || %{})]
      bridge = Enum.find(relations, &(M.map_value(&1, :source_table) == table))
      keys = keys || [M.map_value(through, :owner_key)]
      owner = Selecto.ComputedOwnerKeys.column(source, M.map_value(association, :owner_key))

      is_map(through) and is_map(bridge) and is_list(keys) and length(keys) in 1..8 and
        length(Enum.uniq(keys)) == length(keys) and
        to_string(M.map_value(through, :owner_key)) in Enum.map(keys, &to_string/1) and
        Enum.all?(keys ++ if(is_nil(exclude), do: [], else: [exclude]), fn key ->
          col = Selecto.ComputedOwnerKeys.column(bridge, key)

          is_map(col) and is_nil(M.map_value(col, :computed)) and
            M.map_value(col, :type) == M.map_value(owner, :type)
        end)
    end
  end

  def compile(query, spec, owner_alias) do
    backend = Selecto.AdapterSupport.adapter_name(query.adapter)

    if backend not in [:postgresql, :sqlite, :duckdb] do
      Selecto.Builder.ScopeRefusal.unsupported!(
        Selecto.Error.validation_error(
          "association aggregates are unsupported by this adapter",
          %{code: :unsupported_feature, unsupported_feature: :association_aggregate}
        ),
        :unsupported_feature
      )
    end

    source = OwnerKey.relation(query, owner_alias)

    declared =
      Enum.find(M.map_value(source, :columns) || %{}, fn {_field, column} ->
        M.map_value(column, :computed) == spec
      end)

    valid? =
      case declared do
        {field, column} -> errors(source, query.domain.schemas, field, column, spec) == []
        nil -> false
      end

    unless valid?,
      do:
        Selecto.Builder.ScopeRefusal.unsupported!(
          Selecto.Error.validation_error("invalid declared association aggregate", %{
            code: :invalid_computed_value
          }),
          :invalid_computed_value
        )

    name = M.map_value(spec, :association)
    association = get(M.map_value(source, :associations), name)
    target = get(query.domain.schemas, M.map_value(association, :queryable))

    association =
      Map.merge(
        association,
        Selecto.Schema.Join.association_boundary!(name, association, source, target, query.domain)
      )

    association =
      Map.put(association, :aggregate_owner_keys, M.map_value(spec, :through_owner_keys))
      |> Map.put(:aggregate_exclude_owner_field, M.map_value(spec, :through_exclude_owner_field))

    authored = get(M.map_value(query.domain, :joins), name) || %{}
    nested = M.map_value(authored, :joins) || %{}

    inner =
      Selecto.configure(
        %{
          name: "Association aggregate",
          source: target,
          schemas: query.domain.schemas,
          joins: nested
        },
        query.runtime,
        adapter: query.adapter,
        validate: false
      )

    function = M.map_value(spec, :function) |> to_string()
    field = M.map_value(spec, :field)

    selector =
      case function do
        "count" -> Selecto.Builder.Provenance.internal_selector({:association_count, field})
        "sum" -> {:sum, field}
        "min" -> {:min, field}
        "max" -> {:max, field}
      end

    inner = Selecto.select(inner, [selector])

    inner =
      if M.map_value(spec, :where),
        do:
          Selecto.filter(
            inner,
            Selecto.Domain.Contract.ComputedPredicates.to_filter(M.map_value(spec, :where))
          ),
        else: inner

    correlation =
      Selecto.Builder.Association.predicate(
        query,
        association,
        "selecto_root",
        "selecto_aggregate_owner",
        %{source: source, target: target}
      )

    inner =
      put_in(
        inner.set.filtered,
        inner.set.filtered ++
          [Selecto.Builder.Provenance.generated_filter({:raw_sql_filter, correlation})]
      )

    {sql, _aliases} = Selecto.Builder.Sql.build_iodata(inner, [])
    alias_name = "selecto_aggregate_" <> to_string(name)

    sql =
      sql
      |> OwnerKey.rename("selecto_root", alias_name)
      |> OwnerKey.rename("selecto_aggregate_owner", to_string(owner_alias))

    value = ["(", sql, ")"]

    value =
      case M.fetch_key(spec, :default) do
        {:ok, default} -> ["COALESCE(", value, ", ", {:param, default}, ")"]
        :error -> value
      end

    {value, [owner_alias], []}
  end

  defp get(map, key) do
    case M.fetch_key(map, key) do
      {:ok, value} -> value
      _ -> nil
    end
  end
end
