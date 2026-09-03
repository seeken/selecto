defmodule Selecto.CoDomainComputedEligibilityTest do
  use ExUnit.Case, async: true

  defp domain do
    %{
      schema_version: 1,
      name: "Loads",
      source: %{
        source_table: "loads",
        primary_key: :id,
        fields: [:id, :status, :has_payload, :ready_for_dispatch],
        columns: %{
          id: %{type: :integer},
          status: %{type: :string},
          has_payload: %{type: :boolean},
          ready_for_dispatch: %{
            type: :boolean,
            internal: true,
            computed: %{
              kind: :predicate,
              expression: [:and, [[:in, :status, ["A", "O"]], [:eq, :has_payload, true]]]
            }
          }
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      co_domains: %{
        carriers: %{
          domain: :client,
          view: :carrier_lookup,
          search: %{fields: [:id, :name], mode: :prefix, rank: true},
          result: %{value_field: :id, label_field: :name, description_fields: [:city]}
        }
      },
      actions: %{
        dispatch: %{
          type: :update,
          selection: %{eligibility_field: :ready_for_dispatch}
        }
      }
    }
  end

  test "canonical contract preserves governed co-domains and validates eligibility" do
    assert {:ok, normalized, _diagnostics} = Selecto.Domain.validate(domain())
    assert normalized.co_domains.carriers.search.mode == :prefix
    assert Selecto.Domain.project(normalized, :ui).co_domains == normalized.co_domains
  end

  test "computed predicates compile into the primary query with bound literals" do
    query =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["id", "ready_for_dispatch"])

    {sql, _aliases, params} = Selecto.gen_sql(query, [])
    normalized_sql = String.downcase(sql)

    assert normalized_sql =~ "selecto_root.status = any"
    assert normalized_sql =~ "selecto_root.has_payload ="
    assert params == [["A", "O"], true]
  end

  test "invalid co-domains, non-boolean eligibility, and predicate cycles fail closed" do
    invalid_lookup = put_in(domain(), [:co_domains, :carriers, :search, :raw_sql], "1=1")
    assert {:error, diagnostics} = Selecto.Domain.validate(invalid_lookup)
    assert Enum.any?(diagnostics.errors, &(&1.code == :unknown_co_domain_key))

    invalid_eligibility =
      put_in(domain(), [:actions, :dispatch, :selection, :eligibility_field], :status)

    assert {:error, diagnostics} = Selecto.Domain.validate(invalid_eligibility)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_action_eligibility_field))

    cyclic =
      domain()
      |> put_in(
        [:source, :columns, :ready_for_dispatch, :computed, :expression],
        [:eq, :other_eligibility, [:field, :ready_for_dispatch]]
      )
      |> update_in([:source, :fields], &(&1 ++ [:other_eligibility]))
      |> put_in([:source, :columns, :other_eligibility], %{
        type: :boolean,
        computed: %{kind: :predicate, expression: [:eq, :ready_for_dispatch, true]}
      })

    assert {:error, diagnostics} = Selecto.Domain.validate(cyclic)
    assert Enum.any?(diagnostics.errors, &(&1.code == :computed_predicate_cycle))
  end

  test "nested predicates remain scalar expressions and SQL Server preserves unknown values" do
    nested =
      domain()
      |> update_in([:source, :fields], &(&1 ++ [:nested_eligibility]))
      |> put_in([:source, :columns, :nested_eligibility], %{
        type: :boolean,
        computed: %{kind: :predicate, expression: [:eq, :ready_for_dispatch, true]}
      })

    for adapter <- [
          SelectoDBPostgreSQL.Adapter,
          SelectoDBMySQL.Adapter,
          SelectoDBMSSQL.Adapter,
          SelectoDBSQLite.Adapter
        ] do
      query =
        nested
        |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only))
        |> Selecto.select(["id", "nested_eligibility"])
        |> Selecto.filter({"nested_eligibility", true})

      {sql, _aliases, params} = Selecto.gen_sql(query, [])
      refute sql =~ "selecto_root.nested_eligibility"
      refute sql =~ "selecto_root.ready_for_dispatch"
      assert Enum.any?(List.flatten(params), &(&1 == "A"))

      if adapter == SelectoDBMSSQL.Adapter do
        assert sql =~ "CASE WHEN"
        assert sql =~ "ELSE NULL END"
      end
    end
  end
end
