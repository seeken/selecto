defmodule Selecto.CoreCleanupFixesTest do
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

  test "composition invokes the supplied normalizer for final composed domain" do
    fun = fn domain ->
      send(self(), {:normalized, domain})
      {:ok, %{domain: domain}, %{errors: [], warnings: []}}
    end

    assert {:ok, %{domain: %{name: "Composed"}}, _} =
             Selecto.Domain.Compose.compose(%{name: "Base"}, [%{name: "Composed"}], fun)

    assert_receive {:normalized, %{name: "Base"}}
    assert_receive {:normalized, %{name: "Composed"}}
  end

  test "computed owner compilation configures and validates once per compile context" do
    int = %{type: :integer}

    key = %{
      type: :integer,
      computed: %{
        kind: :expression,
        expression: ["case", [["eq", "id", 1], ["field", "id"]], ["else", ["field", "id"]]]
      }
    }

    d =
      domain()
      |> put_in([:source, :columns, :key], key)
      |> update_in([:source, :fields], &[:key | &1])
      |> put_in([:source, :associations, :lines, :owner_key], :key)

    q = Selecto.configure(d, Process.get(:fix_conn), adapter: SelectoDBSQLite.Adapter)
    Code.ensure_loaded!(Selecto.ComputedOwnerKeys)
    :cprof.start(Selecto, :configure, 3)
    :cprof.start(Selecto.ComputedOwnerKeys, :errors, 1)

    try do
      # The normal SQL builder installs the shared read-clock compile context.
      Selecto.ReadClock.with_context(q, fn ->
        for _ <- 1..4, do: Selecto.Builder.OwnerKey.sql(q, :selecto_root, :key)
      end)

      :cprof.pause()
      assert {Selecto, 1, _} = :cprof.analyse(Selecto)
      assert {Selecto.ComputedOwnerKeys, 1, _} = :cprof.analyse(Selecto.ComputedOwnerKeys)
      # A changed domain cannot reuse the prior compilation's validation.
      bad =
        put_in(
          q.domain.source.columns.id,
          Map.put(int, :computed, %{kind: :expression, expression: ["literal", 1]})
        )

      assert_raise Selecto.Builder.ScopeRefusal, fn ->
        Selecto.Builder.OwnerKey.sql(bad, :selecto_root, :key)
      end
    after
      :cprof.stop()
    end
  end
end
