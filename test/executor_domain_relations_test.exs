defmodule Selecto.ExecutorDomainRelationsTest do
  # The relations an adapter resolves before a read: an ad-hoc join's table and a
  # subquery join's tables count; a CTE an ad-hoc join reads does not.
  use ExUnit.Case, async: true

  defp domain(table, fields) do
    %{
      name: table,
      source: %{
        source_table: table,
        primary_key: :id,
        fields: fields,
        redact_fields: [],
        columns: Map.new(fields, &{&1, %{type: :integer}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp configure(table, fields),
    do: Selecto.configure(domain(table, fields), nil, validate: false)

  test "an ad-hoc join's source is a relation of the read" do
    query =
      configure("products", [:id])
      |> Selecto.join(:reviews, source: "reviews", owner_key: :id, related_key: :product_id)

    assert Enum.sort(Selecto.Executor.domain_relations(query)) == ["products", "reviews"]
    assert Selecto.Executor.dynamic_sources(query) == ["reviews"]
  end

  test "a subquery join's relations are relations of the read, with its query" do
    inner =
      configure("reviews", [:id, :product_id])
      |> Selecto.join(:authors, source: "authors", owner_key: :id, related_key: :review_id)
      |> Selecto.select(["product_id"])

    query =
      configure("products", [:id])
      |> Selecto.DynamicJoin.join_subquery(:best, inner, on: [%{left: "id", right: "product_id"}])

    assert Enum.sort(Selecto.Executor.domain_relations(query)) == [
             "authors",
             "products",
             "reviews"
           ]

    assert length(Selecto.Executor.read_queries(query)) == 2
    assert Selecto.Executor.dynamic_sources(query) == []
  end

  test "a VALUES list an ad-hoc join reads is no relation" do
    query =
      configure("orders", [:id])
      |> Selecto.with_values([["open", "Open"]], columns: ["status", "label"], as: "labels")
      |> Selecto.join(:labels, source: "labels", owner_key: :id, related_key: :status)

    assert Selecto.Executor.dynamic_sources(query) == []
    assert Selecto.Executor.domain_relations(query) == ["orders"]
  end

  test "raw SQL in a nested query keeps its own alias" do
    raw = {:field, {:raw_sql, "COUNT(*) AS n"}, "n"}
    inner = configure("reviews", [:id, :product_id]) |> Selecto.select(["product_id", raw])

    assert %Selecto{} =
             configure("products", [:id])
             |> Selecto.DynamicJoin.join_subquery(:best, inner,
               on: [%{left: "id", right: "product_id"}]
             )
  end

  test "a nested query's renamed plain field keeps its own name" do
    # The nested SQL carries no select alias: the column is the field's own name.
    for selector <- [{:field, "id", "x"}, {:field, "id", as: "x"}, {:field, "id", as: "id"}] do
      inner = configure("reviews", [:id, :product_id]) |> Selecto.select([selector, "product_id"])

      joined =
        configure("products", [:id])
        |> Selecto.DynamicJoin.join_subquery(:best, inner,
          on: [%{left: "id", right: "product_id"}]
        )

      fields = joined.set.dynamic_joins.best.fields |> Map.keys()
      assert "best.id" in fields, inspect(selector)
      refute "best.x" in fields, inspect(selector)
    end
  end

  test "a CTE body without a column list may rename a field, as before" do
    body = fn ->
      configure("products", [:id]) |> Selecto.select([{:field, "id", "product_id"}])
    end

    query = configure("products", [:id]) |> Selecto.with_cte("cb", body) |> Selecto.select(["id"])
    assert {sql, _params} = Selecto.to_sql(query)
    assert sql =~ "cb"
  end

  test "a retarget target's VALUES named like its origin's table is a collision" do
    domain =
      domain("reviews", [:id, :product_id])
      |> put_in([:source, :associations], %{
        prod: %{queryable: :prod, field: :prod, owner_key: :product_id, related_key: :id}
      })
      |> Map.put(:schemas, %{prod: domain("products", [:id]).source})
      |> Map.put(:joins, %{prod: %{type: :left, name: "prod"}})

    query =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.retarget(:prod)
      |> Selecto.with_values([[1, 2]], columns: ["id", "product_id"], as: "reviews")

    assert {:error,
            %Selecto.Error{details: %{reason: :cte_name_collision, relations: ["reviews"]}}} =
             Selecto.Executor.prepare_read(query)
  end

  test "a body sees the statement CTEs emitted before it, in dependency order" do
    cte = fn name, deps ->
      Selecto.Advanced.CTE.create_cte(
        name,
        fn -> configure("x", [:id]) |> Selecto.select(["id"]) end,
        dependencies: deps
      )
    end

    {a, b, c} = {cte.("a", ["c"]), cte.("b", []), cte.("c", [])}
    root = configure("products", [:id]) |> Selecto.with_ctes([a, b, c])
    names = &Enum.map(&1, fn spec -> spec.name end)

    assert names.(Selecto.Builder.Sql.emitted_order(root.set.ctes)) == ["b", "c", "a"]
    assert names.(Selecto.Builder.Sql.visible_ctes(root, a)) == ["b", "c"]
    assert names.(Selecto.Builder.Sql.visible_ctes(root, b)) == []
  end

  test "a body's copy of a statement CTE emitted after it is emitted in the body" do
    spec =
      Selecto.Advanced.CTE.create_cte("c2", fn ->
        configure("products", [:id]) |> Selecto.select(["id"])
      end)

    body = fn ->
      configure("reviews", [:id]) |> Selecto.with_ctes([spec]) |> Selecto.select(["id"])
    end

    after_body =
      configure("reviews", [:id])
      |> Selecto.with_cte("cb", body)
      |> Selecto.with_ctes([spec])
      |> Selecto.select(["id"])

    before_body =
      configure("reviews", [:id])
      |> Selecto.with_ctes([spec])
      |> Selecto.with_cte("cb", body)
      |> Selecto.select(["id"])

    {sql_after, _} = Selecto.to_sql(after_body)
    {sql_before, _} = Selecto.to_sql(before_body)
    assert sql_after =~ ~r/cb AS \(\s*WITH c2 AS/
    refute sql_before =~ ~r/cb AS \(\s*WITH/
  end

  test "under WITH RECURSIVE a body still sees only the CTEs emitted before it" do
    plain = fn name ->
      Selecto.Advanced.CTE.create_cte(name, fn ->
        configure("x", [:id]) |> Selecto.select(["id"])
      end)
    end

    walk =
      Selecto.Advanced.CTE.create_recursive_cte("walk",
        base_query: fn -> configure("x", [:id]) |> Selecto.select(["id"]) end,
        recursive_query: fn _ref -> configure("x", [:id]) |> Selecto.select(["id"]) end
      )

    {cb, c2} = {plain.("cb"), plain.("c2")}
    root = configure("products", [:id]) |> Selecto.with_ctes([cb, c2, walk])

    # MySQL shows no body a later CTE, even under WITH RECURSIVE.
    assert Selecto.Builder.Sql.visible_ctes(root, cb) == []
  end

  test "a values-backed schema's CTE is named by its rows" do
    values_domain = fn rows ->
      %{
        name: :items,
        source: %{
          source_table: "items",
          primary_key: :id,
          fields: [:id, :status_id],
          columns: %{id: %{type: :integer}, status_id: %{type: :string}},
          associations: %{
            status: %{
              queryable: :status,
              field: :status,
              owner_key: :status_id,
              related_key: :id,
              cardinality: :one
            }
          }
        },
        schemas: %{
          status: %{
            primary_key: :id,
            fields: [:id, :name],
            columns: %{id: %{type: :string}, name: %{type: :string}},
            values: rows,
            associations: %{}
          }
        },
        joins: %{status: %{type: :left}}
      }
    end

    table = fn rows ->
      {sql, _aliases, _params} =
        values_domain.(rows)
        |> Selecto.configure(:mock_connection)
        |> Selecto.select(["id", "status.name"])
        |> Selecto.gen_sql([])

      [name] = Regex.run(~r/__selecto_values_status_[0-9a-f]{10}/, sql)
      name
    end

    a = table.([%{id: "A", name: "Item-A"}])
    refute a == table.([%{id: "A", name: "Ship-A"}])
    assert a == table.([%{id: "A", name: "Item-A"}])
  end

  test "names a query defines hide tables only where they are visible" do
    member =
      configure("orders", [:id]) |> Selecto.with_values([["a"]], columns: ["c"], as: "products")

    union =
      Selecto.union(
        configure("products", [:id]) |> Selecto.select(["id"]),
        member |> Selecto.select(["id"])
      )

    assert "products" in Selecto.Executor.domain_relations(union)
  end

  test "generated CTE names are reserved and fit 63 characters" do
    alias Selecto.Builder.GeneratedName

    long = "status_" <> String.duplicate("y", 39)
    other = "status_" <> String.duplicate("y", 38) <> "z"
    rows = [%{id: "A", name: "Item-A"}]

    for name <- [
          GeneratedName.values(long, [:id, :name], rows),
          GeneratedName.hierarchy(long, %{source: "t"}),
          GeneratedName.materialized_path(long, %{source: "t"}),
          GeneratedName.closure(long <> long, %{source: "t"})
        ] do
      assert byte_size(name) <= 63
      assert String.starts_with?(name, "__selecto_")
    end

    refute GeneratedName.values(long, [:id, :name], rows) ==
             GeneratedName.values(other, [:id, :name], rows)

    refute GeneratedName.values(long, [:id, :name], rows) ==
             GeneratedName.values(long, [:id, :name], [%{id: "A", name: "Ship-A"}])

    refute GeneratedName.closure(long <> long, %{}) == GeneratedName.closure(long <> other, %{})

    # A join's name follows its definition: one id over two closure tables, two names.
    root = %{source: "cats", closure_table: "cats_closure"}
    body = %{source: "cats", closure_table: "cc2"}
    assert GeneratedName.closure(:catj, root) =~ ~r/^__selecto_closure_catj_[0-9a-f]{10}$/
    refute GeneratedName.closure(:catj, root) == GeneratedName.closure(:catj, body)

    assert GeneratedName.closure(:catj, root) ==
             GeneratedName.closure(:catj, Map.put(root, :x, 1))
  end

  test "a closure join's own CTE never hides its closure table" do
    cat = :cats
    cols = %{id: %{type: :integer}, name: %{type: :string}}

    domain = %{
      name: "items",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :cat_id],
        redact_fields: [],
        columns: %{id: %{type: :integer}, cat_id: %{type: :integer}},
        associations: %{
          cat => %{queryable: :catq, field: cat, owner_key: :cat_id, related_key: :id}
        }
      },
      schemas: %{
        catq: %{
          source_table: "cats",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: cols,
          associations: %{}
        }
      },
      joins: %{cat => %{type: :hierarchical, name: "cat", hierarchy_type: :closure_table}}
    }

    query =
      Selecto.configure(domain, nil, validate: false) |> Selecto.select(["id", "cats_depth"])

    {sql, _params} = Selecto.to_sql(query)

    assert sql =~ ~r/__selecto_closure_cats_[0-9a-f]{10} AS/
    assert sql =~ "JOIN cats_closure cl"
    assert "cats_closure" in Selecto.Executor.domain_relations(query)
    assert {:ok, _} = Selecto.Executor.prepare_read(query)

    # A user list named like the closure table the generated CTE reads refuses.
    named = Selecto.with_values(query, [[1]], columns: ["ancestor_id"], as: "cats_closure")

    assert {:error,
            %Selecto.Error{details: %{reason: :cte_name_collision, relations: ["cats_closure"]}}} =
             Selecto.Executor.prepare_read(named)
  end

  defp refusal(query) do
    case Selecto.Executor.prepare_read(query) do
      {:ok, _} -> :ok
      {:error, %Selecto.Error{details: %{reason: reason, relations: names}}} -> {reason, names}
    end
  end

  test "a list named like a relation read anywhere in the statement refuses" do
    lk =
      Selecto.Advanced.CTE.create_cte("lk", fn ->
        configure("products", [:id]) |> Selecto.select(["id"])
      end)

    ad_hoc = fn ->
      configure("products", [:id])
      |> Selecto.join(:lkj, source: "lk", owner_key: :id, related_key: :product_id)
      |> Selecto.select(["id"])
    end

    subquery = fn ->
      inner = configure("lk", [:id, :product_id]) |> Selecto.select(["product_id"])

      configure("products", [:id])
      |> Selecto.DynamicJoin.join_subquery(:sq, inner, on: [%{left: "id", right: "product_id"}])
      |> Selecto.select(["id"])
    end

    cb = &Selecto.Advanced.CTE.create_cte("cb", &1)
    root = configure("products", [:id])

    # A body reading the table lk, the statement's CTE lk defined after it.
    assert refusal(Selecto.with_ctes(root, [cb.(ad_hoc), lk])) == {:cte_name_collision, ["lk"]}
    # Deeper: the body's subquery join reads the table.
    assert refusal(Selecto.with_ctes(root, [cb.(subquery), lk])) == {:cte_name_collision, ["lk"]}
    # Before the body the ad-hoc join names the CTE: no table is read.
    assert refusal(Selecto.with_ctes(root, [lk, cb.(ad_hoc)])) == :ok

    # A recursive base reading the table lk.
    walk =
      Selecto.Advanced.CTE.create_recursive_cte("walk",
        base_query: subquery,
        recursive_query: fn _ref -> configure("x", [:id]) |> Selecto.select(["id"]) end
      )

    assert refusal(Selecto.with_ctes(root, [walk, lk])) == {:cte_name_collision, ["lk"]}

    # A union member reading the table a VALUES list of the other member names.
    member = configure("orders", [:id]) |> Selecto.with_values([["a"]], columns: ["c"], as: "lk")

    union =
      Selecto.union(
        configure("lk", [:id]) |> Selecto.select(["id"]),
        member |> Selecto.select(["id"])
      )

    assert refusal(union) == {:cte_name_collision, ["lk"]}
  end

  test "one name defined twice with different lists refuses; identical copies do not" do
    c2 = fn filter ->
      Selecto.Advanced.CTE.create_cte("c2", fn ->
        configure("products", [:id]) |> Selecto.filter({"id", filter}) |> Selecto.select(["id"])
      end)
    end

    {own, all} = {c2.(1), c2.(2)}

    body = fn spec ->
      fn ->
        configure("reviews", [:id])
        |> Selecto.with_ctes([spec])
        |> Selecto.join(:c2j, source: "c2", source_kind: :cte, owner_key: :id, related_key: :id)
        |> Selecto.select(["id"])
      end
    end

    root = configure("reviews", [:id])

    assert refusal(Selecto.with_cte(root, "cb", body.(own)) |> Selecto.with_ctes([all])) ==
             {:cte_name_redefined, ["c2"]}

    assert refusal(Selecto.with_cte(root, "cb", body.(own)) |> Selecto.with_ctes([own])) == :ok

    # Two with_cte calls with one builder define one list, whatever their ids.
    builder = fn -> configure("products", [:id]) |> Selecto.select(["id"]) end

    copy = fn ->
      configure("reviews", [:id])
      |> Selecto.with_cte("pc", builder)
      |> Selecto.join(:pcj, source: "pc", source_kind: :cte, owner_key: :id, related_key: :id)
      |> Selecto.select(["id"])
    end

    assert refusal(root |> Selecto.with_cte("cb", copy) |> Selecto.with_cte("pc", builder)) == :ok

    # Two closures that build one body define one list (the TPC-DS demo builds
    # each copy with its own `fn -> cte end`).
    built = builder.()

    twice = fn ->
      configure("reviews", [:id])
      |> Selecto.with_cte("pc", fn -> built end)
      |> Selecto.join(:pcj, source: "pc", source_kind: :cte, owner_key: :id, related_key: :id)
      |> Selecto.select(["id"])
    end

    assert refusal(
             root
             |> Selecto.with_cte("cb", twice)
             |> Selecto.with_cte("pc", fn -> built end)
           ) ==
             :ok
  end

  test "a filter subquery is a query of the statement" do
    inner = configure("r", [:id, :product_id]) |> Selecto.select(["product_id"])
    root = configure("p", [:id])

    for filter <- [
          {"id", {:subquery, :in, inner}},
          {"id", "=", {:subquery, :any, inner}},
          {:exists, inner}
        ] do
      query = root |> Selecto.filter(filter) |> Selecto.select(["id"])
      assert "r" in Selecto.Executor.domain_relations(query)
      assert inner in Selecto.Executor.read_queries(query)

      named = Selecto.with_values(query, [[1, 2]], columns: ["id", "product_id"], as: "r")
      assert refusal(named) == {:cte_name_collision, ["r"]}
    end
  end

  test "a declared non-association join's table is a relation of the read it joins" do
    domain =
      configure("p", [:id]).domain
      |> Map.put(:joins, %{
        lkd: %{
          non_assoc: true,
          source: "lk",
          type: :left,
          owner_key: :id,
          related_key: :pid,
          fields: %{
            "lkd.pid" => %{colid: "lkd.pid", field: "pid", requires_join: :lkd, type: :integer}
          }
        }
      })

    query = Selecto.configure(domain, nil, validate: false)
    assert "lk" in Selecto.Executor.domain_relations(query)

    # Unused, the join's table is not read: a list named like it reads.
    unused = Selecto.with_values(query, [[1]], columns: ["pid"], as: "lk")
    assert refusal(Selecto.select(unused, ["id"])) == :ok

    assert refusal(Selecto.select(unused, ["id", "lkd.pid"])) ==
             {:cte_name_collision, ["lk"]}
  end

  test "only relations the compiled read names are resolved and checked" do
    # An unused declared join (association, non-association, through table)
    # names no relation of the read; a used one, a subselect or a filter on it
    # does.
    domain =
      configure("p", [:id, :lid]).domain
      |> put_in([:source, :associations], %{
        al: %{queryable: :alq, field: :al, owner_key: :id, related_key: :pid}
      })
      |> Map.put(:schemas, %{
        alq: configure("alloc", [:id, :pid]).domain.source
      })
      |> Map.put(:joins, %{al: %{type: :left, name: "al"}})

    query = Selecto.configure(domain, nil, validate: false)
    named = Selecto.with_values(query, [[1, 1]], columns: ["id", "pid"], as: "alloc")

    assert refusal(Selecto.select(named, ["id"])) == :ok

    for used <- [
          Selecto.select(named, ["id", "al.pid"]),
          named |> Selecto.select(["id"]) |> Selecto.filter({"al.pid", 1}),
          named |> Selecto.select(["id"]) |> Selecto.order_by(["al.pid"]),
          named
          |> Selecto.select(["id"])
          |> Selecto.subselect([%{target_schema: :alq, fields: [:pid], alias: "s"}])
        ] do
      assert refusal(used) == {:cte_name_collision, ["alloc"]}
    end
  end

  test "a domain rooted on a CTE reads the CTE; read as a table elsewhere it refuses" do
    one = fn -> configure("p", [:id]) |> Selecto.select(["id"]) end
    rooted = configure("cte_one", [:id]) |> Selecto.with_cte("cte_one", one, columns: ["id"])
    assert refusal(Selecto.select(rooted, ["id"])) == :ok
    refute "cte_one" in Selecto.Executor.domain_relations(rooted)

    chained =
      configure("cte_two", [:id])
      |> Selecto.with_cte("cte_one", one, columns: ["id"])
      |> Selecto.with_cte(
        "cte_two",
        fn -> configure("cte_one", [:id]) |> Selecto.select(["id"]) end,
        columns: ["id"],
        dependencies: ["cte_one"]
      )

    assert refusal(Selecto.select(chained, ["id"])) == :ok

    # A body before the CTE reads the table of that name.
    mixed =
      configure("cte_one", [:id])
      |> Selecto.with_cte("cb", fn -> configure("cte_one", [:id]) |> Selecto.select(["id"]) end)
      |> Selecto.with_cte("cte_one", one, columns: ["id"])
      |> Selecto.select(["id"])

    assert refusal(mixed) == {:cte_name_collision, ["cte_one"]}

    # A filter subquery over an enclosing list's name reads the table.
    sub = configure("cte_one", [:id]) |> Selecto.select(["id"])
    captured = rooted |> Selecto.filter({"id", {:subquery, :in, sub}}) |> Selecto.select(["id"])
    assert refusal(captured) == {:cte_name_collision, ["cte_one"]}
  end

  test "lists of one name in two set members are private to each" do
    member = fn label ->
      configure("p", [:id])
      |> Selecto.with_values([[1, label]], columns: ["id", "label"], as: "vv")
      |> Selecto.join(:vj, source: "vv", owner_key: :id, related_key: :id)
      |> Selecto.select(["id"])
    end

    union = Selecto.union(member.("L"), member.("R"), all: true)
    assert refusal(union) == :ok

    chained = Selecto.union(union, member.("S"), all: true)
    assert refusal(chained) == :ok

    # A member's list and a different statement list of that name refuse.
    statement =
      configure("p", [:id])
      |> Selecto.with_values([[2, "MAIN"]], columns: ["id", "label"], as: "vv")
      |> Selecto.with_cte("cb", fn -> union end)
      |> Selecto.select(["id"])

    assert refusal(statement) == {:cte_name_redefined, ["vv"]}
  end

  test "only an undeclared root reads a list of its name" do
    fake = fn query ->
      Selecto.with_cte(query, "p", fn -> configure("r", [:id]) |> Selecto.select(["id"]) end,
        columns: ["id"]
      )
    end

    undeclared = configure("p", [:id]) |> fake.() |> Selecto.select(["id"])
    assert refusal(undeclared) == :ok
    assert Selecto.Executor.list_roots(undeclared) == ["p"]

    declared =
      configure("p", [:id]).domain
      |> put_in([:source, :source_schema], "public")
      |> Selecto.configure(nil, validate: false)
      |> fake.()
      |> Selecto.select(["id"])

    assert refusal(declared) == {:cte_name_collision, ["p"]}
    assert Selecto.Executor.list_roots(declared) == []

    # A joined schema over table p is a table, whatever the root.
    joined =
      configure("r", [:id, :product_id]).domain
      |> put_in([:source, :associations], %{
        prod: %{queryable: :prod, field: :prod, owner_key: :product_id, related_key: :id}
      })
      |> Map.put(:schemas, %{prod: configure("p", [:id]).domain.source})
      |> Map.put(:joins, %{prod: %{type: :left, name: "prod"}})
      |> Selecto.configure(nil, validate: false)
      |> fake.()

    assert refusal(Selecto.select(joined, ["id", "prod.id"])) == {:cte_name_collision, ["p"]}
    # Unused, the join reads nothing.
    assert refusal(Selecto.select(joined, ["id"])) == :ok
  end

  test "a CASE subquery is a query of the statement" do
    inner = configure("r", [:id, :product_id]) |> Selecto.select(["product_id"])

    query =
      configure("p", [:id])
      |> Selecto.select(["id"])
      |> Selecto.case_when_select([{[{"id", {:subquery, :in, inner}}], "HIGH"}],
        else: "LOW",
        as: "tier"
      )

    assert inner in Selecto.Executor.read_queries(query)
    assert "r" in Selecto.Executor.domain_relations(query)

    named = Selecto.with_values(query, [[1, 2]], columns: ["id", "product_id"], as: "r")
    assert refusal(named) == {:cte_name_collision, ["r"]}
  end

  test "a raw CTE's name counts; its text is the host's" do
    root = configure("p", [:id])
    plain = root |> Selecto.with_ctes([{:raw_cte, "raw_one AS (SELECT 1 AS v)", []}])
    assert refusal(Selecto.select(plain, ["id"])) == :ok

    assert {"raw_one", {:raw, "raw_one AS (SELECT 1 AS v)", []}} in Selecto.Executor.definitions(
             plain
           )

    inner = configure("r", [:id]) |> Selecto.select(["id"])

    named =
      root
      |> Selecto.with_ctes([{:raw_cte, ~S["r" (id) AS (SELECT 1)], []}])
      |> Selecto.filter({"id", {:subquery, :in, inner}})
      |> Selecto.select(["id"])

    assert refusal(named) == {:cte_name_collision, ["r"]}
  end

  test "an embedded query missing its required tenant refuses typed" do
    inner =
      configure("r", [:id, :tenant_id]).domain
      |> put_in([:source, :tenant_field], :tenant_id)
      |> Map.put(:tenant_required, true)
      |> Selecto.configure(nil, validate: false)
      |> Selecto.select(["id"])

    query = configure("p", [:id]) |> Selecto.filter({"id", {:subquery, :in, inner}})

    assert {:error, %Selecto.Error{details: %{code: :tenant_scope_missing}}} =
             Selecto.Executor.prepare_read(query)
  end

  test "every name a raw CTE's text defines counts; unreadable text refuses" do
    inner = configure("r", [:id]) |> Selecto.select(["id"])
    root = configure("p", [:id]) |> Selecto.filter({"id", {:subquery, :in, inner}})

    for text <- [
          "x13 AS (SELECT 1 AS v), r AS (SELECT 2 AS id)",
          "/* c */ r AS (SELECT 2 AS id)",
          "-- c\n r AS (SELECT 2 AS id)",
          "`r` AS (SELECT 2 AS id)",
          ~S["R" AS (SELECT 2 AS id)]
        ] do
      query = root |> Selecto.with_ctes([{:raw_cte, text, []}]) |> Selecto.select(["id"])
      assert {:cte_name_collision, [_r]} = refusal(query), text
    end

    unreadable = root |> Selecto.with_ctes([{:raw_cte, "SELECT 1", []}]) |> Selecto.select(["id"])

    assert {:error, %Selecto.Error{details: %{reason: :raw_cte_unparsed}}} =
             Selecto.Executor.prepare_read(unreadable)
  end

  test "a raw CTE whose params do not match its placeholders refuses typed" do
    root = configure("p", [:id])

    for {text, params} <- [{"x AS (SELECT 1 AS v)", [5]}, {"x AS (SELECT 1 AS v)", [5, 6]}] do
      query = root |> Selecto.with_ctes([{:raw_cte, text, params}]) |> Selecto.select(["id"])

      assert {:error, %Selecto.Error{details: %{reason: :raw_cte_params_mismatch}}} =
               Selecto.Executor.prepare_read(query),
             inspect(params)
    end

    bound = root |> Selecto.with_ctes([{:raw_cte, "x AS (SELECT 1 AS v)", []}])
    assert {:ok, _} = Selecto.Executor.prepare_read(Selecto.select(bound, ["id"]))
  end

  test "a raw CTE with params inside a nested query binds in the statement's dialect" do
    inner =
      configure("pa", [:pid])
      |> Selecto.with_ctes([{:raw_cte, "pa AS (SELECT $1::int AS pid)", [1]}])
      |> Selecto.select(["pid"])

    query =
      configure("p", [:id])
      |> Selecto.DynamicJoin.join_subquery(:sq, inner, on: [%{left: "id", right: "pid"}])
      |> Selecto.select(["id", "sq.pid"])

    assert {:ok, _} = Selecto.Executor.prepare_read(query)
    {sql, params} = Selecto.to_sql(query)
    assert sql =~ "pa AS (SELECT $1::int AS pid)"
    assert params == [1]
  end

  test "a raw CTE placeholder that would bind the statement's own values refuses" do
    root = configure("pa", [:pid])

    for {text, params} <- [
          {"pa AS (SELECT $1::int AS pid, $2::text AS label)", [5]},
          {"pa AS (SELECT 7 AS pid, $1::text AS label)", []},
          {["pa AS (SELECT ", {:param, 5}, "::int AS pid)"], [6]}
        ] do
      query =
        root
        |> Selecto.with_ctes([{:raw_cte, text, params}])
        |> Selecto.select(["pid"])
        |> Selecto.filter({"pid", 9})

      assert {:error, %Selecto.Error{details: %{reason: :raw_cte_params_mismatch}}} =
               Selecto.Executor.prepare_read(query),
             inspect(text)
    end

    twice =
      root
      |> Selecto.with_ctes([{:raw_cte, "pa AS (SELECT $1::int AS pid, $1::int AS q)", [5]}])
      |> Selecto.select(["pid"])

    assert {:ok, _} = Selecto.Executor.prepare_read(twice)
    assert {_sql, [5, 5]} = Selecto.to_sql(twice)
  end

  test "a query member the query does not use is no query of the statement" do
    member =
      configure("r", [:id, :tenant_id]).domain
      |> put_in([:source, :tenant_field], :tenant_id)
      |> Map.put(:tenant_required, true)
      |> Selecto.configure(nil, validate: false)
      |> Selecto.select(["id"])

    domain = Map.put(configure("p", [:id]).domain, :query_members, %{unused: %{query: member}})
    query = Selecto.configure(domain, nil, validate: false) |> Selecto.select(["id"])

    assert refusal(query) == :ok
    refute member in Selecto.Executor.read_queries(query)
    assert refusal(Selecto.with_values(query, [[1]], columns: ["id"], as: "r")) == :ok
  end

  test "on PostgreSQL a reserved-only name is written folded in its definition and every reference" do
    domain = configure("Rank", [:id]).domain

    rooted =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.with_values([[1]], columns: ["id"], as: "Rank")
      |> Selecto.select(["id"])

    {sql, _params} = Selecto.to_sql(rooted)
    assert sql =~ ~S[WITH "rank" (]
    assert sql =~ ~S[from "rank" selecto_root]
    refute sql =~ ~S["Rank"]
    assert Selecto.Executor.list_root_identifiers(rooted) == [{"Rank", ~S["rank"]}]

    # A raw CTE's unquoted name is referenced as PostgreSQL folds it.
    raw =
      configure("p", [:id])
      |> Selecto.with_ctes([{:raw_cte, "First AS (SELECT 1 AS id, 2 AS v)", []}])
      |> Selecto.join(:mj,
        source: "First",
        owner_key: :id,
        related_key: :id,
        fields: %{"v" => %{type: :integer}}
      )
      |> Selecto.select(["id", "mj.v"])

    {sql, _params} = Selecto.to_sql(raw)
    assert sql =~ ~S[join "first" mj]
  end

  test "a plain list name is written unquoted in its definition and every reference" do
    domain = configure("MixedList", [:id]).domain

    query =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.with_values([[1]], columns: ["id"], as: "MixedList")
      |> Selecto.select(["id"])

    {sql, _params} = Selecto.to_sql(query)
    assert sql =~ ~r/WITH MixedList\b/
    assert sql =~ ~r/from MixedList selecto_root/i
    refute sql =~ ~S["MixedList"]

    # An ad-hoc join and a CTE body naming the list write it the same way.
    joined =
      configure("p", [:id])
      |> Selecto.with_values([[1]], columns: ["id"], as: "MixedList")
      |> Selecto.join(:mj, source: "MixedList", owner_key: :id, related_key: :id)
      |> Selecto.with_cte("cb", fn ->
        Selecto.configure(domain, nil, validate: false) |> Selecto.select(["id"])
      end)
      |> Selecto.select(["id"])

    {sql, _params} = Selecto.to_sql(joined)
    refute sql =~ ~S["MixedList"]

    # Two lists whose names fold together are one name.
    folded =
      configure("p", [:id])
      |> Selecto.with_values([[1]], columns: ["id"], as: "MixF")
      |> Selecto.with_values([[2]], columns: ["id"], as: "mixf")
      |> Selecto.select(["id"])

    assert refusal(folded) == {:cte_name_redefined, ["mixf"]}

    # A raw CTE's unquoted name reads like a Selecto list's; a quoted one keeps
    # its quotes in every reference.
    unquoted =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.with_ctes([{:raw_cte, "MixedList AS (SELECT 1 AS id)", []}])
      |> Selecto.select(["id"])

    assert {:ok, _} = Selecto.Executor.prepare_read(unquoted)
    assert Selecto.to_sql(unquoted) |> elem(0) =~ ~r/from MixedList selecto_root/i

    quoted_raw =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.with_ctes([{:raw_cte, "`MixedList` AS (SELECT 1 AS id)", []}])
      |> Selecto.select(["id"])

    assert {:ok, _} = Selecto.Executor.prepare_read(quoted_raw)
    refute Selecto.to_sql(quoted_raw) |> elem(0) =~ ~r/from MixedList selecto_root/i

    bad = put_in(domain, [:source, :source_table], ~S[bad"name])

    quoted =
      Selecto.configure(bad, nil, validate: false)
      |> Selecto.with_values([[1]], columns: ["id"], as: ~S[bad"name])
      |> Selecto.select(["id"])

    assert {:error, %Selecto.Error{details: %{reason: :invalid_identifier}}} =
             Selecto.Executor.prepare_read(quoted)

    # An ad-hoc join on a list whose name an identifier cannot hold.
    dollar =
      configure("p", [:id])
      |> Selecto.with_values([[1]], columns: ["id"], as: "v$x")
      |> Selecto.join(:vj, source: "v$x", owner_key: :id, related_key: :id)
      |> Selecto.select(["id"])

    assert {:error, %Selecto.Error{details: %{reason: :invalid_identifier, relations: ["v$x"]}}} =
             Selecto.Executor.prepare_read(dollar)
  end

  test "a raw CTE's iodata text with parameters is read, not raised on" do
    query =
      configure("p", [:id])
      |> Selecto.with_ctes([{:raw_cte, ["x14 AS (SELECT ", {:param, 1}, " AS pid)"], []}])
      |> Selecto.select(["id"])

    assert {:ok, _} = Selecto.Executor.prepare_read(query)

    assert {"x14", {:raw, ["x14 AS (SELECT ", {:param, 1}, " AS pid)"], []}} in Selecto.Executor.definitions(
             query
           )
  end

  test "a CTE whose body is a set operation compiles" do
    body = fn ->
      Selecto.union(
        configure("products", [:id]) |> Selecto.select(["id"]),
        configure("products", [:id]) |> Selecto.select(["id"]),
        all: true
      )
    end

    query =
      configure("reviews", [:id])
      |> Selecto.with_cte("u", body, columns: ["uid"])
      |> Selecto.join(:uj, source: "u", source_kind: :cte, owner_key: :id, related_key: :uid)
      |> Selecto.select(["id"])

    {sql, _params} = Selecto.to_sql(query)
    assert sql =~ ~r/WITH u \(uid\) AS \(/i
    assert sql =~ ~r/UNION ALL/i
    assert refusal(query) == :ok
  end

  test "a CTE an ad-hoc join reads is no relation" do
    query =
      configure("products", [:id])
      |> Selecto.join(:recent, source: "recent", owner_key: :id, related_key: :product_id)

    assert Selecto.Executor.dynamic_sources(query) == ["recent"]
    cte = put_in(query.set.dynamic_joins.recent[:source_kind], :cte)
    assert Selecto.Executor.dynamic_sources(cte) == []
  end
end
