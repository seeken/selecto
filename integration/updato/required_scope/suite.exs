defmodule SelectoUpdato.NativeRequiredScopeTest do
  use ExUnit.Case, async: false
  alias SelectoUpdato.NativeRequiredScopeFixture, as: Fixture

  defmodule NativeActionExecutor do
    @behaviour SelectoUpdato.ActionExecutionAdapter
    def execute_action(plan, context, _opts) do
      plan.operation_builder
      |> SelectoUpdato.with_tenant(%{tenant_id: context.tenant_id})
      |> SelectoUpdato.execute(context.execution_target, context: context)
    end
  end

  setup do
    url = System.fetch_env!("SELECTO_REQUIRED_SCOPE_DATABASE_URL")
    uri = URI.parse(url)

    unless uri.host in ["localhost", "127.0.0.1"] and uri.port != 5432 and
             String.starts_with?(uri.path || "", "/selecto_adv_"),
           do: raise("Required-scope tests need a disposable task-owned database")

    connection =
      start_supervised!(
        {Postgrex,
         hostname: uri.host,
         port: uri.port,
         username: uri.userinfo,
         database: String.trim_leading(uri.path, "/"),
         pool_size: 1}
      )

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(
          hostname: uri.host,
          port: uri.port,
          username: uri.userinfo,
          database: String.trim_leading(uri.path, "/")
        )

      Fixture.cleanup(cleanup)
      GenServer.stop(cleanup)
    end)

    %{connection: connection, inputs: Fixture.load()}
  end

  test "TW-07 native graph roots conjoin owner, host field and tenant scope", context do
    observations =
      for variant <- Fixture.variants(context.inputs) do
        Fixture.reset(context.connection, variant["dataset"])
        assert_role_isolation(variant["dataset"])
        initial = Fixture.state(context.connection)
        assert initial == input_state(variant["dataset"])
        source = Fixture.source(context.connection, context.inputs)

        public =
          for probe <- context.inputs["cases"]["ARS001"] do
            before_state = Fixture.state(context.connection)
            result = SelectoUpdato.execute(Fixture.operation(source, probe), source)

            if probe["id"] == "inside_control" do
              assert {:ok, %{affected_rows: 2}} = result
              assert Fixture.state(context.connection) == graph_effect(before_state)
            else
              assert {:error, %SelectoUpdato.Error{type: :cardinality_mismatch}} = result
              assert Fixture.state(context.connection) == before_state
            end

            public_result(result)
          end

        assert Fixture.state(context.connection) == graph_effect(initial)
        public
      end

    assert Enum.uniq(observations) |> length() == 1
  end

  test "TW-07 scoped action plans retain host rules before grants and atomic bulk execution",
       context do
    observations =
      for variant <- Fixture.variants(context.inputs) do
        Fixture.reset(context.connection, variant["dataset"])
        assert_role_isolation(variant["dataset"])
        initial = Fixture.state(context.connection)
        assert initial == input_state(variant["dataset"])
        source = Fixture.source(context.connection, context.inputs)

        public =
          for probe <- context.inputs["cases"]["ARS002"] do
            before_state = Fixture.state(context.connection)
            assert {:ok, plan} = SelectoUpdato.plan_domain_action(source, probe["intent"])

            result =
              SelectoUpdato.ActionExecutionAdapter.execute(NativeActionExecutor, plan, %{
                tenant_id: 7,
                actor: %{id: 42},
                execution_target: source
              })

            ids =
              case probe["id"] do
                "inside_control" -> [1]
                "inside_bulk" -> [1, 2]
                _ -> []
              end

            if ids == [] do
              assert {:error, %SelectoUpdato.Error{type: :cardinality_mismatch}} = result
              assert Fixture.state(context.connection) == before_state
            else
              assert {:ok, %{affected_rows: count}} = result
              assert count == length(ids)
              assert Fixture.state(context.connection) == action_effect(before_state, ids)
            end

            public_result(result)
          end

        assert Fixture.state(context.connection) == action_effect(initial, [1, 2])
        public
      end

    assert Enum.uniq(observations) |> length() == 1
  end

  test "TW-07 actual API root write handler applies the same required guards", context do
    observations =
      for variant <- Fixture.variants(context.inputs) do
        Fixture.reset(context.connection, variant["dataset"])
        assert_role_isolation(variant["dataset"])
        initial = Fixture.state(context.connection)
        assert initial == input_state(variant["dataset"])
        source = Fixture.source(context.connection, context.inputs)

        public =
          for probe <- context.inputs["cases"]["ARS002"] do
            target = probe["intent"]["target"]
            ids = target["ids"] || [target["id"]]

            body = %{
              "operation" => "update",
              "assignments" => %{"name" => "required-action-renamed"},
              "filters" => [%{"field" => "id", "op" => "in", "value" => ids}],
              "expected_count" => length(ids)
            }

            before_state = Fixture.state(context.connection)
            result = SelectoApi.EngineWriteHandler.execute(source, body)

            if probe["id"] in ["inside_control", "inside_bulk"] do
              assert {:ok, %{"affected_rows" => count}} = result
              assert count == length(ids)
              assert Fixture.state(context.connection) == action_effect(before_state, ids)
            else
              assert {:error,
                      %{status: 422, body: %{"error" => %{"code" => "cardinality_mismatch"}}}} =
                       result

              assert Fixture.state(context.connection) == before_state
            end

            encoded = Jason.encode!(elem(result, 1))

            for private <- [
                  "selecto_cert_required",
                  "SQLSTATE",
                  "stacktrace",
                  "ssn-secret",
                  "replaced-",
                  "changed-foreign-ssn"
                ] do
              refute encoded =~ private
            end

            result
          end

        assert Fixture.state(context.connection) == action_effect(initial, [1, 2])
        public
      end

    assert Enum.uniq(observations) |> length() == 1
  end

  defp assert_role_isolation(dataset) do
    people = Map.new(dataset["people"]["rows"], &{hd(&1), &1})
    assert Enum.at(people[3], 1) == 7
    assert Enum.at(people[3], 5) < 25
    assert Enum.at(people[3], 6) != 42
    assert Enum.at(people[4], 1) == 7
    assert Enum.at(people[4], 5) >= 25
    assert Enum.at(people[4], 6) == 42
    assert Enum.at(people[8], 1) == 8
    assert Enum.at(people[8], 5) < 25
    assert Enum.at(people[8], 6) == 42
  end

  defp input_state(dataset),
    do: Map.new(dataset, fn {table, data} -> {table, Enum.sort(data["rows"])} end)

  defp graph_effect(state) do
    state
    |> Map.update!("people", &rename(&1, [1], "required-graph-renamed"))
    |> Map.update!("orders", &Enum.sort(&1 ++ [[901, 7, 1, 17, "required-graph-child"]]))
  end

  defp action_effect(state, ids),
    do: Map.update!(state, "people", &rename(&1, ids, "required-action-renamed"))

  defp rename(rows, ids, name),
    do:
      Enum.map(rows, fn row -> if hd(row) in ids, do: List.replace_at(row, 2, name), else: row end)

  defp public_result({:ok, %{affected_rows: n}}), do: %{outcome: :applied, affected_rows: n}

  defp public_result({:error, %SelectoUpdato.Error{type: type}}),
    do: %{outcome: :rejected, code: type}
end
