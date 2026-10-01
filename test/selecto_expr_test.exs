defmodule Selecto.ExprTest do
  use ExUnit.Case, async: true

  alias Selecto.Expr, as: X

  defp selecto do
    domain = %{
      name: "Expr test",
      source: %{
        source_table: "products",
        primary_key: :id,
        fields: [:id, :name, :nickname, :status, :active, :price],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          nickname: %{type: :string},
          status: %{type: :string},
          active: %{type: :boolean},
          price: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    Selecto.configure(domain, :mock_connection)
  end

  test "builds filter helpers and compact boolean groups" do
    assert X.eq("status", "active") == {"status", "active"}
    assert X.neq("status", "archived") == {"status", {:ne, "archived"}}
    assert X.gte("price", 100) == {"price", {:gte, 100}}
    assert X.not_in("status", ["archived"]) == {"status", {:not_in, ["archived"]}}
    assert X.text_search("name", "chair") == {"name", {:text_search, "chair"}}

    assert X.text_search(["name", "description"], "chair", mode: :boolean) ==
             {["name", "description"], {:text_search, "chair", mode: :boolean}}

    assert X.text_search("name", "chair", mode: :query_expansion) ==
             {"name", {:text_search, "chair", mode: :query_expansion}}

    assert X.text_search("name", query: "chair", mode: :query_expansion) ==
             {"name", {:text_search, "chair", mode: :query_expansion}}

    assert X.text_search("name",
             query: "chair",
             fields: ["name", "description"],
             mode: :boolean
           ) ==
             {"name", {:text_search, "chair", [fields: ["name", "description"], mode: :boolean]}}

    assert X.match_against("name", "chair") ==
             {"name", {:text_search, "chair", mode: :natural}}

    assert X.match_against(["name", "description"], "chair", mode: :boolean) ==
             {["name", "description"], {:text_search, "chair", mode: :boolean}}

    assert X.web_search("name", "chair") == {"name", {:text_search, "chair", mode: :websearch}}
    assert X.plain_search("name", "chair") == {"name", {:text_search, "chair", mode: :plain}}

    assert X.phrase_search("name", "wireless charger") ==
             {"name", {:text_search, "wireless charger", mode: :phrase}}

    assert X.boolean_search(["name", "description"], "foo bar") ==
             {["name", "description"], {:text_search, "foo bar", mode: :boolean}}

    assert X.field_exists("metadata.zone") == {"metadata.zone", :exists}
    assert X.array_contains("tags", ["featured"]) == {:array_contains, "tags", ["featured"]}
    assert X.starts_with("name", "Ch") == {"name", {:starts_with, "Ch"}}
    assert X.when_present(nil, &X.eq("name", &1)) == nil

    assert X.compact_and([
             X.eq("status", "active"),
             nil,
             X.when_present("", &X.case_insensitive_like("name", "%#{&1}%")),
             X.gte("price", 100)
           ]) == {:and, [{"status", "active"}, {"price", {:gte, 100}}]}
  end

  test "prefix searches bind literal LIKE wildcard characters" do
    query =
      selecto()
      |> Selecto.Query.select(["id"])
      |> Selecto.Query.filter(X.starts_with("name", "A%_!\\"))

    {sql, params} = Selecto.to_sql(query)
    assert sql =~ ~s(LIKE $1 ESCAPE '!')
    assert params == ["A!%!_!!\\%"]
  end

  test "substring searches bind literal LIKE wildcard characters" do
    assert X.text_contains("name", "Ch") == {"name", {:text_contains, "Ch"}}
    assert X.normalize({:text_contains, "name", "Ch"}) == {"name", {:text_contains, "Ch"}}

    query =
      selecto()
      |> Selecto.Query.select(["id"])
      |> Selecto.Query.filter(X.text_contains("name", "A%_!"))

    {sql, params} = Selecto.to_sql(query)
    assert sql =~ ~s(LIKE $1 ESCAPE '!')
    assert params == ["%A!%!_!!%"]
  end

  test "suffix searches bind literal LIKE wildcard characters" do
    assert X.ends_with("name", "Ch") == {"name", {:ends_with, "Ch"}}
    assert X.normalize({:ends_with, "name", "Ch"}) == {"name", {:ends_with, "Ch"}}

    query =
      selecto()
      |> Selecto.Query.select(["id"])
      |> Selecto.Query.filter(X.ends_with("name", "50%_!"))

    {sql, params} = Selecto.to_sql(query)
    assert sql =~ ~s(LIKE $1 ESCAPE '!')
    assert params == ["%50!%!_!!"]
  end

  test "literal text searches escape the SQL Server character class bracket" do
    for {filter, pattern} <- [
          {X.starts_with("name", "[a-z]"), "![a-z]%"},
          {X.text_contains("name", "[a-z]"), "%![a-z]%"},
          {X.ends_with("name", "[a-z]"), "%![a-z]"}
        ] do
      {sql, params} =
        selecto()
        |> Selecto.Query.select(["id"])
        |> Selecto.Query.filter(filter)
        |> Selecto.to_sql()

      assert sql =~ ~s(LIKE $1 ESCAPE '!')
      assert params == [pattern]
    end
  end

  test "literal text searches match only the literal text on SQLite" do
    assert {:ok, connection} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               connection,
               "CREATE TABLE products (id INTEGER, name TEXT, nickname TEXT, status TEXT, active INTEGER, price REAL)",
               [],
               []
             )

    names = ["50%", "50x", "a_b", "axb", "[a-z]", "q", "\\x", "x\\", "!x", "x!"]

    for {name, id} <- Enum.with_index(names, 1) do
      assert {:ok, _} =
               SelectoDBSQLite.Adapter.execute(
                 connection,
                 "INSERT INTO products (id, name) VALUES (?, ?)",
                 [id, name],
                 []
               )
    end

    matches = fn filter ->
      {sql, _aliases, params} =
        selecto()
        |> Map.put(:adapter, SelectoDBSQLite.Adapter)
        |> Selecto.Query.select(["name"])
        |> Selecto.Query.filter(filter)
        |> Selecto.Query.order_by(["id"])
        |> Selecto.gen_sql([])

      {:ok, %{rows: rows}} = SelectoDBSQLite.Adapter.execute(connection, sql, params, [])
      List.flatten(rows)
    end

    assert matches.(X.starts_with("name", "50%")) == ["50%"]
    assert matches.(X.text_contains("name", "_")) == ["a_b"]
    assert matches.(X.ends_with("name", "%")) == ["50%"]
    assert matches.(X.text_contains("name", "[a-z]")) == ["[a-z]"]
    assert matches.(X.starts_with("name", "\\")) == ["\\x"]
    assert matches.(X.ends_with("name", "\\")) == ["x\\"]
    assert matches.(X.starts_with("name", "!")) == ["!x"]
    assert matches.(X.ends_with("name", "!")) == ["x!"]
  end

  test "builds selector helpers with aliases and case literals" do
    assert X.field("name") == {:field, "name"}
    assert X.lit("Open") == {:literal, "Open"}
    assert X.count("*") == {:count, "*"}
    assert X.count_distinct("status") == {:count_distinct, "status"}
    assert X.as(X.count("*"), "total") == {:field, {:count, "*"}, "total"}

    assert X.concat([X.field("nickname"), X.lit(" / "), X.field("name")]) ==
             {:concat, [{:field, "nickname"}, {:literal, " / "}, {:field, "name"}]}

    assert X.greatest("price", "id") == {:greatest, ["price", "id"]}
    assert X.least(["price", "id"]) == {:least, ["price", "id"]}
    assert X.nullif("nickname", "name") == {:nullif, ["nickname", "name"]}
    assert X.stddev("price") == {:func, :stddev, ["price"]}
    assert X.variance("price") == {:func, :variance, ["price"]}

    assert X.case_when(
             [
               {X.eq("status", "active"), "Open"},
               {X.eq("status", "archived"), "Closed"}
             ],
             "Other"
           ) ==
             {:case,
              [
                {{"status", "active"}, {:literal, "Open"}},
                {{"status", "archived"}, {:literal, "Closed"}}
              ], {:literal, "Other"}}
  end

  test "deeply nested boolean filters normalize and compile in linear time" do
    leaf = {:eq, "status", "active"}

    nested = %{
      not: Enum.reduce(1..200, leaf, fn _, acc -> {:not, acc} end),
      and: Enum.reduce(1..200, leaf, fn _, acc -> {:and, [acc]} end),
      or: Enum.reduce(1..200, leaf, fn _, acc -> {:or, [acc, {:gt, "price", 1}]} end),
      mixed:
        Enum.reduce(1..200, leaf, fn depth, acc ->
          Enum.at([{:not, acc}, {:and, [acc, leaf]}, {:or, [acc]}], rem(depth, 3))
        end)
    }

    for {kind, filter} <- nested do
      task =
        Task.async(fn ->
          normalized = X.normalize(filter)
          {sql, _params} = selecto() |> Selecto.filter(filter) |> Selecto.to_sql()
          built = Enum.reduce(1..200, X.eq("status", "active"), fn _, acc -> X.not(acc) end)
          {normalized, sql, built}
        end)

      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
      assert match?({:ok, _}, result), "#{kind} nesting did not finish within a second"
      {:ok, {normalized, sql, built}} = result

      assert normalized == X.normalize(normalized)
      assert sql =~ "status"
      assert built == X.normalize(nested.not)
    end
  end

  test "normalizes helper tuples into Selecto AST" do
    assert X.normalize({:eq, "status", "active"}) == {"status", "active"}
    assert X.normalize({:as, {:count, "*"}, "total"}) == {:field, {:count, "*"}, "total"}
    assert X.normalize({:desc, "price"}) == {"price", :desc}
    assert X.normalize({:asc_nulls_last, "price"}) == {"price", :asc_nulls_last}
    assert X.normalize({:text_search, "name", "chair"}) == {"name", {:text_search, "chair"}}

    assert X.normalize({:text_search, ["name", "description"], "chair", [mode: :boolean]}) ==
             {["name", "description"], {:text_search, "chair", mode: :boolean}}

    assert X.normalize({:text_search, "name", "chair", [mode: :query_expansion]}) ==
             {"name", {:text_search, "chair", mode: :query_expansion}}

    assert X.normalize({:text_search, "name", [query: "chair", mode: :query_expansion]}) ==
             {"name", {:text_search, "chair", mode: :query_expansion}}

    assert X.normalize({:match_against, "name", "chair"}) ==
             {"name", {:text_search, "chair", mode: :natural}}

    assert X.normalize({:array_overlap, "tags", ["featured"]}) ==
             {:array_overlap, "tags", ["featured"]}

    assert X.normalize({:count_distinct, "status"}) == {:count_distinct, "status"}

    assert X.normalize({:window, {:lag, "price", 1}, over: [partition_by: ["status"]]}) ==
             {:window, {:lag, "price", 1}, over: [partition_by: ["status"]]}

    assert X.normalize({:and, [{:eq, "status", "active"}, {:gte, "price", 100}]}) ==
             {:and, [{"status", "active"}, {"price", {:gte, 100}}]}
  end

  test "builds window and json helper tuples" do
    assert X.window(:row_number, [],
             over: [partition_by: ["status"], order_by: [X.desc("price")]]
           ) ==
             {:window, {:row_number},
              over: [partition_by: ["status"], order_by: [{"price", :desc}]]}

    assert X.json_extract_text("metadata", "$.warehouse.zone", as: :warehouse_zone) ==
             {:json_extract_text, "metadata", "$.warehouse.zone", as: "warehouse_zone"}

    assert X.json_extract("metadata", "$.priority", :desc) ==
             {:json_extract, "metadata", "$.priority", :desc}
  end

  test "query entry points normalize helper-shaped inputs" do
    query =
      selecto()
      |> Selecto.select({:as, {:count, "*"}, "total"})
      |> Selecto.filter({:and, [{:eq, "active", true}, {:gte, "price", 100}]})
      |> Selecto.order_by({:desc_nulls_last, "price"})
      |> Selecto.group_by(X.rollup([{:field, "status"}]))

    assert query.set.selected == [{:field, {:count, "*"}, "total"}]
    assert query.set.filtered == [{:and, [{"active", true}, {"price", {:gte, 100}}]}]
    assert query.set.order_by == [{"price", :desc_nulls_last}]
    assert query.set.group_by == [rollup: [{:field, "status"}]]
  end

  test "query entry points support canonical macro-free runtime style" do
    query =
      selecto()
      |> Selecto.select([
        "name",
        X.as(X.avg("price"), "avg_price"),
        X.as(X.count_distinct("status"), "status_count")
      ])
      |> Selecto.filter(X.eq("active", true))
      |> Selecto.filter(X.compact_and([X.gte("price", 100), X.not_null("name")]))
      |> Selecto.order_by([X.asc("name"), X.desc("price")])
      |> Selecto.group_by(["status"])

    assert query.set.selected == [
             "name",
             {:field, {:func, "AVG", ["price"]}, "avg_price"},
             {:field, {:count_distinct, "status"}, "status_count"}
           ]

    assert query.set.filtered == [
             {"active", true},
             {:and, [{"price", {:gte, 100}}, {"name", :not_null}]}
           ]

    assert query.set.order_by == [{"name", :asc}, {"price", :desc}]
    assert query.set.group_by == ["status"]
  end

  test "pipeline helpers compose filters and selects" do
    query =
      selecto()
      |> X.merge_where([
        X.eq("active", true),
        X.when_present(nil, &X.eq("status", &1)),
        X.case_insensitive_like("name", "%chair%")
      ])
      |> X.append_select([
        X.field("name"),
        X.as(X.coalesce([X.field("nickname"), X.field("name")]), "display_name")
      ])

    assert query.set.filtered ==
             [{:and, [{"active", true}, {"name", {:case_insensitive_like, "%chair%"}}]}]

    assert query.set.selected == [
             {:field, "name"},
             {:field, {:coalesce, [{:field, "nickname"}, {:field, "name"}]}, "display_name"}
           ]

    {sql, params} = Selecto.to_sql(query)

    assert sql =~ ~r/coalesce/i
    assert sql =~ ~r/ilike/i
    assert true in params
    assert "%chair%" in params
  end

  test "append_select handles expanded selector helpers" do
    query =
      selecto()
      |> X.append_select([
        X.count_distinct("status"),
        X.as(X.concat([X.field("nickname"), X.lit(" / "), X.field("name")]), "display_label"),
        X.as(X.greatest("price", "id"), "largest_value"),
        X.as(X.nullif("nickname", "name"), "nickname_only")
      ])

    assert query.set.selected == [
             {:count_distinct, "status"},
             {:field, {:concat, [{:field, "nickname"}, {:literal, " / "}, {:field, "name"}]},
              "display_label"},
             {:field, {:greatest, ["price", "id"]}, "largest_value"},
             {:field, {:nullif, ["nickname", "name"]}, "nickname_only"}
           ]
  end

  test "append_order_by and append_group_by compose query pipeline ergonomics" do
    query =
      selecto()
      |> X.append_order_by(X.desc("price"))
      |> X.append_group_by(X.rollup([{:field, "status"}]))
      |> X.maybe_order_by(nil, &X.asc(&1))
      |> X.maybe_group_by("status", &X.rollup([{:field, &1}]))

    assert query.set.order_by == [{"price", :desc}]
    assert query.set.group_by == [rollup: [{:field, "status"}], rollup: [{:field, "status"}]]
  end
end
