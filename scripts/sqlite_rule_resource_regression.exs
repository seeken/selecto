# Optional public Updato/native adapter proof. Load selected runtime dependencies
# on ERL_LIBS before running: elixir scripts/sqlite_rule_resource_regression.exs
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule Selecto.Rule.NativeSQLiteResourceTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter
  alias SelectoUpdato.Error

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    sql(db, "CREATE TABLE rule_items(id INTEGER PRIMARY KEY, reference TEXT)")
    sql(db, "INSERT INTO rule_items VALUES(1,'original')")
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  test "public input rules count actual stored Unicode scalars", %{db: db} do
    exact_two = domain(%{op: "text.length", exact: 2})
    assert {:ok, _} = insert(exact_two, db, "e\u0301")
    assert rows(db) == [[1, "original"], [2, "e\u0301"]]
    before = changes(db)

    assert {:error, %Error{type: :validation}} =
             insert(domain(%{op: "text.length", exact: 1}), db, "e\u0301", 3)

    assert changes(db) == before
    assert rows(db) == [[1, "original"], [2, "e\u0301"]]
  end

  test "oversized input refuses before trim or a false condition can hide it", %{db: db} do
    domain = domain(%{op: "presence.required"})
    domain = put_in(domain, [:rules, :bindings, :check, :normalizer], %{id: :trim, version: 1})

    domain =
      put_in(domain, [:rules, :bindings, :check, :condition], %{op: "value.eq", value: "never"})

    domain =
      put_in(domain, [:rules, :normalizers], %{
        trim: %{version: 1, steps: [%{op: "text.trim", profile: "ascii_v1"}]}
      })

    before = changes(db)

    assert {:error,
            %Error{
              type: :validation,
              details: %{code: :data_rule_error, outcomes: [%{code: :evaluation_limit}]}
            }} =
             insert(domain, db, String.duplicate(" ", 17000))

    assert changes(db) == before
    assert rows(db) == [[1, "original"]]
  end

  test "logical success cannot hide a depleted shared native write rule budget", %{db: db} do
    pattern = %{op: "text.pattern", profile: "ascii_v1", pattern: "a*", match: "full"}
    expensive = %{op: "all", rules: List.duplicate(pattern, 100)}
    domain = domain(%{op: "any", rules: [%{op: "presence.required"}, expensive]})
    before = changes(db)

    assert {:error,
            %Error{
              type: :validation,
              details: %{code: :data_rule_error, outcomes: [%{code: :evaluation_limit}]}
            }} =
             insert(domain, db, String.duplicate("a", 4096))

    assert changes(db) == before
    assert rows(db) == [[1, "original"]]
  end

  test "original pattern bytes refuse before a normalizer and false condition", %{db: db} do
    pattern = %{op: "text.pattern", profile: "ascii_v1", pattern: "a", match: "full"}
    authored = domain(pattern)

    authored =
      put_in(authored, [:rules, :normalizers, :trim], %{
        version: 1,
        steps: [%{op: "text.trim", profile: "ascii_v1"}]
      })

    authored =
      put_in(authored, [:rules, :bindings, :check, :normalizer], %{id: :trim, version: 1})

    authored =
      put_in(authored, [:rules, :bindings, :check, :condition], %{op: "value.eq", value: "never"})

    before = changes(db)

    assert {:error,
            %Error{
              type: :validation,
              details: %{code: :data_rule_error, outcomes: [%{code: :evaluation_limit}]}
            }} =
             insert(authored, db, String.duplicate(" ", 5000) <> "a")

    assert changes(db) == before
    assert rows(db) == [[1, "original"]]
  end

  test "numeric work refusal precedes business DML and preserves host transaction", %{db: db} do
    digits = String.duplicate("9", 2048)
    sql(db, "DROP TABLE rule_items")
    sql(db, "CREATE TABLE rule_items(id INTEGER PRIMARY KEY,reference NUMERIC)")
    sql(db, "INSERT INTO rule_items VALUES(1,2)")

    domain =
      put_in(
        domain(%{op: "number.multiple_of", factor: digits}),
        [:source, :columns, :reference, :type],
        :decimal
      )

    sql(db, "BEGIN")
    sql(db, "UPDATE rule_items SET reference=3 WHERE id=1")
    before = changes(db)

    assert {:error,
            %Error{
              type: :validation,
              details: %{code: :data_rule_error, outcomes: [%{code: :evaluation_limit}]}
            }} = insert(domain, db, digits)

    assert changes(db) == before
    assert rows(db) == [[1, 3]]
    sql(db, "ROLLBACK")
    assert rows(db) == [[1, 2]]
  end

  test "protected candidate projection cannot bypass the resource guard", %{db: db} do
    domain = domain(%{op: "presence.required"}, :candidate)

    assert {:error,
            %Error{
              type: :validation,
              details: %{code: :data_rule_error, outcomes: [%{code: :evaluation_limit}]}
            }} =
             insert(domain, db, String.duplicate("a", 17000))

    # Native candidate projection may write its rollback-only private TEMP row.
    # Read physical business state rather than misusing total_changes for it.
    assert rows(db) == [[1, "original"]]
    assert sql(db, "SELECT name FROM temp.sqlite_master") == []
  end

  test "public advisory INPUT resource failure refuses before any business DML", %{db: db} do
    authored =
      domain(%{op: "presence.required"})
      |> put_in([:rules, :bindings, :check, :enforcement], :advisory)
      |> put_in([:rules, :bindings, :check, :condition], %{op: "value.eq", value: "never"})

    before = changes(db)

    assert {:error,
            %Error{
              details: %{
                code: :data_rule_error,
                outcomes: [%{code: :evaluation_limit, enforcement: "advisory"}]
              }
            }} = insert(authored, db, String.duplicate("a", 17000))

    assert changes(db) == before
    assert rows(db) == [[1, "original"]]
  end

  test "public advisory normalizers cannot conceal exhausted work behind a false condition", %{
    db: db
  } do
    authored =
      domain(%{op: "presence.required"})
      |> put_in([:rules, :bindings, :check, :enforcement], :advisory)
      |> put_in([:rules, :bindings, :check, :condition], %{op: "value.eq", value: "never"})
      |> put_in([:rules, :bindings, :check, :normalizer], %{id: :trim, version: 1})
      |> put_in([:rules, :normalizers], %{
        trim: %{
          version: 1,
          steps: List.duplicate(%{op: "text.trim", profile: "ascii_v1"}, 700)
        }
      })

    before = changes(db)

    assert {:error, %Error{details: %{code: :data_rule_error}}} =
             insert(authored, db, String.duplicate("a", 4000))

    assert changes(db) == before
    assert rows(db) == [[1, "original"]]
  end

  test "ordinary public advisory failure preserves successful normalization", %{db: db} do
    authored =
      domain(%{op: "value.eq", value: "never"})
      |> put_in([:rules, :bindings, :check, :enforcement], :advisory)
      |> put_in([:rules, :bindings, :check, :normalizer], %{id: :trim, version: 1})
      |> put_in([:rules, :normalizers], %{
        trim: %{version: 1, steps: [%{op: "text.trim", profile: "ascii_v1"}]}
      })

    assert {:ok, _} = insert(authored, db, " allowed ")
    assert rows(db) == [[1, "original"], [2, "allowed"]]
  end

  defp domain(test, stage \\ :input) do
    %{
      name: "Native bounded rules",
      source: %{
        source_table: "rule_items",
        primary_key: :id,
        fields: [:id, :reference],
        columns: %{id: %{type: :integer}, reference: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{id: %{insertable: true}, reference: %{insertable: true}}
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{check: %{version: 1, test: test}},
        normalizers: %{},
        bindings: %{
          check: %{
            subject: %{scope: stage, path: [:reference]},
            operations: [:insert],
            rule: %{id: :check, version: 1}
          }
        }
      }
    }
  end

  defp insert(domain, db, reference, id \\ 2),
    do:
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: id, reference: reference})
      |> SelectoUpdato.execute(%Selecto{adapter: Adapter, connection: db})

  defp sql(db, query) do
    {:ok, result} = Adapter.execute(db, query, [], [])
    result.rows
  end

  defp rows(db), do: sql(db, "SELECT id,reference FROM rule_items ORDER BY id")
  defp changes(db), do: sql(db, "SELECT total_changes()")
end
