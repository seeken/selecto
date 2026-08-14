defmodule Selecto.SQLFunctionsTest do
  use ExUnit.Case, async: true

  alias Selecto.SQL.Functions
  alias Selecto.TestSQLParams, as: Params

  @test_domain %{
    name: "SQL Functions Test Domain",
    source: %{
      source_table: "products",
      primary_key: :id,
      fields: [:id, :name, :description, :price, :category, :created_at, :tags],
      redact_fields: [],
      columns: %{
        id: %{type: :integer},
        name: %{type: :string},
        description: %{type: :string},
        price: %{type: :decimal},
        category: %{type: :string},
        created_at: %{type: :utc_datetime},
        tags: %{type: {:array, :string}}
      },
      associations: %{}
    },
    schemas: %{},
    default_selected: ["id", "name"],
    joins: %{},
    filters: %{}
  }

  setup do
    {:ok,
     selecto:
       Selecto.configure(@test_domain, :mock_connection, adapter: SelectoDBPostgreSQL.Adapter)}
  end

  defp render({iodata, _joins, params}) do
    {sql, finalized_params} = Params.finalize(iodata)
    {sql, finalized_params ++ params}
  end

  describe "string functions" do
    test "basic string functions compile", %{selecto: selecto} do
      for selector <- [
            {:substr, "description", 1, 50},
            {:trim, "name"},
            {:upper, "category"},
            {:lower, "category"},
            {:length, "name"}
          ] do
        assert {sql, _params} = selecto |> Functions.prep_advanced_selector(selector) |> render()
        assert is_binary(sql)
      end
    end

    test "replace emits params", %{selecto: selecto} do
      {sql, params} =
        selecto
        |> Functions.prep_advanced_selector(
          {:replace, "description", {:literal, "old"}, {:literal, "new"}}
        )
        |> render()

      assert sql =~ ~r/replace\(/i
      assert "old" in params
      assert "new" in params
    end
  end

  describe "math/date/array functions" do
    test "common math and date functions compile", %{selecto: selecto} do
      selectors = [
        {:abs, "price"},
        {:round, "price"},
        {:sqrt, "price"},
        {:random},
        {:now},
        {:date_trunc, {:literal, "month"}, "created_at"},
        {:array_agg, "category"},
        {:array_length, "tags"},
        {:unnest, "tags"}
      ]

      for selector <- selectors do
        assert {sql, _params} = selecto |> Functions.prep_advanced_selector(selector) |> render()
        assert is_binary(sql)
      end
    end

    test "parametrized functions emit params", %{selecto: selecto} do
      assert {_sql, power_params} =
               selecto
               |> Functions.prep_advanced_selector({:power, "price", {:literal, 2}})
               |> render()

      assert 2 in power_params

      assert {_sql, arr_params} =
               selecto
               |> Functions.prep_advanced_selector({:array_to_string, "tags", {:literal, ", "}})
               |> render()

      assert Enum.any?(arr_params, fn
               ", " -> true
               {:literal, ", "} -> true
               {:literal, value} when value == ", " -> true
               {key, value} when key == :literal and value == ", " -> true
               _ -> false
             end)
    end

    test "typed intervals render through the configured dialect", %{selecto: selecto} do
      assert {"interval '2 day'", []} =
               selecto
               |> Functions.prep_advanced_selector({:interval, {2, :days}})
               |> render()

      assert_raise ArgumentError, ~r/invalid_interval/, fn ->
        Functions.prep_advanced_selector(
          selecto,
          {:interval, "1 day' PRECEDING); DROP TABLE records; --"}
        )
      end
    end

    test "typed datetime parts reject SQL-shaped and unsupported values", %{selecto: selecto} do
      assert_raise ArgumentError, ~r/invalid datetime part/, fn ->
        Functions.prep_advanced_selector(
          selecto,
          {:date_trunc, {:literal, "month'); DROP TABLE records; --"}, "created_at"}
        )
      end

      assert_raise ArgumentError, ~r/invalid datetime part/, fn ->
        Functions.prep_advanced_selector(selecto, {:date_part, :fortnight, "created_at"})
      end
    end

    test "collection function shortcuts render through the adapter dialect", %{selecto: selecto} do
      cases = [
        {{:array_agg, "category", distinct: true, order_by: [{"name", :desc}]},
         ~r/ARRAY_AGG\(DISTINCT .* ORDER BY .* DESC\)/i},
        {{:string_agg, "name", ", ", distinct: true, order_by: ["name"]},
         ~r/STRING_AGG\(DISTINCT .* ORDER BY .* ASC\)/i},
        {{:array_length, "tags"}, ~r/ARRAY_LENGTH\(.*, 1\)/i},
        {{:cardinality, "tags"}, ~r/CARDINALITY\(/i},
        {{:array_ndims, "tags"}, ~r/ARRAY_NDIMS\(/i},
        {{:array_dims, "tags"}, ~r/ARRAY_DIMS\(/i},
        {{:array_append, "tags", "new"}, ~r/ARRAY_APPEND\(/i},
        {{:array_prepend, "new", "tags"}, ~r/ARRAY_PREPEND\(/i},
        {{:array_fill, "x", [2, 3]}, ~r/ARRAY_FILL\(/i},
        {{:array_remove, "tags", "old"}, ~r/ARRAY_REMOVE\(/i},
        {{:array_replace, "tags", "old", "new"}, ~r/ARRAY_REPLACE\(/i},
        {{:array_position, "tags", "needle", 2}, ~r/ARRAY_POSITION\(.*, .*, .*\)/i},
        {{:array_positions, "tags", "needle"}, ~r/ARRAY_POSITIONS\(/i},
        {{:array_to_string, "tags", ","}, ~r/ARRAY_TO_STRING\(/i},
        {{:string_to_array, "name", ","}, ~r/STRING_TO_ARRAY\(/i},
        {{:unnest, "tags"}, ~r/UNNEST\(/i}
      ]

      for {selector, expected} <- cases do
        {sql, _params} = selecto |> Functions.prep_advanced_selector(selector) |> render()
        assert sql =~ expected
      end

      {array_cat_sql, _params} =
        selecto
        |> Functions.prep_advanced_selector({:array_cat, "tags", "tags"})
        |> render()

      assert array_cat_sql =~ ~r/ARRAY_CAT\(.*tags.*, .*tags.*\)/i
    end

    test "JSON aggregate shortcuts render through the adapter dialect", %{selecto: selecto} do
      {json_agg_sql, _params} =
        selecto |> Functions.prep_advanced_selector({:json_agg, "name"}) |> render()

      assert json_agg_sql =~ ~r/JSON_AGG\(.*name.*\)/i

      {object_agg_sql, _params} =
        selecto
        |> Functions.prep_advanced_selector({:json_object_agg, "category", "name"})
        |> render()

      assert object_agg_sql =~ ~r/JSON_OBJECT_AGG\(.*category.*, .*name.*\)/i
    end

    test "unsupported collection shortcuts fail closed for the configured adapter", %{
      selecto: selecto
    } do
      sqlite = %{selecto | adapter: SelectoDBSQLite.Adapter}

      assert_raise RuntimeError, ~r/does not support this collection operation/, fn ->
        Functions.prep_advanced_selector(sqlite, {:array_append, "tags", "new"})
      end
    end
  end

  describe "window functions" do
    test "window functions compile", %{selecto: selecto} do
      selectors = [
        {:window, {:row_number}, over: []},
        {:window, {:rank}, over: [order_by: ["price"]]},
        {:window, {:lag, "price"}, over: [partition_by: ["category"]]},
        {:window, {:lead, "price", 2}, over: [partition_by: ["category"]]},
        {:window, {:ntile, 4}, over: [order_by: ["price"]]}
      ]

      for selector <- selectors do
        assert {sql, _params} = selecto |> Functions.prep_advanced_selector(selector) |> render()
        assert sql =~ ~r/over\s*\(/i
      end
    end
  end

  describe "conditional functions" do
    test "iif function emits branch params", %{selecto: selecto} do
      {sql, params} =
        selecto
        |> Functions.prep_advanced_selector({
          :iif,
          {"price", :gt, {:literal, 100}},
          {:literal, "expensive"},
          {:literal, "affordable"}
        })
        |> render()

      assert sql =~ ~r/case\s+when/i
      assert "expensive" in params
      assert "affordable" in params
    end

    test "decode function compiles", %{selecto: selecto} do
      mappings = [
        {{"category", :eq, {:literal, "electronics"}}, {:literal, "tech"}},
        {{"category", :eq, {:literal, "books"}}, {:literal, "literature"}}
      ]

      {sql, _params} =
        selecto
        |> Functions.prep_advanced_selector({:decode, "category", mappings})
        |> render()

      assert sql =~ ~r/decode\(/i
    end
  end

  test "unsupported selector returns nil", %{selecto: selecto} do
    assert Functions.prep_advanced_selector(selecto, {:unknown_function, "field"}) == nil
  end
end
