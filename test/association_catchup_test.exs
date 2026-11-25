defmodule Selecto.AssociationCatchupTest do
  use ExUnit.Case, async: true

  defp relation(table, columns, associations \\ %{}) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Map.keys(columns),
      columns: columns,
      associations: associations,
      redact_fields: []
    }
  end

  test "bridge OR owner keys count a matching leg once and exclude the owner" do
    {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    on_exit(fn -> SelectoDBSQLite.Adapter.disconnect(conn) end)

    for sql <- [
          "CREATE TABLE owners (id INTEGER)",
          "INSERT INTO owners VALUES(1),(2),(3)",
          "CREATE TABLE lines (id INTEGER,amount INTEGER)",
          "INSERT INTO lines VALUES(10,5),(11,7),(1,100)",
          "CREATE TABLE memberships (id INTEGER,line_id INTEGER,primary_owner INTEGER,alternate_owner INTEGER)",
          "INSERT INTO memberships VALUES(1,10,1,1),(2,11,2,1),(3,1,1,NULL)"
        ] do
      assert {:ok, _} = SelectoDBSQLite.Adapter.execute(conn, sql, [], [])
    end

    int = %{type: :integer}

    aggregate = %{
      type: :integer,
      computed: %{
        kind: :association_aggregate,
        association: "lines",
        function: "sum",
        field: "amount",
        default: 0,
        through_owner_keys: ["primary_owner", "alternate_owner"],
        through_exclude_owner_field: "line_id"
      }
    }

    edge = %{
      queryable: :lines,
      owner_key: :id,
      related_key: :id,
      cardinality: :many,
      through: %{table: "memberships", owner_key: :primary_owner, related_key: :line_id}
    }

    domain = %{
      name: "Owners",
      source: relation("owners", %{id: int, total: aggregate}, %{lines: edge}),
      schemas: %{
        lines: relation("lines", %{id: int, amount: int}),
        memberships:
          relation("memberships", %{
            id: int,
            line_id: int,
            primary_owner: int,
            alternate_owner: int
          })
      },
      joins: %{lines: %{type: :left}}
    }

    assert {:ok, _, _} = Selecto.Domain.validate(domain)

    query =
      Selecto.configure(domain, Selecto.Runtime.Context.new(SelectoDBSQLite.Adapter, conn),
        adapter: SelectoDBSQLite.Adapter
      )
      |> Selecto.select(["id", "total"])
      |> Selecto.order_by(["id"])

    assert {:ok, {[[1, 12], [2, 7], [3, 0]], _, _}} =
             Selecto.execute(query, analyze_complexity: false)
  end

  test "computed owner keys refuse computed dependencies and writable overrides" do
    int = %{type: :integer}

    expression = [
      "case",
      [["eq", "choice", 1], ["field", "backup"]],
      ["else", ["field", "primary"]]
    ]

    source =
      relation(
        "owners",
        %{
          id: int,
          choice: int,
          primary: int,
          backup: int,
          key: %{type: :integer, computed: %{kind: :expression, expression: expression}}
        },
        %{target: %{queryable: :targets, owner_key: :key, related_key: :id}}
      )

    domain = %{
      name: "Owners",
      source: source,
      schemas: %{targets: relation("targets", %{id: int})},
      joins: %{target: %{type: :left}}
    }

    assert Selecto.ComputedOwnerKeys.errors(domain) == []

    invalid =
      put_in(domain, [:source, :columns, :backup, :computed], %{
        kind: :expression,
        expression: ["literal", 1]
      })

    refute Selecto.ComputedOwnerKeys.errors(invalid) == []
    writes = %{relationships: %{target: %{writable: true, parent_key: :primary}}}

    assert [%{code: :computed_owner_key_read_only}] =
             Selecto.ComputedOwnerKeys.errors(Map.put(domain, :writes, writes))
  end
end
