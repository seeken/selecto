defmodule Selecto.Phase1IntegrationTest do
  use ExUnit.Case

  test "core CTE modules are available" do
    assert Code.ensure_loaded?(Selecto.Builder.CteSql)
    assert Code.ensure_loaded?(Selecto.Builder.Sql.Hierarchy)
    assert function_exported?(Selecto.Builder.CteSql, :build_with_clause, 1)
    assert function_exported?(Selecto.SQL.Params, :finalize_with_ctes, 1)
  end

  test "the adjacency hierarchy builder renders through the adapter dialect" do
    selecto = %{adapter: SelectoDBPostgreSQL.Adapter}

    {adj_sql, adj_params} =
      Selecto.Builder.Sql.Hierarchy.build_adjacency_list_cte(selecto, :test, %{
        source: "tbl",
        my_key: :id,
        parent_field: :parent_id
      })

    assert IO.iodata_to_binary(adj_sql) =~ ~s(c."parent_id" = h."id")
    assert adj_params == [5]
  end
end
