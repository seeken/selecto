defmodule SelectoUpdato.NativeActionGrantFixture do
  @moduledoc false
  @table "selecto_cert_action_grant_people"

  def variants do
    baseline = [
      [1, 7, "one", 42, 15, "secret-one"],
      [2, 7, "two", 42, 20, "secret-two"],
      [3, 7, "wrong-owner", 77, 15, "secret-three"],
      [4, 7, "wrong-amount", 42, 40, "secret-four"],
      [8, 8, "foreign", 42, 15, "secret-eight"]
    ]

    [
      {"baseline", baseline},
      {"foreign_rows",
       List.replace_at(baseline, 4, [8, 8, "foreign-changed", 42, 15, "other"]) ++
         [[9, 8, "foreign-added", 42, 15, "other-nine"]]},
      {"secret_values", Enum.map(baseline, &List.replace_at(&1, 5, "replacement-secret"))}
    ]
  end

  def domain do
    %{
      name: "action_grants",
      domain_version: "1.0.0",
      domain_fingerprint: "sha256:action-grant-native-v1",
      source: %{
        source_table: @table,
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :name, :owner_id, :amount, :secret],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          name: %{type: :string},
          owner_id: %{type: :integer},
          amount: %{type: :integer},
          secret: %{type: :string, internal: true}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      capabilities: %{"people.rename" => %{operations: [:action, :update], action: :rename}},
      writes: %{
        operations: %{
          update: %{
            enabled: true,
            require_filter: true,
            bulk: true,
            expected_cardinality: :many,
            returning: :count
          },
          delete: %{
            enabled: true,
            require_filter: true,
            bulk: true,
            expected_cardinality: :many,
            returning: :count
          }
        },
        fields: %{name: %{updatable: true}},
        scope: %{tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}}
      },
      actions: %{
        rename: %{
          type: :detail_action,
          scope: :row,
          capability: "people.rename",
          bulk: %{enabled: true},
          execution: %{kind: :updato, operation: :update, set: %{name: "authorized-renamed"}}
        }
      }
    }
  end

  def source(connection, owner \\ 42, amount_limit \\ 25) do
    domain()
    |> Selecto.configure(connection,
      adapter: SelectoDBPostgreSQL.Adapter,
      mode: :strict,
      domain_sql: :declared
    )
    |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: :tenant_id, required: true})
    |> Selecto.apply_tenant_scope()
    |> Selecto.filter({:and, [{"owner_id", owner}, {"amount", {:lt, amount_limit}}]})
  end

  def create(connection) do
    # A fresh task database is required. An existing table is never overwritten.
    Postgrex.query!(
      connection,
      "CREATE TABLE selecto_cert_action_grant_people (id INT PRIMARY KEY, tenant_id INT NOT NULL, name TEXT NOT NULL, owner_id INT NOT NULL, amount INT NOT NULL, secret TEXT)",
      []
    )
  end

  def reset(connection, rows) do
    Postgrex.query!(connection, "DELETE FROM selecto_cert_action_grant_people", [])

    for row <- rows do
      Postgrex.query!(
        connection,
        "INSERT INTO selecto_cert_action_grant_people VALUES ($1,$2,$3,$4,$5,$6)",
        row
      )
    end

    :ok
  end

  def state(connection),
    do:
      Postgrex.query!(
        connection,
        "SELECT * FROM selecto_cert_action_grant_people ORDER BY id",
        []
      ).rows

  def cleanup(connection),
    do: Postgrex.query!(connection, "DROP TABLE selecto_cert_action_grant_people", [])

  def effect(rows, ids),
    do:
      Enum.map(rows, fn row ->
        if hd(row) in ids, do: List.replace_at(row, 2, "authorized-renamed"), else: row
      end)
end
