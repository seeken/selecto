defmodule Selecto.DocumentAggregatePlanTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Query.{CapabilityProfile, Cursor, Plan, Result}

  @maximum 9_007_199_254_740_991
  @aggregates [
    %{"op" => "count", "as" => "total"},
    %{"op" => "sum", "as" => "priority_sum", "field" => "priority"},
    %{"op" => "min", "as" => "priority_min", "field" => "priority"},
    %{"op" => "max", "as" => "priority_max", "field" => "priority"}
  ]

  test "approved aggregate grants create typed one-row intent without changing the row contract" do
    assert {:ok, plan} = query(%{"aggregate" => @aggregates})
    assert :ok = Plan.validate(plan)
    assert plan.bounds["max_input_rows"] == 1000
    assert plan.page == %{"limit" => 1, "after" => nil}
    assert plan.ordering == []
    assert plan.aggregates |> hd() |> Map.fetch!("field") == nil
    assert plan.projection == Enum.map(plan.aggregates, &Map.take(&1, ~w(id type nullable)))

    assert plan.required_capabilities == [
             "document.root",
             "query.aggregate.count",
             "query.aggregate.max",
             "query.aggregate.min",
             "query.aggregate.sum"
           ]

    assert Jason.decode!(Jason.encode!(plan))["aggregates"] == plan.aggregates
    assert {:ok, row_plan} = Plan.new(Fixtures.release(), "work_orders", %{}, context())
    assert row_plan.aggregates == []
    refute Map.has_key?(row_plan.bounds, "max_input_rows")
    refute Map.has_key?(Fixtures.shape()["relations"]["work_orders"], "aggregate_ops")

    for tampered <- [
          %{plan | aggregates: []},
          %{plan | aggregates: Enum.reverse(plan.aggregates)},
          %{plan | required_capabilities: ["document.root"]},
          %{plan | bounds: Map.put(plan.bounds, "max_input_rows", 10_000)},
          %{plan | projection: []}
        ],
        do: assert({:error, _} = Plan.validate(tampered))
  end

  test "old releases cannot implicitly grant aggregation and grants reject unsupported types" do
    for aggregate <- @aggregates do
      assert {:error, _} =
               Plan.new(
                 Fixtures.release(),
                 "work_orders",
                 %{"aggregate" => [aggregate]},
                 context()
               )
    end

    for malformed <- [
          put_in(Fixtures.shape(), ["relations", "work_orders", "aggregate_ops"], ["sum"]),
          put_in(Fixtures.shape(), ["relations", "work_orders", "aggregate_ops"], [
            "count",
            "count"
          ]),
          put_in(Fixtures.shape(), ["relations", "work_order_parts", "aggregate_ops"], ["count"]),
          put_in(Fixtures.shape(), ["shape", "fields", "priority", "aggregate_ops"], ["avg"]),
          put_in(Fixtures.shape(), ["shape", "fields", "priority", "aggregate_ops"], [
            "sum",
            "sum"
          ]),
          put_in(Fixtures.shape(), ["shape", "fields", "title", "aggregate_ops"], ["min"]),
          put_in(Fixtures.shape(), ["shape", "fields", "priority", "aggregate_ops"], true)
        ],
        do: assert({:error, _} = ShapeRelease.new(malformed))

    assert {:error, _} =
             query(%{"aggregate" => [%{"op" => "min", "as" => "first", "field" => "version"}]})

    assert {:error, _} =
             Plan.new(
               Fixtures.aggregate_release(),
               "work_order_parts",
               %{
                 "aggregate" => [%{"op" => "count", "as" => "total"}],
                 "parent_identity" => "wo-1"
               },
               context()
             )
  end

  test "aggregate syntax rejects native operators, paths, duplicate aliases and pagination" do
    for aggregate <- [
          [],
          nil,
          %{},
          List.duplicate(hd(@aggregates), 17),
          [%{"op" => "count", "as" => "total", "field" => "priority"}],
          [%{"op" => "sum", "as" => "total"}],
          [%{"op" => "$sum", "as" => "total", "field" => "priority"}],
          [%{"op" => "min", "as" => "total", "field" => "schedule.due_at"}],
          [%{"op" => "count", "as" => "$where"}],
          [%{"op" => "count", "as" => "nested.total"}],
          [%{"op" => "count", "as" => "total", "native" => %{}}],
          [%{op: "count", as: "total"}],
          [hd(@aggregates), hd(@aggregates)]
        ],
        do: assert({:error, _} = query(%{"aggregate" => aggregate}))

    for {key, value} <- [{"select", []}, {"order_by", []}, {"limit", 1}, {"cursor", nil}] do
      assert {:error, _} = query(%{"aggregate" => @aggregates, key => value})
    end

    assert {:ok, plan} = query(%{"aggregate" => @aggregates})
    assert {:error, _} = Cursor.encode(plan, [], cursor_secret: String.duplicate("x", 32))
    assert {:error, _} = Plan.cursor_values(plan, [])
  end

  test "aggregate-only input bounds and capabilities fail closed" do
    for bound <- [0, -1, 10_001, 1.0, "100"] do
      assert {:error, _} =
               query(%{"aggregate" => @aggregates, "bounds" => %{"max_input_rows" => bound}})
    end

    assert {:error, _} = query(%{"bounds" => %{"max_input_rows" => 100}})

    assert {:ok, plan} =
             query(%{"aggregate" => @aggregates, "bounds" => %{"max_input_rows" => 10}})

    profile = %CapabilityProfile{
      version: "aggregate-contract-test",
      enabled: plan.required_capabilities,
      certified: plan.required_capabilities,
      limits: plan.bounds
    }

    assert :ok = CapabilityProfile.preflight(profile, plan)

    assert {:error, _} =
             CapabilityProfile.preflight(
               %{profile | limits: Map.delete(plan.bounds, "max_input_rows")},
               plan
             )

    assert {:error, _} =
             CapabilityProfile.preflight(%{profile | certified: ["document.root"]}, plan)
  end

  test "integer input limits guarantee exact sums for either sign and exclude missing and null" do
    for bound <- [1, 2, 3, 1000, 10_000] do
      {:ok, plan} = query(%{"aggregate" => @aggregates, "bounds" => %{"max_input_rows" => bound}})

      for aggregate <- tl(plan.aggregates) do
        limit = Plan.aggregate_input_limit(plan, aggregate)
        assert limit == if(aggregate["op"] == "sum", do: div(@maximum, bound), else: @maximum)

        for accepted <- [-limit, -1, 0, 1, limit, nil, %Missing{}],
            do: assert(Plan.aggregate_input?(plan, aggregate, accepted))

        for rejected <- [-limit - 1, limit + 1, 1.0, "1", true, [], %{}],
            do: refute(Plan.aggregate_input?(plan, aggregate, rejected))

        if aggregate["op"] == "sum" do
          assert limit * bound <= @maximum
          assert -(limit * bound) >= -@maximum
        end
      end
    end
  end

  test "aggregate results preserve map exports and reject invalid types, counts and cursors" do
    {:ok, plan} = query(%{"aggregate" => @aggregates})
    columns = Enum.map(plan.projection, & &1["id"])
    result = %Result{rows: [[2, 2, 2, 2]], columns: columns}
    assert :ok = Result.validate(result, plan)

    assert Result.to_maps(result) == [
             %{"total" => 2, "priority_sum" => 2, "priority_min" => 2, "priority_max" => 2}
           ]

    assert :ok = Result.validate(%{result | rows: [[0, nil, nil, nil]]}, plan)
    assert :ok = Result.validate(%{result | rows: [[2, nil, nil, nil]]}, plan)

    for invalid <- [
          %{result | rows: []},
          %{result | rows: result.rows ++ result.rows},
          %{result | rows: [[-1, 2, 2, 2]]},
          %{result | rows: [[1001, 2, 2, 2]]},
          %{result | rows: [[nil, 2, 2, 2]]},
          %{result | rows: [[2, 2.0, 2, 2]]},
          %{result | rows: [[2, @maximum + 1, 2, 2]]},
          %{result | rows: [[2, %Missing{}, 2, 2]]},
          %{result | rows: [[2, 2, 2]]},
          %{result | next_cursor: "unexpected"}
        ],
        do: assert({:error, _} = Result.validate(invalid, plan))
  end

  test "nested aggregate fields and typed predicates preserve independent capability requirements" do
    shape =
      Fixtures.aggregate_shape()
      |> put_in(["shape", "fields", "priority", "path"], ["labor", "minutes"])

    {:ok, release} = ShapeRelease.approve(shape, approved_by: "aggregate-test-author")

    assert {:ok, plan} =
             Plan.new(
               release,
               "work_orders",
               %{
                 "aggregate" => @aggregates,
                 "where" => %{"op" => "eq", "field" => "state", "value" => "open"}
               },
               context()
             )

    assert "document.nested" in plan.required_capabilities
    assert "predicate.eq" in plan.required_capabilities
    assert :ok = Plan.validate(plan)
    assert {:error, _} = Plan.new(release, "work_orders", %{"aggregate" => @aggregates})
  end

  defp query(input), do: Plan.new(Fixtures.aggregate_release(), "work_orders", input, context())
  defp context, do: [trusted_context: %{tenant_id: "tenant-a"}]
end
