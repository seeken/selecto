defmodule SelectoUpdato.NativeBroadWriteTest do
  use ExUnit.Case, async: false
  alias SelectoUpdato.NativeBroadWriteFixture, as: Fixture

  setup do
    uri = URI.parse(System.fetch_env!("SELECTO_BROAD_WRITE_DATABASE_URL"))

    unless uri.host in ["127.0.0.1", "localhost"] and uri.port != 5432 and
             String.starts_with?(uri.path || "", "/selecto_adv_"),
           do: raise("Broad-write tests need a disposable task-owned database")

    options = [
      hostname: uri.host,
      port: uri.port,
      username: uri.userinfo,
      database: String.trim_leading(uri.path, "/"),
      pool_size: 1
    ]

    connection = start_supervised!({Postgrex, options})

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(options)
      Fixture.cleanup(cleanup)
      GenServer.stop(cleanup)
    end)

    %{connection: connection, inputs: Fixture.load()}
  end

  for id <- ~w(ABW001 ABW002 ABW003) do
    test "native public broad write #{id} retains exact count and full scoped state", context do
      id = unquote(id)

      observations =
        for variant <- Fixture.variants(context.inputs) do
          Fixture.reset(context.connection, variant["dataset"])
          assert Fixture.state(context.connection) == input_state(variant["dataset"])

          for probe <- context.inputs["cases"][id] do
            before_state = Fixture.state(context.connection)
            source = Fixture.source(context.connection, context.inputs, probe["domain"])
            result = SelectoApi.EngineWriteHandler.execute(source, probe["intent"])

            if probe["id"] in rejected_ids() do
              code =
                if probe["id"] in ~w(missing-filter missing-filter-delete bulk-disabled bulk-missing),
                  do: "invalid_api_write",
                  else: "cardinality_mismatch"

              assert {:error, %{status: 422, body: %{"error" => %{"code" => ^code}}}} = result
              assert Fixture.state(context.connection) == before_state
            else
              count = probe["intent"]["expected_count"]
              assert {:ok, %{"affected_rows" => ^count}} = result

              assert Fixture.state(context.connection) ==
                       apply_effect(before_state, probe["intent"])
            end

            encoded = Jason.encode!(elem(result, 1))
            refute encoded =~ "selecto_cert_adv"
            refute encoded =~ "SQLSTATE"
            refute encoded =~ "ssn-secret"
            result
          end
        end

      assert length(Enum.uniq(observations)) == 1
    end
  end

  test "late SDK batch refusal occurs after actual native RETURNING and rolls back prior writes",
       context do
    observations =
      for variant <- Fixture.variants(context.inputs) do
        Fixture.reset(context.connection, variant["dataset"])
        assert Fixture.state(context.connection) == input_state(variant["dataset"])
        source = Fixture.source(context.connection, context.inputs)

        for probe <- context.inputs["cases"]["ABW004"] do
          before_state = Fixture.state(context.connection)

          {result, native_returns} =
            native_trace(fn ->
              SelectoUpdato.run(Fixture.batch(source, probe), source, context: %{tenant_id: 7})
            end)

          first = hd(probe["intent"]["commands"])

          assert Enum.any?(native_returns, fn
                   {:ok,
                    %{command: :update, num_rows: 1, columns: ["id", "name"], rows: [[1, value]]}} ->
                     value == first["assignments"]["name"]

                   _ ->
                     false
                 end)

          if probe["id"] in ~w(last-foreign-after-returning last-count-after-returning) do
            assert {:error, %SelectoUpdato.Error{type: :cardinality_mismatch}} = result
            assert Fixture.state(context.connection) == before_state
            %{outcome: :rejected, code: :cardinality_mismatch}
          else
            assert {:ok,
                    %{
                      first: %{affected_rows: 1, rows: [%{"id" => 1}]},
                      second: %{affected_rows: 1, rows: [%{"id" => 2}]}
                    }} = result

            expected =
              Enum.reduce(probe["intent"]["commands"], before_state, &apply_effect(&2, &1))

            assert Fixture.state(context.connection) == expected
            %{outcome: :applied, affected_rows: 2}
          end
        end
      end

    assert length(Enum.uniq(observations)) == 1
  end

  defp native_trace(fun) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            result = fun.()
            send(parent, {:native_result, self(), result})

            receive do
              :stop -> :ok
            end
        end
      end)

    :erlang.trace_pattern({Postgrex, :query, 4}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    try do
      send(worker, :run)

      result =
        receive do
          {:native_result, ^worker, result} ->
            result

          {:DOWN, ^monitor, :process, ^worker, _reason} ->
            raise "Native SDK batch worker failed before returning"
        after
          10_000 -> raise "Native SDK batch did not return"
        end

      marker = :erlang.trace_delivered(worker)

      receive do
        {:trace_delivered, ^worker, ^marker} -> :ok
      after
        5_000 -> raise "Native driver trace was not delivered"
      end

      {result, collect_returns(worker, [])}
    after
      if Process.alive?(worker), do: :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Postgrex, :query, 4}, false, [:local])
      Process.demonitor(monitor, [:flush])
      Process.exit(worker, :kill)
    end
  end

  defp collect_returns(worker, values) do
    receive do
      {:trace, ^worker, :return_from, {Postgrex, :query, 4}, result} ->
        collect_returns(worker, values ++ [result])

      {:trace, ^worker, :call, _} ->
        collect_returns(worker, values)
    after
      0 -> values
    end
  end

  defp rejected_ids,
    do:
      ~w(missing-filter mixed-in-wrong-count too-many-expected too-few-expected missing-filter-delete broad-delete-wrong-count mixed-delete-wrong-count bulk-disabled bulk-missing)

  defp input_state(dataset),
    do: Map.new(dataset, fn {table, data} -> {table, Enum.sort(data["rows"])} end)

  defp apply_effect(state, intent) do
    rows =
      Enum.flat_map(state["people"], fn row ->
        if Enum.at(row, 1) == 7 and matches?(row, intent["filters"]) do
          if intent["operation"] == "delete",
            do: [],
            else: [List.replace_at(row, 2, intent["assignments"]["name"])]
        else
          [row]
        end
      end)

    Map.put(state, "people", rows)
  end

  defp matches?(row, filters),
    do:
      Enum.all?(filters, fn
        %{"op" => "eq", "value" => id} -> hd(row) == id
        %{"op" => "in", "value" => ids} -> hd(row) in ids
        %{"op" => "gte", "value" => id} -> hd(row) >= id
        %{"op" => "not_null"} -> hd(row) != nil
      end)
end
