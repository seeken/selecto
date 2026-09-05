defmodule Selecto.DocumentQueryPlanTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.Fixtures
  alias Selecto.Query.{CapabilityProfile, Cursor, Plan, Result, Runtime}
  @secret String.duplicate("x", 32)

  defmodule IncompleteAdapter do
    def contract_version, do: 1
  end

  defmodule RaisingAdapter do
    def contract_version, do: 1
    def capabilities(_, _), do: raise("sensitive connection details")
    def compile_query(_, _, _), do: :unused
    def execute_query(_, _, _), do: :unused
    def preview_query(_, _, _), do: :unused
  end

  test "only approved releases and host tenant scope yield plans" do
    assert {:error, _} =
             Plan.new(Fixtures.shape(), "work_orders", %{},
               trusted_context: %{tenant_id: "tenant-a"}
             )

    assert {:error, _} = Plan.new(Fixtures.release(), "work_orders")
    assert {:ok, plan} = query(%{"select" => ["id", "due_at"]})
    assert plan.tenant == "tenant-a"
    assert plan.ordering |> hd() |> get_in(["field", "id"]) == "id"
    assert :ok = Plan.validate(plan)
    assert Jason.decode!(Jason.encode!(plan))["version"] == 1

    assert {:error, _} =
             Plan.validate(%{plan | source: Map.put(plan.source, "collection", "private")})

    assert {:error, _} = Plan.validate(%{plan | required_capabilities: []})
    assert {:error, _} = Plan.validate(%{plan | projection: []})
    assert {:error, _} = Plan.validate(%{plan | tenant: "tenant-b"})
    assert {:error, _} = Plan.validate(%{plan | page: Map.put(plan.page, "after", ["wo-1"])})
  end

  test "raw native paths, operators, ambiguous comparisons and unbounded queries fail closed" do
    bad = [
      %{"pipeline" => []},
      %{"tenant_id" => "tenant-b"},
      %{"select" => ["schedule.due_at"]},
      %{"select" => ["id", "id"]},
      %{"limit" => 0},
      %{"limit" => 1001},
      %{"bounds" => %{"max_rows" => 1001}},
      %{"where" => %{"op" => "$where", "field" => "title", "value" => "return true"}},
      %{"where" => %{"op" => "eq", "field" => "due_at", "value" => nil}},
      %{"where" => %{"op" => "eq", "field" => "title", "value" => %{"$ne" => nil}}},
      %{"where" => %{"op" => "eq", "field" => "source_payload", "value" => "x"}},
      %{"order_by" => [%{"field" => "priority", "direction" => "asc"}]},
      %{"where" => %{"op" => "and", "args" => [nil]}}
    ]

    for input <- bad, do: assert(match?({:error, _}, query(input)), inspect(input))

    for op <- ~w(exists missing is_null is_not_null),
        do: assert(match?({:ok, _}, query(%{"where" => %{"op" => op, "field" => "due_at"}})))
  end

  test "child identity is scoped to one parent and cannot use global ordinality" do
    assert {:error, _} =
             Plan.new(Fixtures.release(), "work_order_parts", %{},
               trusted_context: %{tenant_id: "tenant-a"}
             )

    assert {:ok, plan} =
             Plan.new(Fixtures.release(), "work_order_parts", %{"parent_identity" => "wo-1"},
               trusted_context: %{tenant_id: "tenant-a"}
             )

    assert plan.relation["parent_identity"] == "wo-1"
    assert :ok = Plan.validate(plan)
  end

  test "signed cursors bind tenant, predicates, release, parent and expiration" do
    {:ok, plan} = query(%{"limit" => 1})
    assert {:error, _} = Cursor.encode(plan, ["wo-1"])
    assert {:ok, token} = Cursor.encode(plan, ["wo-1"], cursor_secret: @secret, cursor_now: 1000)
    assert {:ok, ["wo-1"]} = Cursor.decode(plan, token, cursor_secret: @secret, cursor_now: 1001)

    assert {:error, _} =
             Cursor.decode(plan, token <> "x", cursor_secret: @secret, cursor_now: 1001)

    assert {:error, _} = Cursor.decode(plan, token, cursor_secret: @secret, cursor_now: 2000)

    assert {:error, _} =
             Cursor.decode(%{plan | tenant: "tenant-b"}, token,
               cursor_secret: @secret,
               cursor_now: 1001
             )

    {:ok, filtered} = query(%{"where" => %{"op" => "eq", "field" => "state", "value" => "open"}})
    assert {:error, _} = Cursor.decode(filtered, token, cursor_secret: @secret, cursor_now: 1001)
    assert {:error, _} = Cursor.encode(plan, [nil], cursor_secret: @secret)
    assert {:ok, current} = Cursor.encode(plan, ["wo-1"], cursor_secret: @secret)

    assert {:ok, next} =
             Plan.new(Fixtures.release(), "work_orders", %{"limit" => 1, "cursor" => current},
               trusted_context: %{tenant_id: "tenant-a"},
               cursor_secret: @secret
             )

    assert :ok = Plan.validate(next, cursor_secret: @secret)
    assert {:error, _} = Plan.validate(next)

    assert {:error, _} =
             Plan.validate(%{next | page: Map.put(next.page, "after", ["wo-2"])},
               cursor_secret: @secret
             )
  end

  test "capability preflight requires enabled AND certified support and exact bounds" do
    {:ok, plan} = query(%{})

    profile = %CapabilityProfile{
      version: "test-v1",
      enabled: plan.required_capabilities,
      certified: plan.required_capabilities,
      limits: plan.bounds
    }

    assert :ok = CapabilityProfile.preflight(profile, plan)
    assert {:error, _} = CapabilityProfile.preflight(%{profile | enabled: []}, plan)
    assert {:error, _} = CapabilityProfile.preflight(%{profile | certified: []}, plan)
    assert {:error, _} = CapabilityProfile.preflight(%{profile | limits: %{}}, plan)
    assert {:error, _} = CapabilityProfile.preflight(%{profile | limits: nil}, plan)
    assert {:error, _} = Runtime.compile(plan, String, :no_connection)
    assert {:error, _} = Runtime.compile(plan, IncompleteAdapter, :no_connection)
    assert {:error, error} = Runtime.compile(plan, RaisingAdapter, :no_connection)
    refute inspect(error) =~ "sensitive connection details"
  end

  test "normalized result retains existing row/column consumer shape" do
    {:ok, plan} = query(%{"select" => ["id"]})
    result = %Result{rows: [["wo-1"]], columns: ["id"]}
    assert Result.to_raw(result) == {[["wo-1"]], ["id"], ["id"]}
    assert Result.to_maps(result) == [%{"id" => "wo-1"}]
    assert :ok = Result.validate(result, plan)
    assert {:error, _} = Result.validate(%{result | columns: ["secret"]}, plan)
  end

  test "existing map and JSON exports preserve document missing separately from null" do
    result = %Result{columns: ["due_at"], rows: [[nil], [%Selecto.Document.Missing{}]]}
    raw = Result.to_raw(result)

    assert {:ok, [%{"due_at" => nil}, %{"due_at" => %Selecto.Document.Missing{}}]} =
             Selecto.Output.Formats.transform(raw, :maps)

    assert {:ok, json} = Selecto.Output.Formats.transform(raw, :json)
    assert Jason.decode!(json) == [%{"due_at" => nil}, %{"due_at" => %{"$selecto" => "missing"}}]
  end

  defp query(input),
    do:
      Selecto.to_plan(Fixtures.release(), "work_orders", input,
        trusted_context: %{tenant_id: "tenant-a"}
      )
end
