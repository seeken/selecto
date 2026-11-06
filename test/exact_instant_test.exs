defmodule Selecto.ExactInstantTest do
  use ExUnit.Case, async: true
  alias Selecto.Builder.Sql.Where

  defmodule Dialect do
    def render_instant_comparison(fragment, _query) do
      send(self(), {:instant_fragment, fragment})
      {:ok, [fragment.expression, " = CAST(", fragment.value, " AS NUMERIC)"]}
    end
  end

  defmodule Adapter do
    def connect(connection), do: {:ok, connection}
    def dialect, do: Dialect
    def placeholder(_), do: "?"
    def quote_identifier(name), do: ["\"", to_string(name), "\""]
    def supports?(_), do: false
  end

  defmodule EmptyDialect do
  end

  defmodule MissingAdapter do
    def dialect, do: EmptyDialect
  end

  defp query(storage \\ nil) do
    domain = %{
      name: "Exact instant unit",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :instant, :epoch, :civil, :secret],
        associations: %{},
        redact_fields: [:secret],
        columns: %{
          id: %{type: :integer},
          instant: %{type: :utc_datetime},
          epoch: %{type: :epoch_datetime},
          civil: %{type: :naive_datetime},
          secret: %{type: :utc_datetime, hidden: true}
        }
      },
      schemas: %{},
      joins: %{}
    }

    domain =
      if is_nil(storage),
        do: domain,
        else: put_in(domain, [:source, :columns, :instant, :storage], storage)

    Selecto.configure(domain, :unused, adapter: Adapter, validate: false)
  end

  test "governed field, exact bound value and finite operation reach the dialect unchanged" do
    for {field, type} <- [{"instant", :utc_datetime}, {"epoch", :epoch_datetime}] do
      predicate = Selecto.Expr.instant_compare(field, :lt, "-0.000000001")
      query = Selecto.filter(query(), predicate)
      {_joins, sql, _params} = Where.build(query, predicate)
      assert_received {:instant_fragment, fragment}
      assert fragment.operation == :lt and fragment.source_type == type
      assert fragment.value == {:param, "-0.000000001"}
      {text, parameters} = Selecto.SQL.Params.finalize(sql, adapter: Adapter)
      assert text =~ field
      refute text =~ "-0.000000001"
      assert parameters == ["-0.000000001"]
    end
  end

  test "manually constructed operands cannot bypass field-type and literal validation" do
    for {field, op, value} <- [
          {"id", :eq, "0"},
          {"civil", :eq, "0"},
          {"instant", :raw, "0"},
          {"instant", :eq, "0.0000000001"},
          {"instant", :eq, "0); SELECT 1"}
        ] do
      assert_raise ArgumentError, fn ->
        Where.build(query(), {field, {:instant_compare, op, value}})
      end
    end
  end

  test "ordinary query privacy still applies to an exact predicate" do
    assert_raise ArgumentError, "Field 'secret' not found", fn ->
      Selecto.filter(query(), Selecto.Expr.instant_compare("secret", :eq, "0"))
    end
  end

  test "an explicit physical UTC storage declaration reaches the exact renderer" do
    predicate = Selecto.Expr.instant_compare("instant", :eq, "0")
    Where.build(query("naive_utc"), predicate)
    assert_received {:instant_fragment, %{storage: :naive_utc}}
    assert_raise ArgumentError, fn -> Where.build(query("local"), predicate) end
  end

  test "unimplemented dialects return a structured unsupported result" do
    fragment = %Selecto.Dialect.Instant.Comparison{
      operation: :eq,
      expression: "instant",
      value: {:param, "0"},
      source_type: :utc_datetime
    }

    assert {:error, %Selecto.Error{details: %{unsupported_feature: :exact_instant_comparisons}}} =
             Selecto.DialectSupport.render_instant_comparison(
               MissingAdapter,
               fragment,
               query()
             )
  end
end
