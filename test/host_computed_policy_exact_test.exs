defmodule Selecto.HostComputedPolicyExactTest do
  # Computed predicate bodies named by a host predicate and association
  # `where` policies are host scope: on an exact-compare adapter (MySQL,
  # MariaDB) their equality leaves compare by declared type (known text by
  # utf8mb4 bytes, known non-text plainly, undeclared guarded by the column's
  # collation). A retarget onto a where-confined association re-applies the
  # policy to its target rows on every adapter. Other adapters compile the
  # plain comparison.
  # Not async: the SQLite read logs a complexity warning that a concurrent
  # capture_log test would see.
  use ExUnit.Case, async: false

  defmodule ExactAdapter do
    @moduledoc false
    def name, do: :exact_test
    def supports?(feature), do: feature in [:exact_tenant_compare]
    def quote_identifier(identifier), do: "`#{String.replace(identifier, "`", "``")}`"
    def placeholder(_index), do: "?"
  end

  @exact_org "(selecto_root.org_key = ? AND CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) = CAST(? AS BINARY))"

  defp compile(domain, adapter, fun) do
    {sql, params} =
      domain
      |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
      |> fun.()
      |> Selecto.to_sql()

    {String.replace(sql, ~r/\s+/, " "), params}
  end

  defp markers(sql), do: sql |> String.graphemes() |> Enum.count(&(&1 == "?"))

  describe "computed predicates in host predicates" do
    defp computed_domain(required) do
      %{
        name: "HS",
        source: %{
          source_table: "hs",
          primary_key: :id,
          fields: [:id, :org_key, :name, :is_t1, :is_t1_or, :is_not_t1, :is_in, :is_named],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            org_key: %{type: :string},
            name: %{type: :string},
            is_t1: %{
              type: :boolean,
              computed: %{kind: :predicate, expression: ["eq", "org_key", "t1"]}
            },
            is_t1_or: %{
              type: :boolean,
              computed: %{
                kind: :predicate,
                expression: ["or", [["eq", "org_key", "t1"], ["eq", "org_key", "zz"]]]
              }
            },
            is_not_t1: %{
              type: :boolean,
              computed: %{kind: :predicate, expression: ["not", ["neq", "org_key", "t1"]]}
            },
            is_in: %{
              type: :boolean,
              computed: %{kind: :predicate, expression: ["in", "org_key", ["t1", "zz"]]}
            },
            is_named: %{
              type: :boolean,
              computed: %{kind: :predicate, expression: ["eq", "name", "a"]}
            }
          },
          associations: %{}
        },
        schemas: %{},
        joins: %{}
      }
      |> then(&if(required, do: Map.put(&1, :required_filters, required), else: &1))
    end

    test "a host predicate on a computed predicate compares its body exactly" do
      for field <- ["is_t1", "is_t1_or", "is_not_t1", "is_in"],
          {domain, fun} <- [
            {computed_domain([{field, true}]), &Selecto.select(&1, ["id"])},
            {computed_domain(nil),
             &(&1
               |> Selecto.Tenant.require_tenant_filter({field, true})
               |> Selecto.select(["id"]))},
            {computed_domain([{:or, [{field, true}, {"id", {:lt, 0}}]}]),
             &Selecto.select(&1, ["id"])}
          ] do
        {sql, params} = compile(domain, ExactAdapter, fun)

        assert sql =~ @exact_org or
                 sql =~
                   "(selecto_root.org_key IN (?, ?) AND CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) IN (CAST(? AS BINARY), CAST(? AS BINARY)))",
               field

        assert markers(sql) == length(params), field

        {plain, _params} = compile(domain, SelectoDBSQLite.Adapter, fun)
        refute plain =~ "BINARY", field
      end
    end

    test "a caller filter on a computed predicate stays plain" do
      {sql, _params} =
        compile(computed_domain(nil), ExactAdapter, fn s ->
          s |> Selecto.filter([{"is_t1", true}]) |> Selecto.select(["id"])
        end)

      refute sql =~ "BINARY"
    end

    test "only the computed columns the host names widen exactness" do
      {sql, _params} =
        compile(computed_domain([{"is_named", true}]), ExactAdapter, fn s ->
          s |> Selecto.filter([{"is_t1", true}]) |> Selecto.select(["id"])
        end)

      assert sql =~ "CAST(CONVERT(selecto_root.name USING utf8mb4) AS BINARY)"
      refute sql =~ "CONVERT(selecto_root.org_key"
    end
  end

  describe "association where policies" do
    defp policy_domain(site_type, bridge_declared? \\ false) do
      acc_columns =
        %{
          id: %{type: :integer},
          label: %{type: :string},
          active: %{type: :boolean},
          site: %{type: site_type}
        }

      schemas = %{
        acc: %{
          source_table: "wp_acc",
          primary_key: :id,
          fields: [:id, :site, :label, :active],
          redact_fields: [],
          columns: acc_columns,
          associations: %{}
        }
      }

      schemas =
        if bridge_declared? do
          Map.put(schemas, :bridge, %{
            source_table: "wp_bridge",
            primary_key: :item_id,
            fields: [:item_id, :acc_id, :site],
            redact_fields: [],
            columns: %{
              item_id: %{type: :integer},
              acc_id: %{type: :integer},
              site: %{type: :string}
            },
            associations: %{}
          })
        else
          schemas
        end

      %{
        name: "WP",
        source: %{
          source_table: "wp_items",
          primary_key: :id,
          fields: [:id, :tenant_key, :account_id],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            tenant_key: %{type: :string},
            account_id: %{type: :integer}
          },
          tenant_field: :tenant_key,
          associations: %{
            a: %{
              queryable: :acc,
              field: :a,
              owner_key: :account_id,
              related_key: :id,
              cardinality: :one,
              where: %{site: "s1", active: true}
            },
            th: %{
              queryable: :acc,
              field: :th,
              owner_key: :id,
              related_key: :id,
              cardinality: :many,
              through: %{
                table: "wp_bridge",
                owner_key: :item_id,
                related_key: :acc_id,
                where: %{site: "s1"}
              }
            }
          }
        },
        schemas: schemas,
        joins: %{a: %{type: :left, name: "a"}, th: %{type: :left, name: "th"}}
      }
    end

    defp tenant(s), do: Selecto.with_tenant(s, "t7")

    test "a join and a through bridge compare the policy by declared type" do
      shapes = [
        {"a", &(&1 |> tenant() |> Selecto.select(["id", "a.label"]))},
        {"th_bridge", &(&1 |> tenant() |> Selecto.select(["id", "th.label"]))}
      ]

      for {alias_name, fun} <- shapes do
        {text, params} = compile(policy_domain(:string), ExactAdapter, fun)
        assert markers(text) == length(params)

        if alias_name == "a" do
          assert text =~
                   ~r/\(\w+\.`site` = \? AND CAST\(CONVERT\(\w+\.`site` USING utf8mb4\) AS BINARY\) = CAST\(\? AS BINARY\)\)/

          # A declared boolean policy column keeps the plain comparison.
          assert text =~ ~r/\w+\.`active` = \?/
          refute text =~ ~r/CONVERT\(\w+\.`active`/
        else
          # An undeclared bridge relation is guarded by the column's collation.
          assert text =~
                   "(th_bridge.`site` = ? AND (COLLATION(th_bridge.`site`) = 'binary' OR CAST(CONVERT(th_bridge.`site` USING utf8mb4) AS BINARY) = CAST(? AS BINARY)))"
        end

        # An unrecognised target column type is guarded; an integer one is plain.
        {guarded, _} = compile(policy_domain("site_code"), ExactAdapter, fun)
        if alias_name == "a", do: assert(guarded =~ ~r/COLLATION\(\w+\.`site`\) = 'binary'/)

        {numeric, _} = compile(policy_domain(:integer), ExactAdapter, fun)
        if alias_name == "a", do: refute(numeric =~ ~r/CONVERT\(\w+\.`site`/)

        {plain, _} = compile(policy_domain(:string), SelectoDBSQLite.Adapter, fun)
        refute plain =~ "BINARY"
        refute plain =~ "COLLATION"
      end

      # A declared text bridge column compares exactly.
      {declared, _} =
        compile(
          policy_domain(:string, true),
          ExactAdapter,
          &(&1 |> tenant() |> Selecto.select(["id", "th.label"]))
        )

      assert declared =~
               "CAST(CONVERT(th_bridge.`site` USING utf8mb4) AS BINARY) = CAST(? AS BINARY)"
    end
  end

  describe "a retarget onto a where-confined association" do
    test "re-applies the policy to the target rows on every adapter" do
      for strategy <- [:in, :exists] do
        fun = fn s ->
          s
          |> tenant()
          |> Selecto.retarget("a", strategy: strategy)
          |> Selecto.select(["id", "label"])
        end

        {exact, params} = compile(policy_domain(:string), ExactAdapter, fun)
        assert markers(exact) == length(params), inspect(strategy)

        assert exact =~
                 "(selecto_root.`active` = ? AND (selecto_root.`site` = ? AND CAST(CONVERT(selecto_root.`site` USING utf8mb4) AS BINARY) = CAST(? AS BINARY)))",
               inspect(strategy)

        {plain, plain_params} = compile(policy_domain(:string), SelectoDBSQLite.Adapter, fun)

        assert plain =~ ~s{("selecto_root"."active" = ? AND "selecto_root"."site" = ?)} or
                 plain =~ ~s{(selecto_root."active" = ? AND selecto_root."site" = ?)},
               plain

        assert markers(plain) == length(plain_params)
        assert Enum.take(plain_params, -2) == [true, "s1"]
      end
    end

    test "returns only the policy's rows when keys repeat across scopes (SQLite)" do
      {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

      for sql <- [
            "CREATE TABLE wp_items (id INTEGER PRIMARY KEY, tenant_key TEXT, account_id INTEGER)",
            "CREATE TABLE wp_acc (id INTEGER NOT NULL, site TEXT, label TEXT, active BOOLEAN)",
            "CREATE TABLE wp_bridge (item_id INTEGER, acc_id INTEGER, site TEXT)",
            "INSERT INTO wp_items VALUES (1, 't7', 101)",
            "INSERT INTO wp_acc VALUES (101, 's1', 'mine', 1), (101, 's2', 'SECRET-s2', 1), (101, 'S1', 'SECRET-S1', 1)"
          ],
          do: {:ok, _} = SelectoDBSQLite.Adapter.execute(conn, sql, [], [])

      # (A boolean policy value does not bind as SQLite's stored 1, so this
      # domain keeps the text pin only.)
      domain =
        update_in(
          policy_domain(:string),
          [:source, :associations, :a, :where],
          &Map.delete(&1, :active)
        )

      for strategy <- [:in, :exists] do
        {:ok, {rows, _, _}} =
          domain
          |> Selecto.configure(conn, adapter: SelectoDBSQLite.Adapter, validate: false)
          |> tenant()
          |> Selecto.retarget("a", strategy: strategy)
          |> Selecto.select(["id", "label"])
          |> Selecto.execute()

        assert rows == [[101, "mine"]], inspect(strategy)
      end
    end

    test "a target without a policy compiles as before" do
      fun = fn s -> s |> tenant() |> Selecto.retarget("th") |> Selecto.select(["id", "label"]) end
      {plain, _} = compile(policy_domain(:string), SelectoDBSQLite.Adapter, fun)
      refute plain =~ ~s{selecto_root."site"}
    end
  end
end
