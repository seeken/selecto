defmodule Selecto.GroupingSetsTest do
  use ExUnit.Case, async: true

  import Selecto.Expr, only: [cube: 1, grouping_sets: 1, rollup: 1]

  defmodule CubeAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(feature), do: feature in [:rollup, :cube, :grouping_sets]
    def placeholder(index), do: "$#{index}"
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def rollup_sql(clauses), do: ["rollup( ", clauses, " )"]

    def execute(_connection, sql, _params, _opts) do
      send(self(), {:executed, sql})
      {:ok, %{rows: [], columns: []}}
    end
  end

  defmodule RollupOnlyAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(feature), do: feature == :rollup
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: "`#{identifier}`"
    def rollup_sql(clauses), do: [clauses, " WITH ROLLUP"]

    def prepare_read(selecto, _connection) do
      send(self(), :catalog_read)
      {:ok, selecto}
    end

    def execute(_connection, sql, _params, _opts) do
      send(self(), {:executed, sql})
      {:ok, %{rows: [], columns: []}}
    end
  end

  defmodule RenderingAdapter do
    defdelegate connect(connection), to: CubeAdapter
    defdelegate supports?(feature), to: CubeAdapter
    defdelegate placeholder(index), to: CubeAdapter
    defdelegate quote_identifier(identifier), to: CubeAdapter

    def render_grouping_sets(selecto, _opts) do
      send(self(), {:rendered, selecto.set.group_by, selecto.set.order_by})
      {["SELECT 1"], ["one"], []}
    end
  end

  @domain %{
    name: "Sales",
    source: %{
      source_table: "sales",
      primary_key: :id,
      fields: [:id, :region, :channel, :tier, :amount],
      redact_fields: [],
      columns: %{
        id: %{type: :integer},
        region: %{type: :string},
        channel: %{type: :string},
        tier: %{type: :integer},
        amount: %{type: :integer}
      },
      associations: %{}
    },
    schemas: %{},
    joins: %{}
  }

  defp query(adapter \\ CubeAdapter) do
    Selecto.configure(@domain, :mock_connection, adapter: adapter)
  end

  defp measures(selecto, dimensions) do
    Selecto.select(
      selecto,
      dimensions ++
        [
          {:field, {:count, "*"}, "n"},
          {:field, {:sum, "amount"}, "total"},
          {:field, {:grouping, dimensions}, "marker"}
        ]
    )
  end

  describe "builders" do
    test "cube/1 and grouping_sets/1 build keyword specs for group_by/2" do
      assert cube(["region", "channel"]) == [cube: ["region", "channel"]]

      assert grouping_sets([["region"], ["channel"], []]) ==
               [grouping_sets: [["region"], ["channel"], []]]

      assert query() |> Selecto.group_by(cube(["region"])) |> then(& &1.set.group_by) ==
               [cube: ["region"]]
    end
  end

  describe "grouping_set_positions/1" do
    test "cube sets are most detailed first, first dimension most significant" do
      assert %{
               dimensions: ["region", "channel", "tier"],
               sets: [[0, 1, 2], [0, 1], [0, 2], [1, 2], [0], [1], [2], []]
             } =
               query()
               |> Selecto.group_by(cube(["region", "channel", "tier"]))
               |> Selecto.grouping_set_positions()
    end

    test "declared sets keep first-appearance dimensions and written order" do
      assert %{dimensions: ["channel", "region"], sets: [[0], [1, 0], []]} =
               query()
               |> Selecto.group_by(grouping_sets([["channel"], ["region", "channel"], []]))
               |> Selecto.grouping_set_positions()
    end

    test "rollup prefixes, plain grouping and no grouping" do
      assert %{dimensions: ["region", "channel"], sets: [[0, 1], [0], []]} =
               query()
               |> Selecto.group_by(rollup(["region", "channel"]))
               |> Selecto.grouping_set_positions()

      assert %{dimensions: ["region", "channel"], sets: [[0, 1]]} =
               query()
               |> Selecto.group_by(["region", "channel"])
               |> Selecto.grouping_set_positions()

      assert %{dimensions: [], sets: [[]]} = Selecto.grouping_set_positions(query())
    end

    test "a plain grouping before a rollup combines with every rollup set" do
      assert %{dimensions: ["tier", "region", "channel"], sets: [[0, 1, 2], [0, 1], [0]]} =
               query()
               |> Selecto.group_by(["tier"])
               |> Selecto.group_by(rollup(["region", "channel"]))
               |> Selecto.grouping_set_positions()
    end

    test "a field named by atom and by string is one dimension" do
      assert %{dimensions: [:region], sets: [[0], [0]]} =
               Selecto.GroupingSets.positions(grouping_sets: [[:region], ["region"]])
    end
  end

  describe "build-time limits" do
    test "a cube takes 1 to 8 distinct dimensions" do
      eight = ~w(region channel tier amount id a b c)
      assert %{sets: sets} = Selecto.GroupingSets.positions(cube: eight)
      assert length(sets) == 256

      assert_raise ArgumentError, ~r/1 to 8/, fn -> Selecto.group_by(query(), cube([])) end

      assert_raise ArgumentError, ~r/1 to 8/, fn ->
        Selecto.group_by(query(), cube(eight ++ ["d"]))
      end

      assert_raise ArgumentError, ~r/twice/, fn ->
        Selecto.group_by(query(), cube(["region", "region"]))
      end
    end

    test "grouping sets: 1 to 64, not only [], no repeats, no duplicates" do
      fields = ~w(region channel tier amount id)

      # the 64 non-empty subsets of six dimensions, minus one, plus []
      subsets =
        for mask <- 1..63 do
          for {field, bit} <- Enum.with_index(fields ++ ["g"]),
              Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0,
              do: field
        end

      assert :ok = Selecto.GroupingSets.validate_group_by!([], grouping_sets([[] | subsets]))

      assert_raise ArgumentError, ~r/1 to 64/, fn ->
        Selecto.GroupingSets.validate_group_by!([], grouping_sets([[], ["x"] | subsets]))
      end

      assert_raise ArgumentError, ~r/1 to 64/, fn ->
        Selecto.group_by(query(), grouping_sets([]))
      end

      assert_raise ArgumentError, ~r/at least one/, fn ->
        Selecto.group_by(query(), grouping_sets([[]]))
      end

      assert_raise ArgumentError, ~r/twice/, fn ->
        Selecto.group_by(query(), grouping_sets([["region", "region"]]))
      end

      assert_raise ArgumentError, ~r/distinct/, fn ->
        Selecto.group_by(query(), grouping_sets([["region", "channel"], ["channel", "region"]]))
      end
    end

    test "a cube or grouping sets must be the only grouping" do
      assert_raise ArgumentError, ~r/only grouping/, fn ->
        query() |> Selecto.group_by(["tier"]) |> Selecto.group_by(cube(["region"]))
      end

      assert_raise ArgumentError, ~r/only grouping/, fn ->
        query() |> Selecto.group_by(grouping_sets([["region"], []])) |> Selecto.group_by(["tier"])
      end
    end

    test "unknown dimensions refuse like any group_by field" do
      assert_raise ArgumentError, fn ->
        Selecto.group_by(query(), grouping_sets([["nope"], []]))
      end
    end
  end

  describe "native SQL" do
    test "CUBE and GROUPING SETS render with GROUPING()" do
      {sql, _aliases, []} =
        query()
        |> measures(["region", "channel"])
        |> Selecto.group_by(cube(["region", "channel"]))
        |> Selecto.gen_sql([])

      assert sql =~ ~r/group by\s+CUBE\(selecto_root\.region, selecto_root\.channel\)/i
      assert sql =~ ~r/grouping\(/i

      {sql, _aliases, []} =
        query()
        |> measures(["region", "channel"])
        |> Selecto.group_by(grouping_sets([["region"], ["channel", "region"], []]))
        |> Selecto.gen_sql([])

      assert sql =~
               ~r/GROUPING SETS \(\(selecto_root\.region\), \(selecto_root\.channel, selecto_root\.region\), \(\)\)/
    end

    test "orderings name selected outputs and compile to positions" do
      {sql, _aliases, []} =
        query()
        |> measures(["region", "channel"])
        |> Selecto.group_by(cube(["region", "channel"]))
        |> Selecto.order_by([
          {{:grouping, ["region", "channel"]}, :asc},
          {{:sum, "amount"}, :desc}
        ])
        |> Selecto.order_by({"region", :asc})
        |> Selecto.limit(4)
        |> Selecto.gen_sql([])

      assert sql =~ ~r/order by\s+5 asc, 4 desc, 1 asc/
    end

    test "an ordering matches a selected expression of another spelling or its position" do
      {sql, _aliases, []} =
        query()
        |> measures(["region"])
        |> Selecto.group_by(grouping_sets([["region"], []]))
        |> Selecto.order_by([{Selecto.Expr.sum("amount"), :desc}, {{:literal_position, 1}, :asc}])
        |> Selecto.gen_sql([])

      assert sql =~ ~r/order by\s+3 desc, 1 asc/
    end

    test "an ordering that names no selected output refuses before SQL" do
      selecto =
        query()
        |> measures(["region", "channel"])
        |> Selecto.group_by(cube(["region", "channel"]))
        |> Selecto.order_by({"id", :asc})

      assert_raise Selecto.Builder.ScopeRefusal, ~r/selected output/, fn ->
        Selecto.gen_sql(selecto, [])
      end

      assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
               Selecto.execute(selecto)

      assert details.reason == :ordering_not_selected
      refute_received {:executed, _}
    end

    test "a whole-query adapter lowering receives positional orderings" do
      query(RenderingAdapter)
      |> measures(["region"])
      |> Selecto.group_by(grouping_sets([["region"], []]))
      |> Selecto.order_by({{:sum, "amount"}, :desc})
      |> Selecto.gen_sql([])

      assert_received {:rendered, [grouping_sets: [["region"], []]],
                       [{{:literal_position, 3}, :desc}]}
    end
  end

  describe "adapters without the mode" do
    test "refuse with unsupported_feature before the catalog read or any SQL" do
      for {mode, groups} <- [
            cube: cube(["region"]),
            grouping_sets: grouping_sets([["region"], []])
          ] do
        selecto =
          query(RollupOnlyAdapter)
          |> measures(["region"])
          |> Selecto.group_by(groups)
          # the unselected ordering is not what refuses first
          |> Selecto.order_by({"id", :asc})

        assert {:error, %Selecto.Error{details: %{unsupported_feature: ^mode}}} =
                 Selecto.execute(selecto)

        refute_received :catalog_read
        refute_received {:executed, _}

        assert_raise Selecto.Builder.ScopeRefusal, fn -> Selecto.gen_sql(selecto, []) end
      end
    end

    test "rollup is unaffected" do
      {sql, _, _} =
        query(RollupOnlyAdapter)
        |> measures(["region"])
        |> Selecto.group_by(rollup(["region"]))
        |> Selecto.gen_sql([])

      assert sql =~ "WITH ROLLUP"
    end
  end
end
