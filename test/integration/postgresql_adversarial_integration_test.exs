defmodule Selecto.Integration.PostgreSQLAdversarialTest do
  @moduledoc """
  Adversarial read-path checks against a live PostgreSQL database: tenant scope
  in query members, literal text matching, recursion bounds, and driver error
  disclosure. Each test works on temporary tables of its own connection.
  """

  use ExUnit.Case, async: true

  @moduletag :requires_db

  alias Selecto.Expr, as: X

  setup do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
        port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
        username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
        password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
        database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test"),
        pool_size: 1
      )

    Postgrex.query!(conn, "SET statement_timeout = '5s'", [])
    on_exit(fn -> Process.exit(conn, :normal) end)
    {:ok, conn: conn}
  end

  defp relation(table, columns, extra \\ %{}) do
    Map.merge(
      %{
        source_table: table,
        primary_key: :id,
        fields: columns |> Map.keys() |> Enum.sort(),
        redact_fields: [],
        columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
        associations: %{}
      },
      extra
    )
  end

  defp rows(selecto) do
    assert {:ok, {rows, _columns, _aliases}} = Selecto.execute(selecto)
    rows
  end

  test "query members read only the root tenant's rows", %{conn: conn} do
    Postgrex.query!(conn, "CREATE TEMP TABLE people (id int, name text, tenant_id int)", [])

    Postgrex.query!(
      conn,
      "CREATE TEMP TABLE orders (id int, person_id int, total int, tenant_id int)",
      []
    )

    Postgrex.query!(conn, "INSERT INTO people VALUES (1, 'Ann', 7)", [])
    # Tenant 8 holds an order that names tenant 7's person.
    Postgrex.query!(conn, "INSERT INTO orders VALUES (1, 1, 10, 7), (2, 1, 1000, 8)", [])

    tenant = %{tenant_field: :tenant_id}

    domain = %{
      name: "People",
      source: relation("people", %{id: :integer, name: :string, tenant_id: :integer}, tenant),
      schemas: %{
        order:
          relation(
            "orders",
            %{id: :integer, person_id: :integer, total: :integer, tenant_id: :integer},
            tenant
          )
      },
      joins: %{},
      query_members: %{
        ctes: %{
          order_totals: %{
            source: "order",
            query: %{
              "select" => [
                "person_id",
                %{"as" => "spent", "aggregate" => "sum", "field" => "total"}
              ],
              "group_by" => ["person_id"]
            },
            join: %{owner_key: "id", related_key: "person_id", type: "left"}
          }
        },
        laterals: %{
          latest_order: %{
            source: "order",
            query: %{"select" => ["total"], "order_by" => [["id", "desc"]], "limit" => 1},
            correlations: %{person_id: "id"},
            join_type: "left"
          }
        }
      }
    }

    scoped =
      domain
      |> Selecto.configure(conn)
      |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
      |> Selecto.apply_tenant_scope()

    assert [["Ann", 10]] =
             scoped
             |> Selecto.with_cte(:order_totals)
             |> Selecto.select(["name", "order_totals.spent"])
             |> rows()

    assert [["Ann", 10]] =
             scoped
             |> Selecto.with_lateral(:latest_order)
             |> Selecto.select(["name", "latest_order.total"])
             |> rows()
  end

  test "literal text searches match the literal text", %{conn: conn} do
    Postgrex.query!(conn, "CREATE TEMP TABLE labels (id int, name text)", [])

    names = ["50%", "50x", "a_b", "axb", "[a-z]", "q", "\\x", "x\\", "!x", "x!"]

    for {name, id} <- Enum.with_index(names, 1) do
      Postgrex.query!(conn, "INSERT INTO labels VALUES ($1, $2)", [id, name])
    end

    labels =
      %{name: "Labels", source: relation("labels", %{id: :integer, name: :string}), schemas: %{}}
      |> Map.put(:joins, %{})
      |> Selecto.configure(conn)
      |> Selecto.select(["name"])
      |> Selecto.order_by(["id"])

    matches = fn filter -> labels |> Selecto.filter(filter) |> rows() |> List.flatten() end

    assert matches.(X.starts_with("name", "50%")) == ["50%"]
    assert matches.(X.text_contains("name", "_")) == ["a_b"]
    assert matches.(X.ends_with("name", "%")) == ["50%"]
    assert matches.(X.text_contains("name", "[a-z]")) == ["[a-z]"]
    assert matches.(X.starts_with("name", "\\")) == ["\\x"]
    assert matches.(X.ends_with("name", "\\")) == ["x\\"]
    assert matches.(X.ends_with("name", "!")) == ["x!"]
  end

  test "a cyclic hierarchy stops at the recursion bound", %{conn: conn} do
    Postgrex.query!(conn, "CREATE TEMP TABLE members (id int, name text, team_id int)", [])
    Postgrex.query!(conn, "CREATE TEMP TABLE teams (id int, parent_id int, name text)", [])
    Postgrex.query!(conn, "INSERT INTO members VALUES (1, 'Ann', 1)", [])
    # Teams 1 and 2 are each other's parent.
    Postgrex.query!(conn, "INSERT INTO teams VALUES (1, 2, 'one'), (2, 1, 'two')", [])

    team_tree = %{
      kind: "recursive",
      source: "team",
      base: %{
        "select" => ["id", %{"as" => "depth", "value" => ["literal", 0, "integer"]}],
        "filter" => ["eq", "id", 1]
      },
      step: %{
        "select" => [
          "id",
          %{"as" => "depth", "value" => ["add", ["previous", "depth"], ["literal", 1]]}
        ]
      },
      step_join: %{owner_key: "parent_id", related_key: "id"},
      join: %{owner_key: "team_id", related_key: "id", type: "inner"}
    }

    domain = %{
      name: "Members",
      source: relation("members", %{id: :integer, name: :string, team_id: :integer}),
      schemas: %{team: relation("teams", %{id: :integer, parent_id: :integer, name: :string})},
      joins: %{},
      query_members: %{ctes: %{team_tree: team_tree}}
    }

    depths =
      domain
      |> Selecto.configure(conn)
      |> Selecto.with_cte(:team_tree)
      |> Selecto.select(["team_tree.depth"])
      |> rows()
      |> List.flatten()

    # Levels 1..100 alternate between teams 1 and 2; Ann's team 1 is the odd levels.
    assert length(depths) == 50
    assert Enum.max(depths) == 98
  end

  test "database errors do not disclose SQL, relation names or server text", %{conn: conn} do
    selecto =
      %{
        name: "Missing",
        source: relation("selecto_adv_missing_relation", %{id: :integer, name: :string}),
        schemas: %{},
        joins: %{}
      }
      |> Selecto.configure(conn)
      |> Selecto.select(["name"])
      |> Selecto.filter({"name", "canary-param"})

    for result <- [
          Selecto.execute(selecto),
          Selecto.execute_with_metadata(selecto),
          Selecto.execute_count_with_metadata(selecto)
        ] do
      assert {:error, %Selecto.Error{type: :query_error} = error} = result
      rendered = inspect(error, limit: :infinity, printable_limit: :infinity)
      refute rendered =~ "selecto_adv_missing_relation"
      refute rendered =~ "canary-param"
      refute rendered =~ ~r/\bselect\b/i
      assert error.details.sqlstate == "42P01"
      assert error.details.category == :database_error
    end
  end
end
