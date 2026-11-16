defmodule Selecto.Builder.LateralJoinTest do
  use ExUnit.Case, async: true

  alias Selecto.Advanced.LateralJoin.Spec
  alias Selecto.Builder.LateralJoin
  alias Selecto.TestSQLParams, as: Params

  defmodule LoweringDialect do
    @behaviour Selecto.DB.Dialect
    @impl true
    def render_lateral_subquery(%{options: %{query: child}}, parent) do
      send(self(), {:structured_lateral, child, parent})
      {:ok, ["LEFT JOIN lowered ON ", {:param, "selecto_root.literal?"}]}
    end
  end

  defmodule LoweringAdapter do
    def dialect, do: Selecto.Builder.LateralJoinTest.LoweringDialect
  end

  test "optional lowering receives the original child AST before SQL compilation" do
    parent = %Selecto{set: %{}}
    child = %Selecto{set: %{selected: ["would need a real compiler"]}}
    spec = %Spec{join_type: :left, alias: "child", subquery_builder: fn ^parent -> child end}

    assert {iodata, []} =
             LateralJoin.build_lateral_join(spec, adapter: LoweringAdapter, selecto: parent)

    assert iodata == ["LEFT JOIN lowered ON ", {:param, "selecto_root.literal?"}]
    assert_received {:structured_lateral, ^child, ^parent}
  end

  defp to_sql(iodata) do
    {sql, _params} = Params.finalize(iodata)
    sql
  end

  test "table-function lateral join builds iodata" do
    spec = %Spec{
      id: "lat1",
      join_type: :inner,
      subquery_builder: nil,
      table_function: {:unnest, "film.special_features"},
      alias: "features",
      correlation_refs: ["film.special_features"],
      validated: true
    }

    {sql_iodata, params} = LateralJoin.build_lateral_join(spec)
    sql = to_sql(sql_iodata)

    assert sql =~ "JOIN LATERAL"
    assert sql =~ "UNNEST(film.special_features)"
    assert params == []
  end

  test "build_lateral_joins returns all SQL parts" do
    specs = [
      %Spec{
        id: "lat1",
        join_type: :inner,
        subquery_builder: nil,
        table_function: {:unnest, "film.special_features"},
        alias: "features",
        correlation_refs: [],
        validated: true
      },
      %Spec{
        id: "lat2",
        join_type: :left,
        subquery_builder: nil,
        table_function: {:function, :generate_series, [1, 5]},
        alias: "numbers",
        correlation_refs: [],
        validated: true
      }
    ]

    {sql_parts, params} = LateralJoin.build_lateral_joins(specs)
    assert length(sql_parts) == 2
    assert is_list(params)
  end

  test "mysql json_table compiles as join without lateral keyword" do
    spec = %Spec{
      id: "lat_json",
      join_type: :inner,
      subquery_builder: nil,
      table_function:
        {:json_table, "selecto_root.line_items", "$[*]",
         [
           %{name: "position", for_ordinality: true, type: :integer},
           %{name: "sku", path: "$.sku", type: :string},
           %{name: "quantity", path: "$.quantity", type: :integer}
         ]},
      alias: "item_rows",
      correlation_refs: ["selecto_root.line_items"],
      validated: true
    }

    {sql_iodata, params} = LateralJoin.build_lateral_join(spec, adapter: SelectoDBMySQL.Adapter)
    {sql, finalized_params} = Params.finalize(sql_iodata, adapter: SelectoDBMySQL.Adapter)

    assert params == []
    assert finalized_params == []
    assert sql =~ "INNER JOIN JSON_TABLE(selecto_root.line_items"
    assert sql =~ "position FOR ORDINALITY"
    assert sql =~ "sku VARCHAR(255) PATH '$.sku'"
    assert sql =~ "quantity INTEGER PATH '$.quantity'"
    refute sql =~ "JOIN LATERAL"
  end

  test "json_table fails explicitly on unsupported adapters" do
    spec = %Spec{
      id: "lat_json",
      join_type: :inner,
      subquery_builder: nil,
      table_function:
        {:json_table, "selecto_root.line_items", "$[*]", [%{name: "sku", path: "$.sku"}]},
      alias: "item_rows",
      correlation_refs: ["selecto_root.line_items"],
      validated: true
    }

    assert_raise Selecto.Builder.ScopeRefusal, ~r/does not support JSON_TABLE joins/, fn ->
      LateralJoin.build_lateral_join(spec, adapter: SelectoDBSQLite.Adapter)
    end
  end

  test "sqlite json_each compiles as join without lateral keyword" do
    spec = %Spec{
      id: "lat_json_each",
      join_type: :inner,
      subquery_builder: nil,
      table_function: {:json_each, "selecto_root.line_items", "$[*]"},
      alias: "item_rows",
      correlation_refs: ["selecto_root.line_items"],
      validated: true
    }

    {sql_iodata, params} = LateralJoin.build_lateral_join(spec, adapter: SelectoDBSQLite.Adapter)
    {sql, finalized_params} = Params.finalize(sql_iodata, adapter: SelectoDBSQLite.Adapter)

    assert params == ["$[*]"]
    assert finalized_params == ["$[*]"]

    assert sql =~
             ~r/INNER JOIN JSON_EACH\(selecto_root\.line_items, \?\) AS item_rows ON true/i

    refute sql =~ "JOIN LATERAL"
  end

  test "sqlite json_tree compiles without explicit path when omitted" do
    spec = %Spec{
      id: "lat_json_tree",
      join_type: :left,
      subquery_builder: nil,
      table_function: {:json_tree, "selecto_root.line_items", nil},
      alias: "item_tree",
      correlation_refs: ["selecto_root.line_items"],
      validated: true
    }

    {sql_iodata, params} = LateralJoin.build_lateral_join(spec, adapter: SelectoDBSQLite.Adapter)
    {sql, finalized_params} = Params.finalize(sql_iodata, adapter: SelectoDBSQLite.Adapter)

    assert params == []
    assert finalized_params == []
    assert sql =~ "LEFT JOIN JSON_TREE(selecto_root.line_items) AS item_tree ON true"
    refute sql =~ "JOIN LATERAL"
  end

  test "sqlite json rowset fails explicitly on unsupported adapters" do
    spec = %Spec{
      id: "lat_json_each",
      join_type: :inner,
      subquery_builder: nil,
      table_function: {:json_each, "selecto_root.line_items", "$[*]"},
      alias: "item_rows",
      correlation_refs: ["selecto_root.line_items"],
      validated: true
    }

    assert_raise Selecto.Builder.ScopeRefusal,
                 ~r/does not support SQLite JSON rowset joins/i,
                 fn ->
                   LateralJoin.build_lateral_join(spec, adapter: SelectoDBMySQL.Adapter)
                 end
  end

  test "unsupported adapters fail explicitly" do
    spec = %Spec{
      id: "lat1",
      join_type: :left,
      subquery_builder: nil,
      table_function: {:unnest, "film.special_features"},
      alias: "features",
      correlation_refs: [],
      validated: true
    }

    refusal =
      assert_raise Selecto.Builder.ScopeRefusal,
                   ~r/does not support this collection operation/,
                   fn ->
                     LateralJoin.build_lateral_join(spec, adapter: SelectoDBSQLite.Adapter)
                   end

    assert refusal.reason == :lateral_unsupported
  end

  test "integrates lateral joins into base SQL" do
    base_sql = ["SELECT film.title", " FROM film"]

    specs = [
      %Spec{
        id: "lat1",
        join_type: :left,
        subquery_builder: nil,
        table_function: {:unnest, "film.special_features"},
        alias: "features",
        correlation_refs: [],
        validated: true
      }
    ]

    {updated_sql, _params} = LateralJoin.integrate_lateral_joins_sql(base_sql, specs)
    combined = IO.iodata_to_binary(updated_sql)

    assert combined =~ "JOIN LATERAL"
    assert combined =~ "features"
  end
end
