# Run with the real selecto_db_sqlite adapter and its dependencies on the code path:
# elixir scripts/sqlite_required_predicate_guard_regression.exs
# This optional adapter integration is deliberately outside the driver-free suite.
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoUpdato.NativeSQLiteRequiredPredicateGuardTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter
  alias SelectoUpdato.Error

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(db) end)

    {:ok, _} =
      Adapter.execute(
        db,
        "CREATE TABLE items(id INTEGER PRIMARY KEY, external_id TEXT, name TEXT, tenant_id INTEGER)",
        [],
        []
      )

    {:ok, _} =
      Adapter.execute(
        db,
        "INSERT INTO items VALUES (1,'baseline','before',7),(2,'other','before',7),(3,'baseline','before',8)",
        [],
        []
      )

    {:ok, %{db: db, domain: domain()}}
  end

  test "direct updates and deletes scope by the required predicate", %{db: db, domain: domain} do
    for type <- [:update, :delete] do
      operation = domain |> SelectoUpdato.new() |> SelectoUpdato.filter({:id, 2})

      operation =
        if type == :update,
          do: SelectoUpdato.update(operation, %{name: "stolen"}),
          else: SelectoUpdato.delete(operation)

      assert {:error, %Error{type: :cardinality_mismatch}} = execute(operation, db)
    end

    assert rows(db) == [
             [1, "baseline", "before", 7],
             [2, "other", "before", 7],
             [3, "baseline", "before", 8]
           ]

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "allowed"})

    assert {:ok, _} = execute(operation, db)

    operation =
      domain |> SelectoUpdato.new() |> SelectoUpdato.filter({:id, 1}) |> SelectoUpdato.delete()

    assert {:ok, _} = execute(operation, db)
    assert rows(db) == [[2, "other", "before", 7], [3, "baseline", "before", 8]]
  end

  test "eligibility is checked at mutation after the caller's earlier read", %{
    db: db,
    domain: domain
  } do
    read =
      Selecto.configure(domain, db, adapter: Adapter)
      |> Selecto.select(["id"])
      |> Selecto.filter({"id", 1})

    assert {:ok, {[[1]], _, _}} = Selecto.execute(read)
    {:ok, _} = Adapter.execute(db, "UPDATE items SET external_id='other' WHERE id=1", [], [])

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "stale"})

    assert {:error, %Error{type: :cardinality_mismatch}} = execute(operation, db)
    assert hd(rows(db)) == [1, "other", "before", 7]
  end

  test "insert admits only actual matching candidates and refuses null or missing fields", %{
    db: db,
    domain: domain
  } do
    for attrs <- [
          %{id: 4, external_id: "other", name: "denied"},
          %{id: 4, external_id: nil},
          %{id: 4}
        ] do
      operation = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(attrs)
      assert {:error, %Error{type: :query_enforcement}} = execute(operation, db)
      assert length(rows(db)) == 3
    end

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: 4, external_id: "baseline", name: "allowed"})

    assert {:ok, _} = execute(operation, db)
    assert List.last(rows(db)) == [4, "baseline", "allowed", nil]
  end

  test "configured SQLite backend overrides a caller's backend hint", %{db: db, domain: domain} do
    {:ok, _} =
      Adapter.execute(
        db,
        "CREATE TABLE nocase_items(id INTEGER PRIMARY KEY, external_id TEXT COLLATE NOCASE, name TEXT, tenant_id INTEGER)",
        [],
        []
      )

    domain = put_in(domain, [:source, :source_table], "nocase_items")

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: 4, external_id: "BASELINE", name: "native"})

    assert {:ok, _} = execute(operation, db, storage_backend: :caller_hint)

    assert {:ok, %{rows: [["BASELINE"]]}} =
             Adapter.execute(db, "SELECT external_id FROM nocase_items", [], [])
  end

  test "required boolean groups preserve true-only SQL null admission", %{db: db, domain: domain} do
    domain =
      Map.put(domain, :required_filters, [
        {:and,
         [
           {:or, [{"external_id", "baseline"}, {"external_id", "planned"}]},
           {:not, {"name", "blocked"}}
         ]}
      ])

    for attrs <- [
          %{id: 4, external_id: "baseline", name: nil},
          %{id: 4, external_id: "planned", name: "blocked"}
        ] do
      assert {:error, %Error{details: %{code: :query_rule_violation}}} =
               domain |> SelectoUpdato.new() |> SelectoUpdato.insert(attrs) |> execute(db)
    end

    assert {:ok, _} =
             domain
             |> SelectoUpdato.new()
             |> SelectoUpdato.insert(%{id: 4, external_id: "planned", name: "allowed"})
             |> execute(db)
  end

  test "tenant scope intersects the domain predicate on update and insert", %{
    db: db,
    domain: domain
  } do
    domain = put_in(domain, [:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})
    opts = [context: %{tenant_id: 7}]

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 3})
      |> SelectoUpdato.update(%{name: "other tenant"})

    assert {:error, %Error{type: :cardinality_mismatch}} = execute(operation, db, opts)

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: 4, external_id: "baseline", name: "allowed"})

    assert {:ok, _} = execute(operation, db, opts)
    assert List.last(rows(db)) == [4, "baseline", "allowed", 7]
  end

  test "atomic Multi rolls back earlier valid writes on native guard refusal", %{
    db: db,
    domain: domain
  } do
    runtime = %Selecto{adapter: Adapter, connection: db}

    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_update(:rename, domain,
        filters: [{:id, 1}],
        changes: %{name: "rolled back"}
      )
      |> SelectoUpdato.multi_insert(:denied, domain, %{id: 4, external_id: "other"})

    assert {:error, %Error{details: %{code: :query_rule_violation}}} =
             SelectoUpdato.run(multi, runtime)

    assert hd(rows(db)) == [1, "baseline", "before", 7]
    assert length(rows(db)) == 3
  end

  test "caller-owned transactions survive guard refusal", %{db: db, domain: domain} do
    {:ok, _} = Adapter.execute(db, "BEGIN", [], [])
    {:ok, _} = Adapter.execute(db, "UPDATE items SET name='caller' WHERE id=1", [], [])

    operation =
      domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{id: 4, external_id: "other"})

    assert {:error, %Error{type: :query_enforcement}} = execute(operation, db)
    assert hd(rows(db)) == [1, "baseline", "caller", 7]
    {:ok, _} = Adapter.execute(db, "ROLLBACK", [], [])
    assert hd(rows(db)) == [1, "baseline", "before", 7]
  end

  test "trigger transformations are refused before business mutation", %{db: db, domain: domain} do
    {:ok, _} = Adapter.execute(db, "CREATE TABLE effects(value TEXT)", [], [])

    {:ok, _} =
      Adapter.execute(
        db,
        "CREATE TRIGGER transform AFTER INSERT ON ITEMS BEGIN INSERT INTO effects VALUES ('fired'); UPDATE items SET external_id='outside' WHERE id=new.id; END",
        [],
        []
      )

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             domain
             |> SelectoUpdato.new()
             |> SelectoUpdato.insert(%{id: 4, external_id: "baseline"})
             |> execute(db)

    assert length(rows(db)) == 3
    assert {:ok, %{rows: []}} = Adapter.execute(db, "SELECT * FROM effects", [], [])
  end

  test "uppercase TEMP tables and views cannot shadow admission", %{db: db, domain: domain} do
    for ddl <- [
          "CREATE TEMP TABLE ITEMS(id INTEGER, external_id TEXT)",
          "CREATE TEMP VIEW ITEMS AS SELECT * FROM main.items"
        ] do
      {:ok, _} = Adapter.execute(db, ddl, [], [])

      assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
               domain
               |> SelectoUpdato.new()
               |> SelectoUpdato.insert(%{id: 4, external_id: "baseline"})
               |> execute(db)

      assert {:ok, %{rows: [[3]]}} =
               Adapter.execute(db, "SELECT count(*) FROM main.items", [], [])

      kind = if String.contains?(ddl, "VIEW"), do: "VIEW", else: "TABLE"
      {:ok, _} = Adapter.execute(db, "DROP #{kind} temp.ITEMS", [], [])
    end
  end

  test "required association predicates refuse execute and preview on every operation", %{
    db: db,
    domain: domain
  } do
    domain =
      domain
      |> put_in([:source, :associations], %{
        owner: %{queryable: :owner, owner_key: :id, related_key: :id}
      })
      |> Map.put(:schemas, %{
        owner: %{
          source_table: "owners",
          primary_key: :id,
          fields: [:id, :status],
          columns: %{id: %{type: :integer}, status: %{type: :string}},
          associations: %{}
        }
      })
      |> Map.put(:required_filters, [{"owner.status", "active"}])

    for type <- [:insert, :update, :delete, :upsert] do
      base = SelectoUpdato.new(domain)

      operation =
        case type do
          :insert ->
            SelectoUpdato.insert(base, %{id: 4, name: "invalid"})

          :update ->
            base |> SelectoUpdato.filter({:id, 1}) |> SelectoUpdato.update(%{name: "invalid"})

          :delete ->
            base |> SelectoUpdato.filter({:id, 1}) |> SelectoUpdato.delete()

          :upsert ->
            base
            |> SelectoUpdato.upsert(%{id: 1, name: "invalid"})
            |> SelectoUpdato.conflict_target([:id])
        end

      assert {:error, %Error{details: %{code: :query_rule_unsupported_field}}} =
               execute(operation, db)

      assert {:error, %Error{details: %{code: :query_rule_unsupported_field}}} =
               SelectoUpdato.preview(operation, %Selecto{adapter: Adapter, connection: db})
    end

    assert hd(rows(db)) == [1, "baseline", "before", 7]
  end

  test "upserts with a required predicate explicitly refuse both branches", %{
    db: db,
    domain: domain
  } do
    for id <- [1, 4] do
      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.upsert(%{id: id, external_id: "baseline", name: "invalid"})
        |> SelectoUpdato.conflict_target([:id])

      assert {:error, %Error{details: %{code: :query_enforcement_unsupported_operation}}} =
               execute(operation, db)
    end

    assert hd(rows(db)) == [1, "baseline", "before", 7]
    assert length(rows(db)) == 3
  end

  test "empty owned sync preserves ineligible children, other owners and tenants", %{
    db: db,
    domain: domain
  } do
    {:ok, _} =
      Adapter.execute(
        db,
        "CREATE TABLE parts(id INTEGER PRIMARY KEY, parent_id INTEGER, external_id TEXT, name TEXT, tenant_id INTEGER)",
        [],
        []
      )

    {:ok, _} =
      Adapter.execute(
        db,
        "INSERT INTO parts VALUES (11,1,'baseline','visible',7),(12,1,'other','hidden',7),(13,1,'baseline','other tenant',8),(21,2,'baseline','other parent',7)",
        [],
        []
      )

    child =
      domain()
      |> put_in([:source, :source_table], "parts")
      |> update_in([:source, :fields], &(&1 ++ [:parent_id]))
      |> put_in([:source, :columns, :parent_id], %{type: :integer})
      |> put_in([:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})

    root =
      domain
      |> put_in([:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})
      |> put_in([:writes, :relationships], %{
        parts: %{
          writable: true,
          cardinality: :many,
          ownership: :owned,
          allowed_ops: [:insert, :update, :delete],
          domain: child,
          child_key: :parent_id,
          parent_key: :id,
          identity_fields: [:id],
          strategy: :sync,
          delete_missing: true
        }
      })

    operation =
      root
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "sync", parts: []})

    assert {:ok, _} = execute(operation, db, context: %{tenant_id: 7})

    assert {:ok, %{rows: [[12], [13], [21]]}} =
             Adapter.execute(db, "SELECT id FROM parts ORDER BY id", [], [])
  end

  test "canonical required write fields are enforced without a database constraint", %{
    db: db,
    domain: domain
  } do
    domain = put_in(domain, [:writes, :fields, :name, :required], true)

    for attrs <- [
          %{id: 4, external_id: "baseline"},
          %{id: 4, external_id: "baseline", name: nil},
          %{id: 4, external_id: "baseline", name: "  \t"}
        ] do
      operation = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(attrs)

      assert {:error, %Error{details: %{code: :missing_required_write_fields}}} =
               execute(operation, db)

      assert length(rows(db)) == 3
    end

    assert {:ok, _} =
             domain
             |> SelectoUpdato.new()
             |> SelectoUpdato.insert(%{id: 4, external_id: "baseline", name: "present"})
             |> execute(db)

    assert List.last(rows(db)) == [4, "baseline", "present", nil]
  end

  defp domain do
    %{
      name: "RequiredGuard",
      required_filters: [{"external_id", "baseline"}],
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :external_id, :name, :tenant_id],
        columns: %{
          id: %{type: :integer},
          external_id: %{type: :string},
          name: %{type: :string},
          tenant_id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          delete: %{enabled: true},
          upsert: %{enabled: true, conflict_targets: [[:id]]}
        },
        fields: %{
          id: %{insertable: true},
          external_id: %{insertable: true, updatable: true},
          name: %{insertable: true, updatable: true},
          tenant_id: %{insertable: true, immutable: true}
        }
      }
    }
  end

  defp execute(operation, db, opts \\ []),
    do: SelectoUpdato.execute(operation, %Selecto{adapter: Adapter, connection: db}, opts)

  defp rows(db) do
    {:ok, %{rows: rows}} =
      Adapter.execute(db, "SELECT id,external_id,name,tenant_id FROM items ORDER BY id", [], [])

    rows
  end
end
