defmodule Selecto.Integration.PostgreSQLRetargetScopeKeysTest do
  # The retarget scope-key fixture on PostgreSQL (see RetargetScopeKeysTest).
  use ExUnit.Case, async: false

  @moduletag :requires_db

  # The retarget scope-key fixture (intprobe4). Accounts and regions are
  # confined only by scope keys and repeat their ids across tenants:
  # v1 names the keys tenant_key -> org_key -> org_key, v3 tenant_key all the
  # way. Tenant t7 must never reach t8's SECRET rows, nor a case variant
  # 'T7' on a case-insensitive collation (the physical key is (id, label)).
  @variants [:v1, :v3]

  defp retarget_statements(variant) do
    {prefix, key} = if variant == :v1, do: {"rs", "org_key"}, else: {"rs2", "tenant_key"}

    [
      "CREATE TABLE #{prefix}_items (id INT PRIMARY KEY, tenant_key VARCHAR(16) NOT NULL, account_id INT, name VARCHAR(20))",
      "CREATE TABLE #{prefix}_acc (id INT NOT NULL, #{key} VARCHAR(16) NOT NULL, region_id INT, label VARCHAR(40), PRIMARY KEY (id, label))",
      "CREATE TABLE #{prefix}_reg (id INT NOT NULL, #{key} VARCHAR(16) NOT NULL, label VARCHAR(40), PRIMARY KEY (id, label))",
      "INSERT INTO #{prefix}_items VALUES (1, 't7', 101, 'own'), (2, 't8', 101, 'other')",
      "INSERT INTO #{prefix}_acc VALUES (101, 't7', 201, 'mine'), (101, 't8', 201, 'SECRET-t8'), (101, 'T7', 201, 'SECRET-T7')",
      "INSERT INTO #{prefix}_reg VALUES (201, 't7', 'reg-mine'), (201, 't8', 'SECRET-reg-t8'), (201, 'T7', 'SECRET-reg-T7')"
    ]
  end

  defp retarget_domain(variant) do
    {prefix, key} = if variant == :v1, do: {"rs", :org_key}, else: {"rs2", :tenant_key}

    relation = fn table, columns, associations ->
      %{
        source_table: table,
        primary_key: :id,
        fields: Keyword.keys(columns),
        redact_fields: [],
        columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
        associations: associations
      }
    end

    %{
      name: "Items",
      source:
        relation.(
          "#{prefix}_items",
          [id: :integer, tenant_key: :string, account_id: :integer, name: :string],
          %{
            a: %{
              queryable: :acc,
              field: :a,
              owner_key: :account_id,
              related_key: :id,
              cardinality: :one,
              source_scope_key: :tenant_key,
              target_scope_key: key
            }
          }
        )
        |> Map.put(:tenant_field, :tenant_key),
      schemas: %{
        acc:
          relation.(
            "#{prefix}_acc",
            [{:id, :integer}, {key, :string}, {:region_id, :integer}, {:label, :string}],
            %{
              reg: %{
                queryable: :reg,
                field: :reg,
                owner_key: :region_id,
                related_key: :id,
                cardinality: :one,
                source_scope_key: key,
                target_scope_key: key
              }
            }
          ),
        reg: relation.("#{prefix}_reg", [{:id, :integer}, {key, :string}, {:label, :string}], %{})
      },
      joins: %{a: %{type: :left, name: "a", joins: %{reg: %{type: :left, name: "reg"}}}}
    }
  end

  # Every retarget (in and exists, one and two hops) under the engine tenant
  # and under a required filter: {label, query, expected labels}.
  defp retarget_cases(base) do
    for bound <- [:engine, :required],
        strategy <- [:in, :exists],
        {target, expected} <- [{:a, ["mine"]}, {"a.reg", ["reg-mine"]}] do
      bounded =
        if bound == :engine,
          do: Selecto.with_tenant(base, "t7"),
          else: Selecto.Tenant.require_tenant_filter(base, "tenant_key", "t7")

      query =
        bounded
        |> Selecto.retarget(target, strategy: strategy)
        |> Selecto.select(["id", "label"])

      {"#{bound} #{strategy} #{target}", query, expected}
    end
  end

  defp retarget_labels(query) do
    {:ok, {rows, _columns, _aliases}} = Selecto.execute(query)
    rows |> Enum.map(&List.last/1) |> Enum.sort()
  end

  for variant <- @variants do
    test "#{variant}: every retarget reaches only the own scope's rows on PostgreSQL" do
      {:ok, conn} = Postgrex.start_link(connection_options())
      schema = "selecto_retarget_scope_#{System.unique_integer([:positive])}"
      Postgrex.query!(conn, "CREATE SCHEMA #{schema}", [])

      try do
        {:ok, scoped} =
          Postgrex.start_link(Keyword.put(connection_options(), :parameters, search_path: schema))

        try do
          for statement <- retarget_statements(unquote(variant)),
              do: Postgrex.query!(scoped, statement, [])

          base =
            Selecto.configure(retarget_domain(unquote(variant)), scoped,
              adapter: SelectoDBPostgreSQL.Adapter,
              validate: false
            )

          for {label, query, expected} <- retarget_cases(base) do
            assert retarget_labels(query) == expected, label
          end
        after
          GenServer.stop(scoped)
        end
      after
        Postgrex.query!(conn, "DROP SCHEMA #{schema} CASCADE", [])
        GenServer.stop(conn)
      end
    end
  end

  defp connection_options do
    [
      hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
      username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
      password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
      database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test")
    ]
  end
end
