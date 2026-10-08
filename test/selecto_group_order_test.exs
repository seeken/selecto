defmodule Selecto.GroupOrderTest do
  use ExUnit.Case

  defmodule NoRollupAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(:rollup), do: false
    def supports?(_feature), do: false
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
  end

  defmodule WholeQueryRollupAdapter do
    defdelegate connect(connection), to: NoRollupAdapter
    defdelegate quote_identifier(identifier), to: NoRollupAdapter
    def supports?(:rollup), do: true
    def supports?(_feature), do: false
    def placeholder(index), do: "$#{index}"

    def render_rollup(selecto, opts) do
      send(self(), {:rollup_rendered, selecto.set.group_by, opts})

      {["SELECT '? $1', ", {:param, "first"}, ", ", {:param, "second"}], ["rolled"],
       [:dimension_join]}
    end
  end

  test "whole-query rollup rendering keeps structural binds, aliases and joins" do
    query = rollup_dispatch_query()

    assert {"SELECT '? $1', $1, $2", ["rolled"], ["first", "second"], [:dimension_join]} =
             Selecto.Builder.Sql.build_with_joins(query, unique_projection_aliases: true)

    assert_received {:rollup_rendered, [rollup: ["region"]], [unique_projection_aliases: true]}

    assert {"SELECT '? $1', $1, $2", ["rolled"], ["first", "second"]} =
             Selecto.Builder.Sql.build(query, [])
  end

  test "whole-query rollup callback is skipped for ordinary grouping" do
    query = put_in(rollup_dispatch_query().set.group_by, ["region"])
    assert {sql, _, []} = Selecto.Builder.Sql.build(query, [])
    assert sql =~ "group by selecto_root.region"
    refute_received {:rollup_rendered, _, _}
  end

  test "strict query policy is validated before whole-query adapter dispatch" do
    query = rollup_dispatch_query(mode: :strict)
    query = put_in(query.set.filtered, [{:raw_sql_filter, "1 = 1"}])
    assert_raise Selecto.PolicyViolation, fn -> Selecto.Builder.Sql.build(query, []) end
    refute_received {:rollup_rendered, _, _}
  end

  defp rollup_dispatch_query(opts \\ []) do
    domain = %{
      name: "Sales",
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region],
        redact_fields: [],
        columns: %{id: %{type: :integer}, region: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    Selecto.configure(
      domain,
      :mock_connection,
      Keyword.put(opts, :adapter, WholeQueryRollupAdapter)
    )
    |> Selecto.select(["region"])
    |> Selecto.group_by(rollup: ["region"])
  end

  test "GROUP BY and ORDER BY with new iodata parameterization (phase 2)" do
    # Domain configuration
    domain = %{
      source: %{
        source_table: "users",
        primary_key: :id,
        fields: [:id, :name, :email, :age],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          email: %{type: :string},
          age: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "User"
    }

    selecto = Selecto.configure(domain, :mock_connection)

    # Test with GROUP BY and ORDER BY
    selecto =
      selecto
      |> Selecto.select([{:count}])
      |> Selecto.group_by(["age"])
      |> Selecto.order_by([{"age", :desc}])

    {sql, aliases, params} = Selecto.gen_sql(selecto, [])

    # Verify SQL structure
    assert String.contains?(sql, "select")
    assert String.contains?(sql, "count(*)")
    assert String.contains?(sql, "group by")
    assert String.contains?(sql, "order by")
    assert String.contains?(sql, "selecto_root.age")
    assert String.contains?(sql, "desc")

    # Verify no legacy sentinel remains
    refute String.contains?(sql, "^SelectoParam^")

    # Verify params structure (should be empty for this query)
    assert is_list(params)

    # Verify aliases structure  
    assert is_list(aliases)
    # count(*)
    assert length(aliases) == 1
  end

  test "ROLLUP fails closed for adapters without rollup rendering" do
    domain = %{
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :amount],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          region: %{type: :string},
          amount: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "Sales"
    }

    selecto =
      Selecto.configure(domain, :mock_connection, adapter: NoRollupAdapter, validate: false)

    selecto =
      selecto
      |> Selecto.select([{:sum, "amount"}])
      |> Selecto.group_by(rollup: ["region"])
      |> Selecto.order_by([{"region", :asc}])

    assert_raise ArgumentError,
                 ~r/does not implement rollup rendering/,
                 fn -> Selecto.gen_sql(selecto, []) end
  end

  test "ROLLUP supports linked grouping-set steps" do
    domain = %{
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :city, :state, :amount],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          region: %{type: :string},
          city: %{type: :string},
          state: %{type: :string},
          amount: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "Sales"
    }

    selecto =
      Selecto.configure(domain, :mock_connection,
        adapter: SelectoDBPostgreSQL.Adapter,
        rollup_sort_fix: false,
        validate: false
      )
      |> Selecto.select([{:sum, "amount"}])
      |> Selecto.group_by(rollup: ["region", {:grouping_set, ["city", "state"]}])

    {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])
    sql = String.downcase(sql)

    assert sql =~ "group by"
    assert sql =~ "rollup"
    assert sql =~ "(selecto_root.city, selecto_root.state)"
  end

  test "ROLLUP positional ordering preserves explicit directions" do
    domain = %{
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :city, :amount],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          region: %{type: :string},
          city: %{type: :string},
          amount: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "Sales"
    }

    selecto =
      Selecto.configure(domain, :mock_connection,
        adapter: SelectoDBPostgreSQL.Adapter,
        rollup_sort_fix: true,
        validate: false
      )
      |> Selecto.select(["region", "city", {:sum, "amount"}])
      |> Selecto.group_by(rollup: ["region", "city"])
      |> Selecto.order_by([
        {"region", :asc_nulls_last},
        {"city", :desc_nulls_first}
      ])

    {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])
    sql = String.downcase(sql)

    assert sql =~ "order by 1 asc nulls last, 2 desc nulls first"
  end

  defp orders_selecto do
    domain = %{
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :person_id, :state, :total],
        redact_fields: [:total],
        columns: %{
          id: %{type: :integer},
          person_id: %{type: :integer},
          state: %{type: :string},
          total: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      name: "Orders"
    }

    Selecto.configure(domain, :mock_connection,
      adapter: SelectoDBPostgreSQL.Adapter,
      rollup_sort_fix: false,
      validate: false
    )
  end

  test "a one-dimensional ROLLUP selects a GROUPING marker over its dimension" do
    {sql, _aliases, params} =
      orders_selecto()
      |> Selecto.select([
        "state",
        {:field, {:count, "*"}, "order_count"},
        {:field, {:grouping, ["state"]}, "grouping_marker"}
      ])
      |> Selecto.group_by(rollup: ["state"])
      |> Selecto.gen_sql([])

    sql = String.downcase(sql)

    assert sql =~ "select selecto_root.state, count(*), grouping(selecto_root.state)\n"
    assert sql =~ "group by rollup( selecto_root.state )"
    assert params == []
  end

  test "a two-dimensional ROLLUP marker covers both dimensions in order" do
    {sql, _aliases, _params} =
      orders_selecto()
      |> Selecto.select([
        "state",
        "person_id",
        {:field, {:count, "*"}, "order_count"},
        {:field, {:grouping, ["state", "person_id"]}, "grouping_marker"}
      ])
      |> Selecto.group_by(rollup: ["state", "person_id"])
      |> Selecto.gen_sql([])

    sql = String.downcase(sql)

    assert sql =~ "grouping(selecto_root.state, selecto_root.person_id)\n"
    assert sql =~ "group by rollup( selecto_root.state, selecto_root.person_id )"
  end

  test "a GROUPING marker refuses unknown and redacted fields" do
    for field <- ["missing", "total"] do
      assert_raise RuntimeError, ~r/Field .#{field}. not found/, fn ->
        orders_selecto()
        |> Selecto.select(["state", {:field, {:grouping, ["state", field]}, "marker"}])
        |> Selecto.group_by(rollup: ["state"])
        |> Selecto.gen_sql([])
      end
    end
  end
end
