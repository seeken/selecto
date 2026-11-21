defmodule Selecto.AssociationJoinConditionsTest do
  # Association `conditions` (certification profile engine_join_conditions,
  # JC001-JC004): owner/target comparisons ANDed after the key equality
  # wherever the association is joined.
  use ExUnit.Case, async: true

  defmodule ExactAdapter do
    @moduledoc false
    def name, do: :exact_test
    def supports?(feature), do: feature in [:exact_tenant_compare, :right_join, :full_join]
    def quote_identifier(identifier), do: "`#{String.replace(identifier, "`", "``")}`"
    def placeholder(_index), do: "?"
  end

  @conditions [
    %{left: :ordered_on, op: :gte, right: :valid_from},
    %{left: "ordered_on", op: "LT", right: "valid_to", open: 1},
    %{left: :code, op: :ne, right: :code}
  ]

  defp relation(table, columns, associations \\ %{}) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Keyword.keys(columns),
      redact_fields: [],
      tenant_field: :tenant_id,
      columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
      associations: associations
    }
  end

  defp domain(opts \\ []) do
    association =
      Map.merge(
        %{
          queryable: :prices,
          field: :price,
          owner_key: :product_id,
          related_key: :product_id,
          conditions: @conditions
        },
        Map.new(Keyword.get(opts, :association, []))
      )

    %{
      name: "Orders",
      source:
        relation(
          "orders",
          [
            id: :integer,
            product_id: :integer,
            ordered_on: :date,
            code: :string,
            quantity: :integer,
            tenant_id: :integer
          ],
          %{price: association}
        ),
      schemas: %{
        prices:
          relation(
            "prices",
            [
              id: :integer,
              product_id: :integer,
              currency_id: :integer,
              valid_from: :date,
              valid_to: :date,
              amount: :decimal,
              code: :string,
              published: :boolean,
              tenant_id: :integer
            ],
            %{
              currency: %{
                queryable: :currencies,
                field: :currency,
                owner_key: :currency_id,
                related_key: :id,
                conditions: [%{left: :valid_from, op: :gte, right: :since, open: true}]
              }
            }
          ),
        currencies:
          relation("currencies", id: :integer, since: :date, label: :string, tenant_id: :integer)
      },
      joins: %{
        price: %{
          type: Keyword.get(opts, :type, :left),
          joins: %{currency: %{type: :left}}
        }
      }
    }
  end

  defp sql(domain, adapter \\ SelectoDBPostgreSQL.Adapter, fields \\ ["id", "price.amount"]) do
    domain
    |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
    |> Selecto.with_tenant(7)
    |> Selecto.select(fields)
    |> Selecto.to_sql()
  end

  defp errors(domain) do
    case Selecto.Domain.validate(domain) do
      {:ok, _normalized, _diagnostics} -> []
      {:error, diagnostics} -> diagnostics.errors
    end
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, v} -> {to_string(key), stringify(v)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp stringify(value), do: value

  describe "validation" do
    test "a valid list validates natively and as strict JSON" do
      assert [] == errors(domain())
      assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate_json(stringify(domain()))
    end

    test "each rule refuses with invalid_join_conditions at the association path" do
      cases = [
        {[], "must be a non-empty array"},
        {List.duplicate(%{left: :id, op: :eq, right: :id}, 9), "at most 8 entries"},
        {[%{left: :id, op: :eq, right: :id, extra: 1}],
         "entries take only left, op, right and open"},
        {[%{left: :id, op: :like, right: :id}], "operator like is not one of"},
        {[%{left: :nope, op: :eq, right: :id}], "owner field nope is not a field"},
        {[%{left: :id, op: :eq, right: :nope}], "target field nope is not a field"},
        {[%{left: :ordered_on, op: :eq, right: :amount}], "of different types"},
        {[%{left: :code, op: :lt, right: :code}], "lt compares numbers, dates and times only"},
        {[%{left: :code, op: :eq, right: :code, open: true}], "open is available only with"},
        {[%{left: :ordered_on, op: :lt, right: :valid_to, open: "yes"}],
         "open must be a boolean"},
        {[%{left: nil, op: :eq, right: :id}], "entries require a string left"},
        {["id"], "entries must be objects"}
      ]

      for {conditions, message} <- cases do
        assert [error] = errors(domain(association: [conditions: conditions])),
               "#{inspect(conditions)} validated"

        assert error.code == :invalid_join_conditions
        assert error.path == [:source, :associations, :price, :conditions]
        assert error.message =~ message, "#{error.message} !~ #{message}"
      end
    end

    test "redacted fields, through and values associations refuse" do
      redacted = domain() |> Map.put(:redact_fields, ["price.code"])
      assert [%{message: message}] = errors(redacted)
      assert message =~ "target field code is redacted"

      owner_redacted = put_in(domain(), [:source, :redact_fields], [:code])
      assert [%{message: message}] = errors(owner_redacted)
      assert message =~ "owner field code is redacted"

      through = domain(association: [through: [:price, :currency]])
      assert Enum.any?(errors(through), &(&1.message =~ "not available on a through association"))
    end

    test "a nested schema association validates at its own path" do
      bad =
        put_in(
          domain(),
          [:schemas, :prices, :associations, :currency, :conditions],
          [%{left: :valid_from, op: :gte, right: :label}]
        )

      assert [error] = errors(bad)
      assert error.path == [:schemas, :prices, :associations, :currency, :conditions]
    end
  end

  describe "SQL" do
    test "left and inner joins AND the conditions after the key equality" do
      for {type, keyword} <- [left: "left join", inner: "inner join"] do
        {sql, params} = sql(domain(type: type))

        assert sql =~
                 ~s(#{keyword} prices price on price.product_id = selecto_root.product_id ) <>
                   ~s(and selecto_root."ordered_on" >= price."valid_from" ) <>
                   ~s(and \(price."valid_to" IS NULL OR selecto_root."ordered_on" < price."valid_to"\) ) <>
                   ~s(and NOT \(selecto_root."code" = price."code"\) ) <>
                   ~s(and selecto_root.tenant_id = price.tenant_id)

        assert params == [7]
      end
    end

    test "right and full joins keep the conditions in ON and bind the preserved target's tenant" do
      for {type, keyword} <- [right: "right join", full: "full join"] do
        {sql, params} = sql(domain(type: type))

        assert sql =~
                 ~s[#{keyword} (select * from prices price where price."tenant_id" = $1) price ] <>
                   ~s[on price.product_id = selecto_root.product_id and selecto_root."ordered_on" >= price."valid_from"]

        # The tenant id binds typed, like the root's own tenant filter.
        assert params == [7, 7]
      end

      {_sql, params} =
        domain(type: :right)
        |> Selecto.configure(
          Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only),
          validate: false
        )
        |> Selecto.with_tenant("7")
        |> Selecto.select(["id", "price.amount"])
        |> Selecto.to_sql()

      assert params == [7, 7]
    end

    test "a nested join renders its own conditions" do
      {sql, _params} = sql(domain(), SelectoDBPostgreSQL.Adapter, ["id", "currency.label"])

      assert sql =~
               ~s[left join currencies currency on currency.id = price.currency_id ] <>
                 ~s[and (currency."since" IS NULL OR price."valid_from" >= currency."since") ] <>
                 ~s[and price.tenant_id = currency.tenant_id]
    end

    test "a subselect correlates with the conditions" do
      {sql, _params} =
        domain()
        |> put_in([:source, :associations, :price, :cardinality], :many)
        |> Map.put(:joins, %{})
        |> Selecto.configure(
          Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only),
          validate: false
        )
        |> Selecto.with_tenant(7)
        |> Selecto.select(["id"])
        |> Selecto.subselect([
          %{
            fields: ["amount"],
            target_schema: :prices,
            format: :count,
            alias: "prices",
            join_path: [:price]
          }
        ])
        |> Selecto.to_sql()

      assert sql =~
               ~s[WHERE sub_prices."product_id" = selecto_root."product_id" ] <>
                 ~s[AND selecto_root."ordered_on" >= sub_prices."valid_from" ] <>
                 ~s[AND (sub_prices."valid_to" IS NULL OR selecto_root."ordered_on" < sub_prices."valid_to") ] <>
                 ~s[AND NOT (selecto_root."code" = sub_prices."code") ] <>
                 ~s[AND sub_prices."tenant_id" = selecto_root."tenant_id"]
    end

    test "text eq/ne compare exactly on MySQL-family adapters" do
      {sql, _params} = sql(domain(), ExactAdapter)

      assert sql =~
               "NOT ((selecto_root.`code` = price.`code` AND " <>
                 "CAST(CONVERT(selecto_root.`code` USING utf8mb4) AS BINARY) = " <>
                 "CAST(CONVERT(price.`code` USING utf8mb4) AS BINARY)))"
    end

    test "a domain without conditions compiles as before" do
      plain = update_in(domain(), [:source, :associations, :price], &Map.delete(&1, :conditions))
      {sql, _params} = sql(plain)

      assert sql =~
               ~s(left join prices price on price.product_id = selecto_root.product_id and selecto_root.tenant_id = price.tenant_id\n)
    end
  end

  describe "contract_json" do
    test "open exports as a JSON boolean and the rest keeps its form" do
      assert {:ok, contract} = Selecto.Domain.contract_json(domain())

      assert contract["source"]["associations"]["price"]["conditions"] == [
               %{"left" => "ordered_on", "op" => "gte", "right" => "valid_from"},
               %{"left" => "ordered_on", "op" => "LT", "right" => "valid_to", "open" => true},
               %{"left" => "code", "op" => "ne", "right" => "code"}
             ]

      assert [%{"open" => true}] =
               contract["schemas"]["prices"]["associations"]["currency"]["conditions"]

      assert "conditions" in Selecto.Domain.contract_keys().association
    end
  end
end
