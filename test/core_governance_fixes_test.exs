defmodule Selecto.CoreGovernanceFixesTest do
  use ExUnit.Case, async: false

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

  setup do
    {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    on_exit(fn -> SelectoDBSQLite.Adapter.disconnect(conn) end)
    Process.put(:fix_conn, Selecto.Runtime.Context.new(SelectoDBSQLite.Adapter, conn))
    :ok
  end

  defp domain do
    int = %{type: :integer}

    %{
      name: "Owners",
      source:
        relation("owners", %{id: int}, %{
          lines: %{queryable: :lines, owner_key: :id, related_key: :owner_id, cardinality: :many}
        }),
      schemas: %{
        lines: relation("lines", %{id: int, owner_id: int, cost: int, note: %{type: :string}})
      },
      joins: %{}
    }
  end

  test "public and private-set unmarked selectors refuse in strict mode" do
    q =
      Selecto.configure(domain(), Process.get(:fix_conn),
        adapter: SelectoDBSQLite.Adapter,
        mode: :strict
      )

    assert_raise ArgumentError, fn -> Selecto.select(q, ["lines.cost"]) end

    for selector <- [
          {:revision_storage, "id"},
          {:association_count, "id"},
          {:association_aggregate, %{association: :lines, function: "max", field: "cost"},
           :selecto_root}
        ] do
      assert_raise Selecto.PolicyViolation, ~r/internal selector/, fn ->
        Selecto.select(q, [selector])
      end

      assert_raise Selecto.PolicyViolation, fn ->
        Selecto.gen_sql(put_in(q.set.selected, [selector]), [])
      end
    end
  end

  test "aggregate compiler revalidates specs even for direct internal calls" do
    q = Selecto.configure(domain(), Process.get(:fix_conn), adapter: SelectoDBSQLite.Adapter)

    for {function, field} <- [{"avg", "cost"}, {"sum", "note"}, {"max", "absent"}] do
      assert_raise Selecto.Builder.ScopeRefusal, fn ->
        Selecto.AssociationAggregate.compile(
          q,
          %{association: :lines, function: function, field: field},
          :selecto_root
        )
      end
    end
  end

  test "revision tokens on insert upsert or undeclared revisions refuse" do
    for {type, spec} <- [
          {:insert, %{column: "v"}},
          {:upsert, %{column: "v"}},
          {:update, nil},
          {:delete, nil}
        ] do
      op = %{type: type, row_revision: "sr1_token"}

      assert {:error, %{type: :invalid_row_revision}} =
               Selecto.RowRevision.check(op, %{row_revision: spec}, :predicate, %{}, [])

      assert {:ok, :predicate} =
               Selecto.RowRevision.check(
                 %{op | row_revision: nil},
                 %{row_revision: spec},
                 :predicate,
                 %{},
                 []
               )
    end
  end
end
