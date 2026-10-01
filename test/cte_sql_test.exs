defmodule Selecto.CteSqlTest do
  use ExUnit.Case, async: true

  alias Selecto.Advanced.CTE
  alias Selecto.Builder.CteSql
  alias Selecto.TestSQLParams, as: Params

  defp domain do
    %{
      name: "Users",
      source: %{
        source_table: "users",
        primary_key: :id,
        fields: [:id, :name, :active],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          active: %{type: :boolean}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  test "build_with_clause/1 supports raw CTE entries" do
    {with_clause, params} =
      CteSql.build_with_clause([
        {:raw_cte, ["active_users AS (SELECT 1 AS id)"], []}
      ])

    with_sql = IO.iodata_to_binary(with_clause)
    assert with_sql =~ ~r/^with\s+/i
    assert with_sql =~ ~r/active_users\s+as\s*\(/i
    assert params == []
  end

  test "build_with_clause/1 uses recursive WITH when recursive entries exist" do
    {with_clause, params} =
      CteSql.build_with_clause([
        {:raw_recursive_cte, ["tree AS (SELECT 1 AS id UNION ALL SELECT 2 AS id)"], []}
      ])

    with_sql = IO.iodata_to_binary(with_clause)
    assert with_sql =~ ~r/^with\s+recursive\s+/i
    assert with_sql =~ ~r/tree\s+as\s*\(/i
    assert params == []
  end

  test "build_with_clause/1 supports validated structured CTE specs" do
    spec =
      CTE.create_cte("active_users", fn ->
        Selecto.configure(domain(), nil, validate: false)
        |> Selecto.select(["id", "name"])
        |> Selecto.filter({"active", true})
      end)

    {with_clause, params} = CteSql.build_with_clause([spec])
    {with_sql, finalized_params} = Params.finalize(with_clause)

    assert with_sql =~ ~r/^with\s+/i
    assert with_sql =~ ~r/active_users\s+as\s*\(/i
    assert with_sql =~ ~r/select/i
    assert with_sql =~ ~r/from users cte_active_users/i
    refute with_sql =~ ~r/selecto_root/i
    assert params == [true]
    assert finalized_params == [true]
  end

  test "dependency validation emits dependencies before dependents" do
    query_builder = fn ->
      Selecto.configure(domain(), nil, validate: false)
      |> Selecto.select(["id"])
    end

    child = CTE.create_cte("child", query_builder, dependencies: ["base"])
    base = CTE.create_cte("base", query_builder)

    assert {:ok, [^base, ^child]} = CTE.validate_dependencies([child, base])

    {with_clause, []} = CteSql.build_with_clause([child, base])
    sql = IO.iodata_to_binary(with_clause)
    assert byte_size(sql) > 0
    assert :binary.match(sql, "base AS") < :binary.match(sql, "child AS")
  end

  test "dependency validation preserves authored order among independent CTEs" do
    query_builder = fn -> Selecto.configure(domain(), nil, validate: false) end
    first = CTE.create_cte("first", query_builder)
    second = CTE.create_cte("second", query_builder)
    third = CTE.create_cte("third", query_builder)

    assert {:ok, [^first, ^second, ^third]} =
             CTE.validate_dependencies([first, second, third])
  end

  test "dependency declarations reject malformed names" do
    assert_raise CTE.ValidationError, ~r/valid CTE name/, fn ->
      CTE.create_cte("child", fn -> :query end, dependencies: [:base])
    end

    assert_raise CTE.ValidationError, ~r/list of valid CTE names/, fn ->
      CTE.create_cte("child", fn -> :query end, dependencies: "base")
    end
  end

  test "dependency validation distinguishes missing, duplicate, and circular graphs" do
    query_builder = fn -> :query end
    missing = CTE.create_cte("missing_child", query_builder, dependencies: ["base"])

    assert {:error, %CTE.ValidationError{type: :missing_dependency, details: missing_details}} =
             CTE.validate_dependencies([missing])

    assert missing_details.missing == [%{cte: "missing_child", dependency: "base"}]

    duplicate_one = CTE.create_cte("duplicate", query_builder)
    duplicate_two = CTE.create_cte("duplicate", query_builder)

    assert {:error,
            %CTE.ValidationError{
              type: :duplicate_cte,
              details: %{duplicates: ["duplicate"]}
            }} = CTE.validate_dependencies([duplicate_one, duplicate_two])

    cycle_a = CTE.create_cte("cycle_a", query_builder, dependencies: ["cycle_b"])
    cycle_b = CTE.create_cte("cycle_b", query_builder, dependencies: ["cycle_a"])

    assert {:error,
            %CTE.ValidationError{
              type: :circular_dependency,
              details: %{cycle: ["cycle_a", "cycle_b", "cycle_a"]}
            }} = CTE.validate_dependencies([cycle_a, cycle_b])

    self_cycle = CTE.create_cte("self_cycle", query_builder, dependencies: ["self_cycle"])

    assert {:error,
            %CTE.ValidationError{
              type: :circular_dependency,
              details: %{cycle: ["self_cycle", "self_cycle"]}
            }} = CTE.validate_dependencies([self_cycle])
  end

  test "with_ctes/3 rejects an invalid dependency graph before query mutation" do
    selecto = Selecto.configure(domain(), nil, validate: false)
    child = CTE.create_cte("child", fn -> selecto end, dependencies: ["missing"])

    assert_raise CTE.ValidationError, ~r/same query/, fn ->
      Selecto.with_ctes(selecto, [child])
    end

    assert Map.get(selecto.set, :ctes, []) == []
  end

  test "integrate_ctes_with_query/3 keeps CTE params before query params" do
    ctes = [
      {:raw_cte, ["active_users AS (SELECT id FROM users WHERE active = ", {:param, true}, ")"],
       [true]}
    ]

    query_iodata = ["SELECT * FROM active_users WHERE id > ", {:param, 10}]
    query_params = [10]

    {iodata, params} = CteSql.integrate_ctes_with_query(ctes, query_iodata, query_params)
    {sql, finalized_params} = Params.finalize(iodata)

    assert sql =~ ~r/^with\s+/i
    assert sql =~ ~r/select\s+\*/i
    assert params == [true, 10]
    assert finalized_params == [true, 10]
  end

  test "build_with_clause/1 rejects legacy untagged tuple entries" do
    assert_raise ArgumentError, ~r/Unsupported CTE entries/, fn ->
      CteSql.build_with_clause([{["WITH x AS (SELECT 1)"], []}])
    end
  end

  test "create_cte_reference/1 returns queryable reference map" do
    ref = CteSql.create_cte_reference("hierarchy")

    assert ref.__cte_reference__ == true
    assert ref.name == "hierarchy"
    assert ref.source == "hierarchy"
    assert ref.type == :cte
  end

  describe "recursion depth" do
    defp employees do
      %{
        name: "Employees",
        source: %{
          source_table: "employees",
          primary_key: :id,
          fields: [:id, :manager_id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, manager_id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        },
        schemas: %{},
        joins: %{}
      }
    end

    defp base_query do
      fn ->
        Selecto.configure(employees(), nil, validate: false)
        |> Selecto.select(["id", "manager_id"])
        |> Selecto.filter({"manager_id", nil})
      end
    end

    defp step_query do
      fn _cte_ref ->
        Selecto.configure(employees(), nil, validate: false)
        |> Selecto.join(:reports,
          source: "reports",
          type: :inner,
          owner_key: :manager_id,
          related_key: :id,
          fields: %{"id" => %{type: :integer}}
        )
        |> Selecto.select(["id", "manager_id"])
      end
    end

    defp recursive_sql(opts) do
      employees()
      |> Selecto.configure(nil, validate: false)
      |> Selecto.with_recursive_cte(
        "reports",
        [base_query: base_query(), recursive_query: step_query(), columns: ["id", "manager_id"]] ++
          opts
      )
      |> Selecto.select(["name"])
      |> Selecto.to_sql()
      |> elem(0)
      |> String.replace(~r/\s+/, " ")
    end

    test "a recursive CTE is bounded at 100 levels by default" do
      sql = recursive_sql([])

      assert sql =~ "reports (id, manager_id, selecto_depth) AS ("
      assert sql =~ ~r/select cte_reports\.id, cte_reports\.manager_id, 1 AS selecto_depth from/
      assert sql =~ "reports.selecto_depth + 1"
      assert sql =~ "reports.selecto_depth < 100"
    end

    test "max_depth and cycle_detection are honored" do
      assert recursive_sql(max_depth: 3) =~ "reports.selecto_depth < 3"
      assert recursive_sql(max_depth: 3, cycle_detection: true) =~ "reports.selecto_depth < 3"

      inline =
        employees()
        |> Selecto.configure(nil, validate: false)
        |> Selecto.with_recursive_cte("reports", base_query(), step_query(),
          columns: ["id", "manager_id"],
          max_depth: 4
        )
        |> Selecto.select(["name"])
        |> Selecto.to_sql()
        |> elem(0)

      assert inline =~ "reports.selecto_depth < 4"
    end

    test "invalid bounds are rejected" do
      for bad <- [0, -1, 10_001, "5", 1.5] do
        assert_raise CTE.ValidationError, ~r/max_depth/, fn -> recursive_sql(max_depth: bad) end
      end

      assert_raise CTE.ValidationError, ~r/cycle_detection/, fn ->
        recursive_sql(cycle_detection: :yes)
      end
    end

    test "an explicit bound the recursive query cannot carry fails closed" do
      unjoined = fn _cte_ref ->
        Selecto.configure(employees(), nil, validate: false)
        |> Selecto.select(["id", "manager_id"])
      end

      build = fn opts ->
        employees()
        |> Selecto.configure(nil, validate: false)
        |> Selecto.with_recursive_cte(
          "reports",
          [base_query: base_query(), recursive_query: unjoined, columns: ["id", "manager_id"]] ++
            opts
        )
        |> Selecto.to_sql()
      end

      assert {sql, _params} = build.([])
      refute sql =~ "selecto_depth"

      assert_raise ArgumentError, ~r/max_depth/, fn -> build.(max_depth: 5) end
      assert_raise ArgumentError, ~r/max_depth/, fn -> build.(cycle_detection: true) end
    end
  end
end
