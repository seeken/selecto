defmodule Selecto.SubselectGuardTest do
  use ExUnit.Case, async: true
  @adapter SelectoDBSQLite.Adapter

  test "guard rejects projected bytes before invoking a throwing JSON constructor" do
    {:ok, db} = @adapter.connect(database: ":memory:")

    try do
      {:ok, _} = @adapter.execute(db, "CREATE TABLE parents(id INTEGER);", [], [])

      {:ok, _} =
        @adapter.execute(
          db,
          "CREATE TABLE children(id INTEGER,parent_id INTEGER,name BLOB);",
          [],
          []
        )

      {:ok, _} = @adapter.execute(db, "INSERT INTO parents VALUES(1)", [], [])
      {:ok, _} = @adapter.execute(db, "INSERT INTO children VALUES(1,1,x'6162')", [], [])
      columns = %{id: %{type: :integer}, parent_id: %{type: :integer}, name: %{type: :string}}

      domain = %{
        name: "Guard",
        source: %{
          source_table: "parents",
          primary_key: :id,
          fields: [:id],
          columns: %{id: %{type: :integer}},
          redact_fields: [],
          associations: %{
            children: %{
              queryable: :children,
              owner_key: :id,
              related_key: :parent_id,
              cardinality: :many
            }
          }
        },
        schemas: %{
          children: %{
            source_table: "children",
            primary_key: :id,
            fields: Map.keys(columns),
            columns: columns,
            redact_fields: [],
            associations: %{}
          }
        },
        joins: %{children: %{type: :left}}
      }

      base =
        Selecto.configure(domain, db, adapter: @adapter, validate: false)
        |> Selecto.select(["id"])

      config = %{
        target_schema: :children,
        join_path: [:children],
        fields: ["name"],
        alias: "children",
        order_by: [{:asc, :id}],
        limit: 21,
        format: :json_agg,
        guard: %{max_rows: 20, max_scalar_bytes: 16_384, max_projected_bytes: 1}
      }

      bounded = Selecto.subselect(base, [config])
      assert {:ok, {[[1, nil]], _, _}} = Selecto.execute(bounded)
      # A BLOB is small enough to pass the enlarged budget, but SQLite's JSON
      # constructor throws. The first assertion proves the refused branch did
      # not construct or aggregate JSON merely to measure its size.
      allowed = put_in(config.guard.max_projected_bytes, 1_000)
      assert {:error, _} = base |> Selecto.subselect([allowed]) |> Selecto.execute()

      assert_raise ArgumentError, fn ->
        Selecto.subselect(base, [put_in(config.guard.max_rows, 19)])
      end
    after
      @adapter.disconnect(db)
    end
  end
end
