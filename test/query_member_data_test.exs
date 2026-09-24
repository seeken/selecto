defmodule Selecto.QueryMemberDataTest do
  use ExUnit.Case, async: true

  defp relation(table, columns) do
    %{
      source_table: table,
      primary_key: :id,
      fields: columns |> Map.keys() |> Enum.sort(),
      redact_fields: [],
      columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
      associations: %{}
    }
  end

  defp domain(members \\ %{}) do
    %{
      name: "People",
      source: relation("people", %{id: :integer, name: :string, team_id: :integer}),
      schemas: %{
        order:
          relation("orders", %{id: :integer, person_id: :integer, total: :decimal, state: :string}),
        team: relation("teams", %{id: :integer, parent_id: :integer, name: :string})
      },
      joins: %{},
      query_members:
        Map.merge(
          %{
            ctes: %{
              order_totals: %{
                source: "order",
                query: %{
                  "select" => [
                    "person_id",
                    %{"as" => "orders", "aggregate" => "count"},
                    %{"as" => "spent", "aggregate" => "sum", "field" => "total"}
                  ],
                  "filter" => ["ne", "state", "void"],
                  "group_by" => ["person_id"]
                },
                join: %{owner_key: "id", related_key: "person_id", type: "left"}
              },
              team_tree: %{
                kind: "recursive",
                source: "team",
                base: %{
                  "select" => [
                    "id",
                    "parent_id",
                    "name",
                    %{"as" => "depth", "value" => ["literal", 0, "integer"]}
                  ],
                  "filter" => ["is_null", "parent_id"]
                },
                step: %{
                  "select" => [
                    "id",
                    "parent_id",
                    "name",
                    %{"as" => "depth", "value" => ["add", ["previous", "depth"], ["literal", 1]]}
                  ]
                },
                step_join: %{owner_key: "parent_id", related_key: "id"},
                join: %{owner_key: "team_id", related_key: "id", type: "inner"}
              }
            },
            laterals: %{
              latest_order: %{
                source: "order",
                query: %{
                  "select" => ["id", "total"],
                  "order_by" => [["id", "desc"]],
                  "limit" => 1
                },
                correlations: %{person_id: "id"},
                join_type: "left"
              }
            }
          },
          members
        )
    }
  end

  defp sql(query) do
    {sql, _aliases, params} = Selecto.gen_sql(query, [])
    {sql, params}
  end

  test "data members validate with the canonical contract" do
    assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate(domain())
  end

  test "a CTE member compiles from data" do
    {sql, params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.with_cte(:order_totals)
      |> Selecto.select(["name", "order_totals.orders", "order_totals.spent"])
      |> sql()

    assert sql =~ "WITH order_totals"
    assert sql =~ ~r/count\(\*\)/i
    assert "void" in params
  end

  test "a recursive member reads the previous level" do
    {sql, _params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.with_cte(:team_tree)
      |> Selecto.select(["name", "team_tree.depth"])
      |> sql()

    assert sql =~ "WITH RECURSIVE team_tree"
    assert sql =~ ~r/team_tree"?\.\"?depth"? \+ CAST/
  end

  test "a lateral member compiles from data" do
    {sql, _params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.with_lateral(:latest_order)
      |> Selecto.select(["name", "latest_order.total"])
      |> sql()

    assert sql =~ ~r/LEFT JOIN LATERAL/i
    assert sql =~ ~r/limit 1/i
  end

  test "previous outside a recursive step is rejected" do
    bad = %{
      ctes: %{
        bad: %{
          source: "order",
          query: %{"select" => [%{"as" => "x", "value" => ["previous", "id"]}]},
          join: %{owner_key: "id", related_key: "x"}
        }
      }
    }

    assert {:error, _} = Selecto.Domain.validate(domain(bad))
  end
end
