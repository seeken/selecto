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

  test "runtime member identifiers obey the bounded interner's byte limit" do
    identifier = "member_#{System.unique_integer([:positive])}" <> String.duplicate("ø", 128)
    base = Selecto.configure(domain(), :compile_only)
    ordinary = put_in(domain().query_members.ctes.order_totals, [:join, :owner_key], identifier)

    assert_raise ArgumentError, ~r/255-byte runtime limit/, fn ->
      Selecto.QueryMembers.Data.to_runtime(base, :ctes, "orders", ordinary)
    end

    recursive =
      Selecto.QueryMembers.Data.to_runtime(
        base,
        :ctes,
        identifier,
        domain().query_members.ctes.team_tree
      )

    assert_raise ArgumentError, ~r/255-byte runtime limit/, fn ->
      recursive.recursive_query.(nil)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
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

  describe "recursion depth" do
    defp team_tree_sql(member_overrides) do
      members = %{
        ctes: %{team_tree: Map.merge(domain().query_members.ctes.team_tree, member_overrides)}
      }

      domain(members)
      |> Selecto.configure(:compile_only)
      |> Selecto.with_cte(:team_tree)
      |> Selecto.select(["name", "team_tree.depth"])
      |> sql()
    end

    test "a recursive member is bounded at 100 levels by default" do
      {sql, _params} = team_tree_sql(%{})

      assert sql =~ "team_tree (id, parent_id, name, depth, selecto_depth) AS ("
      assert sql =~ "1 AS selecto_depth"
      assert sql =~ "team_tree.selecto_depth + 1"
      assert sql =~ "team_tree.selecto_depth < 100"
    end

    test "a recursive member declares its own max_depth" do
      {sql, _params} = team_tree_sql(%{max_depth: 7})
      assert sql =~ "team_tree.selecto_depth < 7"
      assert {:ok, _, _} = Selecto.Domain.validate(domain(%{ctes: %{t: tree_member(7)}}))

      for bad <- [0, 10_001, "7"] do
        assert {:error, _} = Selecto.Domain.validate(domain(%{ctes: %{t: tree_member(bad)}}))
      end
    end

    defp tree_member(max_depth),
      do: Map.put(domain().query_members.ctes.team_tree, :max_depth, max_depth)
  end

  describe "tenant scope" do
    defp tenant_domain do
      tenant_scoped = fn relation ->
        %{
          relation
          | fields: Enum.sort([:tenant_id | relation.fields]),
            columns: Map.put(relation.columns, :tenant_id, %{type: :integer})
        }
        |> Map.put(:tenant_field, :tenant_id)
      end

      domain()
      |> Map.update!(:source, tenant_scoped)
      |> update_in([:schemas, :order], tenant_scoped)
      |> update_in([:schemas, :team], tenant_scoped)
    end

    defp tenant_query do
      tenant_domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
      |> Selecto.apply_tenant_scope()
    end

    test "a CTE member over a tenant-scoped schema carries the root tenant" do
      {sql, params} =
        tenant_query()
        |> Selecto.with_cte(:order_totals)
        |> Selecto.select(["name", "order_totals.spent"])
        |> sql()

      [member, _root] = split_member(sql)
      assert member =~ "cte_order_totals.tenant_id = $"
      assert sql =~ "selecto_root.tenant_id = $"
      assert Enum.count(params, &(&1 == 7)) == 2
    end

    test "the tenant applied after the member is added still scopes the member" do
      {sql, params} =
        tenant_domain()
        |> Selecto.configure(:compile_only)
        |> Selecto.with_cte(:order_totals)
        |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
        |> Selecto.apply_tenant_scope()
        |> Selecto.select(["name", "order_totals.spent"])
        |> sql()

      [member, _root] = split_member(sql)
      assert member =~ "cte_order_totals.tenant_id = $"
      assert Enum.count(params, &(&1 == 7)) == 2
    end

    test "both levels of a recursive member carry the root tenant" do
      {sql, params} =
        tenant_query()
        |> Selecto.with_cte(:team_tree)
        |> Selecto.select(["name", "team_tree.depth"])
        |> sql()

      [member, _root] = split_member(sql)
      [base, step] = String.split(member, "UNION ALL")
      assert base =~ "cte_team_tree.tenant_id = $"
      assert step =~ "cte_team_tree.tenant_id = $"
      assert Enum.count(params, &(&1 == 7)) == 3
    end

    test "a lateral member carries the root tenant" do
      {sql, params} =
        tenant_query()
        |> Selecto.with_lateral(:latest_order)
        |> Selecto.select(["name", "latest_order.total"])
        |> sql()

      [lateral] = Regex.run(~r/LATERAL \((.*)\) AS latest_order/s, sql, capture: :all_but_first)
      assert lateral =~ ~r/subq_root_orders\.tenant_id = \$\d/
      assert Enum.count(params, &(&1 == 7)) == 2
    end

    test "a scoped root whose scope has no tenant condition fails closed" do
      scoped =
        tenant_domain()
        |> Selecto.configure(:compile_only)
        |> Selecto.require_tenant_filter({"name", "Ann"})

      assert_raise Selecto.PolicyViolation, ~r/tenant/, fn ->
        scoped |> Selecto.with_cte(:order_totals) |> Selecto.select(["name"]) |> sql()
      end

      assert_raise Selecto.PolicyViolation, ~r/tenant/, fn ->
        scoped |> Selecto.with_cte(:team_tree) |> Selecto.select(["name"]) |> sql()
      end

      assert_raise Selecto.Advanced.LateralJoin.CorrelationError, ~r/missing_tenant_scope/, fn ->
        Selecto.with_lateral(scoped, :latest_order)
      end
    end

    test "an unscoped root leaves members unscoped" do
      {sql, _params} =
        tenant_domain()
        |> Selecto.configure(:compile_only)
        |> Selecto.with_cte(:order_totals)
        |> Selecto.select(["name", "order_totals.spent"])
        |> sql()

      refute sql =~ "tenant_id ="
    end

    defp split_member(sql) do
      [_with, rest] = String.split(sql, " AS (", parts: 2)
      String.split(rest, ~r/\n\)\n/, parts: 2)
    end
  end
end
