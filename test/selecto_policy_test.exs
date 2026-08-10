defmodule Selecto.PolicyTest do
  use ExUnit.Case, async: true

  alias Selecto.PolicyViolation

  defp domain do
    %{
      name: "Strict orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :status, :total, :team_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          status: %{type: :string},
          total: %{type: :decimal},
          team_id: %{type: :integer}
        },
        associations: %{
          team: %{queryable: :team, field: :team, owner_key: :team_id, related_key: :id}
        }
      },
      schemas: %{
        team: %{
          source_table: "teams",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{
        team: %{name: "Team", type: :left, display_field: :name}
      },
      custom_columns: %{
        "status_upper" => %{select: "UPPER(selecto_root.status)", type: :string}
      },
      query_members: %{
        values: %{
          status_labels: %{
            rows: [["open", "Open work"], ["closed", "Closed work"]],
            columns: ["status", "status_label"],
            as: "status_labels",
            join: [owner_key: :status, related_key: :status]
          }
        },
        ctes: %{
          open_orders: %{
            query: fn selecto ->
              selecto
              |> Selecto.select(["id", "status"])
              |> Selecto.filter({"status", "open"})
            end,
            columns: ["id", "status"],
            join: [owner_key: :id, related_key: :id, fields: :infer]
          }
        },
        laterals: %{},
        subqueries: %{},
        unnests: %{}
      }
    }
  end

  defp strict_query do
    Selecto.configure(domain(), :mock_connection, mode: :strict)
  end

  test "strict mode composes ordinary domain-backed queries" do
    query =
      strict_query()
      |> Selecto.select(["status", "team.name", "status_upper"])
      |> Selecto.filter({"status", "open"})
      |> Selecto.order_by({"team.name", :asc})

    assert Selecto.Policy.strict?(query)
    assert :ok = Selecto.Policy.validate_query!(query)

    {sql, params} = Selecto.to_sql(query)
    assert sql =~ "join teams"
    assert sql =~ "UPPER(selecto_root.status)"
    assert params == ["open"]
  end

  test "strict mode requires validation" do
    assert_raise PolicyViolation, ~r/requires domain validation/, fn ->
      Selecto.configure(domain(), :mock_connection, mode: :strict, validate: false)
    end
  end

  test "strict mode rejects query-authored SQL eagerly and at the compiler boundary" do
    assert_raise PolicyViolation, ~r/query-authored :raw_sql/, fn ->
      strict_query() |> Selecto.select({:raw_sql, "current_user"})
    end

    assert_raise PolicyViolation, ~r/query-authored :raw_sql_filter/, fn ->
      strict_query() |> Selecto.filter({:raw_sql_filter, "status = 'open'"})
    end

    manually_modified =
      strict_query()
      |> put_in([Access.key(:set), :selected], [{:raw_sql, "current_user"}])

    assert_raise PolicyViolation, ~r/query-authored :raw_sql/, fn ->
      Selecto.to_sql(manually_modified)
    end
  end

  test "strict mode enables declared joins but rejects ad-hoc joins and overrides" do
    declared = strict_query() |> Selecto.join(:team) |> Selecto.select(["team.name"])
    assert :ok = Selecto.Policy.validate_query!(declared)

    assert_raise PolicyViolation, ~r/not declared by the domain/, fn ->
      strict_query()
      |> Selecto.join(:audit_log,
        source: "audit_logs",
        owner_key: :id,
        related_key: :order_id
      )
    end

    assert_raise PolicyViolation, ~r/may not override its structure/, fn ->
      strict_query() |> Selecto.join(:team, type: :inner)
    end
  end

  test "strict mode seals the authored domain and compiled authority" do
    changed_domain = put_in(strict_query().domain[:source][:source_table], "other_orders")

    assert_raise PolicyViolation, ~r/domain changed after strict mode sealed it/, fn ->
      Selecto.to_sql(changed_domain |> Selecto.select(["id"]))
    end

    changed_config = put_in(strict_query().config[:source_table], "other_orders")

    assert_raise PolicyViolation, ~r/compiled domain configuration changed/, fn ->
      Selecto.to_sql(changed_config |> Selecto.select(["id"]))
    end
  end

  test "strict mode allows declared VALUES members and rejects direct row sources" do
    query =
      strict_query()
      |> Selecto.with_values(:status_labels, rows: [["open", "Ready"]])
      |> Selecto.select(["status", "status_labels.status_label"])

    assert :ok = Selecto.Policy.validate_query!(query)
    {sql, params} = Selecto.to_sql(query)
    assert sql =~ "status_labels"
    assert sql =~ "('open', 'Ready')"
    assert params == []

    assert_raise PolicyViolation, ~r/prohibits direct values sources/, fn ->
      strict_query()
      |> Selecto.with_values([["open", "Ready"]], columns: ["status", "label"], as: "labels")
    end
  end

  test "strict mode allows named CTEs that preserve the strict nested policy" do
    query =
      strict_query()
      |> Selecto.with_cte(:open_orders)
      |> Selecto.select(["id", "open_orders.status"])

    assert :ok = Selecto.Policy.validate_query!(query)
    {sql, _params} = Selecto.to_sql(query)
    assert sql =~ "WITH open_orders"

    assert_raise PolicyViolation, ~r/prohibits direct cte sources/, fn ->
      strict_query()
      |> Selecto.with_cte("manual_orders", fn ->
        Selecto.configure(domain(), :mock_connection) |> Selecto.select(["id"])
      end)
    end
  end

  test "domain_sql can prohibit even trusted SQL declared by the domain" do
    assert_raise PolicyViolation, ~r/domain_sql: :forbid/, fn ->
      Selecto.configure(domain(), :mock_connection, mode: :strict, domain_sql: :forbid)
    end

    domain_without_sql = Map.delete(domain(), :custom_columns)

    assert %Selecto{policy: %Selecto.Policy{mode: :strict, domain_sql: :forbid}} =
             Selecto.configure(domain_without_sql, :mock_connection,
               mode: :strict,
               domain_sql: :forbid
             )
  end

  test "set operations cannot mix strict and permissive queries" do
    left = strict_query() |> Selecto.select(["status"])
    strict_right = strict_query() |> Selecto.select(["status"])
    right = Selecto.configure(domain(), :mock_connection) |> Selecto.select(["status"])

    assert :ok = left |> Selecto.union(strict_right) |> Selecto.Policy.validate_query!()

    assert_raise PolicyViolation, ~r/cannot mix strict and permissive/, fn ->
      Selecto.union(left, right)
    end
  end
end
