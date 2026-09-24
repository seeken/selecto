defmodule Selecto.ComputedValueColumnsTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.Contract.ComputedValues

  defp columns(extra) do
    Map.merge(
      %{
        id: %{type: :integer},
        person_id: %{type: :integer},
        state: %{type: :string},
        total: %{type: :decimal},
        payload: %{type: :jsonb},
        buyer: %{
          type: :string,
          computed: %{
            kind: :expression,
            expression: [
              "coalesce",
              ["field", "person.nickname"],
              ["field", "person.name"],
              ["literal", "Unassigned"]
            ]
          }
        },
        order_band: %{
          type: :string,
          computed: %{
            kind: :expression,
            expression: [
              "case",
              [["gte", "total", 20], ["literal", "large"]],
              [["eq", "state", "orphan"], ["literal", "orphan"]],
              ["else", ["literal", "standard"]]
            ]
          }
        },
        half_total: %{
          type: :decimal,
          computed: %{
            kind: :expression,
            expression: ["divide", ["field", "total"], ["literal", 2]]
          }
        },
        first_sku: %{
          type: :string,
          computed: %{
            kind: :expression,
            expression: ["json_text", "payload", ["items", 0, "sku"]]
          }
        }
      },
      extra
    )
  end

  defp domain(extra \\ %{}) do
    cols = columns(extra)

    %{
      schema_version: 1,
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: Map.keys(cols),
        redact_fields: [],
        columns: cols,
        associations: %{
          person: %{queryable: :person, owner_key: :person_id, related_key: :id}
        }
      },
      schemas: %{
        person: %{
          source_table: "people",
          primary_key: :id,
          fields: [:id, :name, :nickname],
          columns: %{id: %{type: :integer}, name: %{type: :string}, nickname: %{type: :string}},
          redact_fields: [],
          associations: %{}
        }
      },
      joins: %{person: %{type: :left, name: "Person"}}
    }
  end

  defp sql(query) do
    {sql, _aliases, params} = Selecto.gen_sql(query, [])
    {sql, params}
  end

  test "value expressions validate as part of the canonical contract" do
    assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate(domain())
  end

  test "coalesce across an association introduces its join and binds the literal" do
    {sql, params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["id", "buyer"])
      |> sql()

    assert sql =~ ~r/COALESCE\(/
    assert String.downcase(sql) =~ "join people"
    assert "Unassigned" in params
  end

  test "case, divide, and json_text compile with bound values" do
    {sql, params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["order_band", "half_total", "first_sku"])
      |> sql()

    assert sql =~ "CASE WHEN"
    assert sql =~ "AS NUMERIC) / CAST("
    assert sql =~ "JSONB_EXTRACT_PATH_TEXT(CAST("
    assert ["large", "orphan", "standard"] -- params == []
    assert ["items", "0", "sku"] -- params == []
  end

  test "computed values can be filtered, grouped, and ordered" do
    {sql, _params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["order_band", {:count}])
      |> Selecto.filter({"order_band", {:!=, "orphan"}})
      |> Selecto.group_by(["order_band"])
      |> Selecto.order_by("order_band")
      |> sql()

    # Grouping and ordering refer to the selected output by position, so the
    # separately numbered parameters cannot make the expressions differ.
    assert String.downcase(sql) =~ ~r/group by 1\s/
    assert String.downcase(sql) =~ ~r/order by 1 asc/
    assert length(Regex.scan(~r/CASE WHEN/, sql)) == 2
  end

  defp rejected?(extra) do
    match?({:error, _}, Selecto.Domain.validate(domain(extra)))
  end

  test "unsafe or ill-typed value expressions fail closed" do
    assert rejected?(%{
             bad: %{type: :string, computed: %{kind: :expression, expression: ["sql", "now()"]}}
           })

    assert rejected?(%{
             bad: %{type: :string, computed: %{kind: :expression, expression: ["literal", nil]}}
           })

    assert rejected?(%{
             bad: %{
               type: :string,
               computed: %{kind: :expression, expression: ["cast", ["field", "id"], "bytea"]}
             }
           })

    assert rejected?(%{
             bad: %{
               type: :string,
               computed: %{kind: :expression, expression: ["json_text", "payload", ["a'b"]]}
             }
           })

    assert rejected?(%{
             bad: %{
               type: :string,
               computed: %{kind: :expression, expression: ["upper", ["field", "total"]]}
             }
           })

    assert rejected?(%{
             bad: %{
               type: :integer,
               computed: %{kind: :expression, expression: ["field", "state"]}
             }
           })

    assert rejected?(%{
             loop_a: %{
               type: :string,
               computed: %{kind: :expression, expression: ["upper", ["field", "loop_b"]]}
             },
             loop_b: %{
               type: :string,
               computed: %{kind: :expression, expression: ["lower", ["field", "loop_a"]]}
             }
           })
  end

  test "untyped literals infer the same types as other runtimes" do
    assert {:ok, ["literal", 100, "integer"]} = ComputedValues.normalize(["literal", 100])
    assert {:ok, ["literal", 2.5, "decimal"]} = ComputedValues.normalize(["literal", 2.5])
    assert {:ok, ["literal", "x", "string"]} = ComputedValues.normalize(["literal", "x"])
    assert {:ok, ["literal", true, "boolean"]} = ComputedValues.normalize(["literal", true])
  end
end
