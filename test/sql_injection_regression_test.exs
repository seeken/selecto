defmodule Selecto.SqlInjectionRegressionTest do
  use ExUnit.Case, async: true

  alias Selecto.Advanced.{JsonOperations, ValuesClause}
  alias Selecto.Builder.JsonOperations, as: JsonBuilder
  alias Selecto.Builder.ValuesClause, as: ValuesBuilder
  alias Selecto.Builder.Window
  alias Selecto.Json
  alias Selecto.Subfilter.FilterSpec
  alias Selecto.Subfilter.SQL.Safe
  alias Selecto.Window.{Frame, Spec}

  test "JSON paths, keys, containment values, and arrays stay inside literals" do
    attack = "x' OR TRUE --"

    assert Json.build_extraction("attributes", [attack], adapter: SelectoDBPostgreSQL.Adapter) ==
             ~s("attributes"->>'x'' OR TRUE --')

    assert Json.build_extraction("attributes", ["outer", attack],
             adapter: SelectoDBPostgreSQL.Adapter
           ) ==
             ~s("attributes"#>>ARRAY['outer', 'x'' OR TRUE --'])

    assert Json.build_key_exists("attributes", attack, adapter: SelectoDBPostgreSQL.Adapter) ==
             ~s("attributes" ? 'x'' OR TRUE --')

    assert Json.build_array_contains("attributes", ["tags"], attack,
             adapter: SelectoDBPostgreSQL.Adapter
           ) ==
             ~s("attributes"->'tags' ? 'x'' OR TRUE --')

    assert Json.build_contains("attributes", %{"owner" => "O'Reilly"},
             adapter: SelectoDBPostgreSQL.Adapter
           ) ==
             ~s("attributes" @> '{"owner":"O''Reilly"}'::jsonb)
  end

  test "JSON construction keys and VALUES aliases are encoded as data or identifiers" do
    json_spec =
      JsonOperations.create_json_operation(:json_build_object, nil,
        value: [{"x'); DROP TABLE users; --", "safe"}]
      )

    json_sql =
      json_spec
      |> JsonBuilder.build_json_select(adapter: SelectoDBPostgreSQL.Adapter)
      |> IO.iodata_to_binary()

    assert json_sql =~ "'x''); DROP TABLE users; --'"

    values_spec =
      ValuesClause.create_values_clause([["safe"]],
        columns: [~s(value"; DROP TABLE users; --)],
        as: ~s(v"; DROP TABLE users; --)
      )

    values_sql = values_spec |> ValuesBuilder.build_values_cte() |> IO.iodata_to_binary()
    assert values_sql =~ ~s("v""; DROP TABLE users; --")
    assert values_sql =~ ~s("value""; DROP TABLE users; --")
  end

  test "comparison operators are allowlisted and temporal intervals bind magnitudes" do
    assert {:error, %{type: :invalid_comparison_operator}} =
             Safe.comparison_operator(">= ANY (SELECT 1); DROP TABLE users; --")

    assert {:ok, "events.created_at > (CURRENT_DATE - (? * INTERVAL '1 day'))", [7]} =
             Safe.temporal_condition(
               %FilterSpec{type: :temporal, temporal_type: :within_days, value: 7},
               "events.created_at"
             )

    assert {:error, %{type: :invalid_temporal_value}} =
             Safe.temporal_condition(
               %FilterSpec{
                 type: :temporal,
                 temporal_type: :within_days,
                 value: "1 day'); DROP TABLE users; --"
               },
               "events.created_at"
             )
  end

  test "window interval frames reject interpolated SQL" do
    selecto = %Selecto{
      set: %{
        window_functions: [
          %Spec{
            function: :row_number,
            arguments: [],
            partition_by: [],
            order_by: [],
            frame: %Frame{
              type: :range,
              start: {:interval, "1 day' PRECEDING); DROP TABLE users; --"},
              end: :current_row
            }
          }
        ]
      }
    }

    assert_raise RuntimeError, ~r/Invalid window frame interval/, fn ->
      Window.build_window_functions(selecto)
    end
  end
end
