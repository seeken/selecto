defmodule Selecto.StorageIdentityCompareTest do
  # Comparisons compiled from the storage types an adapter loads before a
  # read (`prepare_read/2`):
  # - MySQL-family (item 62a): a host, trusted, required or tenant
  #   comparison, or an association `where` pin, on a column stored as
  #   TIMESTAMP compares UNIX_TIMESTAMP(col) with an epoch computed in
  #   Elixir, so a time_zone switch inside the statement cannot move it;
  # - DuckDB (items 38, 53): one on a VARCHAR identity column compares the
  #   UTF-8 bytes under every operator, whatever the collation.
  # Caller filters on other columns, and compiles without loaded types, are
  # unchanged.
  use ExUnit.Case, async: true

  alias Selecto.Builder.ExactCompare

  defmodule TestAdapter do
    @moduledoc false
    def name, do: :storage_test
    def supports?(feature), do: feature in [:rollup_without_empty_total]
    def quote_identifier(identifier), do: "\"#{identifier}\""
    def placeholder(_index), do: "?"
  end

  defp domain(required_filters, where \\ %{}) do
    %{
      name: "Events",
      source: %{
        source_table: "events",
        primary_key: :id,
        tenant_field: :org_key,
        fields: [:id, :org_key, :ts, :note, :site_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          org_key: %{type: :string},
          ts: %{type: :utc_datetime},
          note: %{type: :string},
          site_id: %{type: :integer}
        },
        associations: %{
          site: %{
            queryable: :sites,
            field: :site,
            owner_key: :site_id,
            related_key: :id,
            cardinality: :one,
            where: where
          }
        }
      },
      schemas: %{
        sites: %{
          source_table: "sites",
          primary_key: :id,
          fields: [:id, :opened, :name],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            opened: %{type: :utc_datetime},
            name: %{type: :string}
          },
          associations: %{}
        }
      },
      joins: %{site: %{type: :left, name: "site"}},
      required_filters: required_filters
    }
  end

  defp compile(domain, set, filters) do
    selecto =
      domain
      |> Selecto.configure(Selecto.Runtime.Context.new(TestAdapter, :compile_only),
        validate: false
      )
      |> Selecto.with_tenant("t1")

    selecto = %{selecto | set: Map.merge(selecto.set, set)}

    {sql, params} =
      selecto
      |> Selecto.select(["id", "site.name"])
      |> Selecto.filter(filters)
      |> Selecto.to_sql()

    {String.replace(sql, ~r/\s+/, " "), params}
  end

  @timestamps %{
    storage_column_types: %{
      "id" => MapSet.new(["int"]),
      "org_key" => MapSet.new(["varchar"]),
      "ts" => MapSet.new(["timestamp"]),
      "opened" => MapSet.new(["timestamp"]),
      "note" => MapSet.new(["varchar"]),
      "site_id" => MapSet.new(["int"]),
      "name" => MapSet.new(["varchar"])
    },
    zone_independent_timestamps: true
  }

  test "TIMESTAMP scope comparisons and pins compare epochs" do
    {sql, params} =
      compile(
        domain([{"ts", {:lt, "2024-01-01 00:00:00"}}], %{opened: "2023-06-01 00:00:00"}),
        @timestamps,
        [{"note", "x"}]
      )

    # Exact on its own: a zero date keeps the native comparison (R5).
    assert sql =~
             "(CASE WHEN selecto_root.ts = 0 THEN selecto_root.ts < ? " <>
               "ELSE UNIX_TIMESTAMP(selecto_root.ts) < ? END)"

    assert sql =~ ~s|ELSE UNIX_TIMESTAMP(site."opened") = ? END|
    assert 1_704_067_200 in params
    assert 1_685_577_600 in params
    # The caller's own filter on another column is unchanged.
    assert sql =~ "selecto_root.note = ?"
  end

  test "set operation operands compile with the loaded storage types" do
    base =
      domain([{"ts", {:lt, "2024-01-01 00:00:00"}}])
      |> Selecto.configure(Selecto.Runtime.Context.new(TestAdapter, :compile_only),
        validate: false
      )
      |> Selecto.select(["id"])

    union = Selecto.union(base, base)
    union = %{union | set: Map.merge(union.set, @timestamps)}
    {sql, _params} = Selecto.to_sql(union)
    sql = String.replace(sql, ~r/\s+/, " ")

    assert length(String.split(sql, "UNIX_TIMESTAMP(selecto_root.ts) <")) == 3
  end

  test "without loaded types, or on a DATETIME column, the comparison is plain" do
    {sql, _params} = compile(domain([{"ts", {:lt, "2024-01-01 00:00:00"}}]), %{}, [])
    refute sql =~ "UNIX_TIMESTAMP"
    assert sql =~ "selecto_root.ts < ?"

    datetime = put_in(@timestamps, [:storage_column_types, "ts"], MapSet.new(["datetime"]))
    {sql, _params} = compile(domain([{"ts", {:lt, "2024-01-01 00:00:00"}}]), datetime, [])
    refute sql =~ "UNIX_TIMESTAMP(selecto_root.ts)"
  end

  test "a declared temporal scope column the lookup did not resolve is refused" do
    unresolved = update_in(@timestamps, [:storage_column_types], &Map.delete(&1, "ts"))

    assert_raise Selecto.Builder.ScopeRefusal, ~r/did not resolve/, fn ->
      compile(domain([{"ts", {:lt, "2024-01-01 00:00:00"}}]), unresolved, [])
    end
  end

  test "a host-named computed predicate's TIMESTAMP body compares epochs (R7)" do
    domain =
      domain([{"early", false}])
      |> update_in([:source, :fields], &(&1 ++ [:early]))
      |> put_in([:source, :columns, :early], %{
        type: :boolean,
        computed: %{kind: :predicate, expression: ["lt", "ts", "2024-01-01 00:00:00"]}
      })

    {sql, _params} = compile(domain, @timestamps, [])
    assert sql =~ "ELSE UNIX_TIMESTAMP(selecto_root.ts) < ? END"
  end

  test "a name stored as TIMESTAMP and another type is not rewritten blindly (R5)" do
    mixed =
      put_in(@timestamps, [:storage_column_types, "ts"], MapSet.new(["timestamp", "datetime"]))

    assert_raise Selecto.Builder.ScopeRefusal, fn ->
      compile(domain([{"ts", {:lt, "2024-01-01 00:00:00"}}]), mixed, [])
    end
  end

  test "MySQL-family identity text ranges and patterns compare bytes; TIMESTAMP patterns refuse" do
    {sql, _params} =
      compile(
        domain([
          {"org_key", {:between, "t1", "t1"}},
          {"org_key", {:starts_with, "t1"}},
          {"note", {:gte, "a"}}
        ]),
        @timestamps,
        [{"site.name", {:gte, "z"}}]
      )

    assert sql =~
             "CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) >= CAST(? AS BINARY)"

    assert sql =~
             "CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) LIKE CAST(? AS BINARY) ESCAPE '!'"

    assert sql =~ "CAST(CONVERT(selecto_root.note USING utf8mb4) AS BINARY) >= CAST(? AS BINARY)"

    for filter <- [
          {"ts", {:starts_with, "2023"}},
          {"ts", {:like, "2023%"}}
        ] do
      assert %Selecto.Builder.ScopeRefusal{reason: :timestamp_operator} =
               catch_error(compile(domain([filter]), @timestamps, []))
    end
  end

  test "DuckDB identity prefixes use prefix(); other patterns refuse (R3)" do
    bytes = %{
      storage_column_types: Map.delete(@timestamps.storage_column_types, "ts"),
      identity_text_bytes: true
    }

    {sql, _params} =
      compile(
        domain([{"org_key", {:starts_with, "t1"}}, {"org_key", {:between, "a", "z"}}]),
        bytes,
        []
      )

    assert sql =~ "prefix(selecto_root.org_key, ?)"
    assert sql =~ "encode(selecto_root.org_key) <= encode(CAST(? AS VARCHAR))"

    assert %Selecto.Builder.ScopeRefusal{reason: :identity_pattern} =
             catch_error(compile(domain([{"org_key", {:like, "t1%"}}]), bytes, []))
  end

  test "a scope refusal is a typed error" do
    error = Selecto.Error.from_reason(%Selecto.Builder.ScopeRefusal{message: "m", reason: :r})

    assert %Selecto.Error{
             type: :query_enforcement,
             details: %{code: :query_rule_not_evaluable, reason: :r}
           } = error
  end

  test "epochs are exact, read as UTC" do
    assert ExactCompare.epoch("2024-01-01 00:00:00") == {:ok, 1_704_067_200}
    assert ExactCompare.epoch(~U[2024-01-01 00:00:00.5Z]) == {:ok, Decimal.new("1704067200.5")}
    assert ExactCompare.epoch(~N[2024-01-01 00:00:00]) == {:ok, 1_704_067_200}
    assert ExactCompare.epoch(~D[2024-01-01]) == {:ok, 1_704_067_200}
    assert ExactCompare.epoch("2024-01-01T05:00:00+05:00") == {:ok, 1_704_067_200}
    assert ExactCompare.epoch("not a time") == :error
    assert ExactCompare.epoch(1.5) == :error
  end

  test "VARCHAR identity comparisons compare bytes when the adapter asks for it" do
    bytes = %{
      storage_column_types: Map.delete(@timestamps.storage_column_types, "ts"),
      identity_text_bytes: true
    }

    {sql, _params} =
      compile(
        domain([{"org_key", {:gte, "t1"}}], %{name: "S1"}),
        bytes,
        [{"note", {:gte, "a"}}]
      )

    assert sql =~ "encode(selecto_root.org_key) >= encode(CAST(? AS VARCHAR))"
    assert sql =~ "encode(selecto_root.org_key) = encode(CAST(? AS VARCHAR))"
    assert sql =~ ~s|encode(site."name") = encode(CAST(? AS VARCHAR))|
    # A caller range on a non-identity column keeps the backend's collation.
    assert sql =~ "selecto_root.note >= ?"
  end
end
