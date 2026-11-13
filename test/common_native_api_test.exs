defmodule SelectoUpdato.CommonNativeApiTest do
  use ExUnit.Case, async: false

  defmodule Adapter do
    def name, do: :common_api_test
    def connect(connection), do: {:ok, connection}
    def execute(_, _, _, _), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: "$#{index}"
    def quote_identifier(value), do: ~s("#{value}")
    def supports?(_), do: false

    def write_capabilities(_),
      do: %{
        protocol_version: 1,
        insert: true,
        update: true,
        delete: true,
        returning: true,
        transactions: true
      }

    def preview_write(_, command, _), do: {:ok, %{command: command}}

    def execute_write(_, command, _) do
      send(self(), {:write, command})
      {:ok, %Selecto.Write.Result{operation: command.operation, affected_rows: 1}}
    end
  end

  defp engine do
    Selecto.configure(domain(), :recording,
      adapter: Adapter,
      validate: false,
      rollup_sort_fix: false
    )
    |> Selecto.with_tenant(8)
  end

  defp domain do
    %{
      name: "Items",
      source: %{
        source_table: "items",
        primary_key: :id,
        tenant_field: :org_id,
        fields: [:id, :org_id, :site_id, :name, :state],
        associations: %{},
        columns: %{
          id: %{type: :integer},
          org_id: %{type: :integer},
          site_id: %{type: :integer},
          name: %{type: :string},
          state: %{type: :string}
        }
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true, returning: :all}},
        fields:
          Map.new(
            [:id, :org_id, :site_id, :name, :state],
            &{&1, %{insertable: true, updatable: true}}
          ),
        transitions: %{state: %{"done" => ["archived"]}}
      },
      capabilities: %{"items.archive" => %{operations: [:action, :update]}},
      actions: %{
        archive: %{
          type: :transition,
          capability: "items.archive",
          transition: %{field: :state, from: "done", to: "archived"},
          execution: %{kind: :updato, operation: :update, set: %{state: "archived"}}
        }
      }
    }
  end

  test "engine-bound operations retain domain context and materialize the custom tenant" do
    engine = engine()
    operation = engine |> Selecto.write() |> SelectoUpdato.insert(%{id: 1, name: "Test"})
    assert operation.engine == engine
    assert operation.domain == engine.domain
    assert {:ok, _} = SelectoUpdato.preview(operation)
    refute_receive {:write, _}
    assert {:ok, _} = SelectoUpdato.execute(operation)
    assert_receive {:write, command}
    assert %{field: "org_id", value: {:literal, 8}} in command.assignments
    assert command.relation == "items"
  end

  test "only required engine filters can establish independent host scope" do
    engine =
      engine()
      |> Selecto.require_tenant_filter("site_id", 42)
      |> Selecto.filter({"name", "Optional"})

    operation = Selecto.write(engine)
    assert operation.query_enforcement.filters == [{"site_id", 42}]
    assert operation.query_enforcement.host_scope
    refute {"name", "Optional"} in operation.query_enforcement.filters
  end

  test "actions preserve compound required host scope without promoting optional read filters" do
    required = {:and, [{"site_id", 42}, {"name", "Eligible"}]}
    domain = Map.put(domain(), :required_filters, [required])

    engine =
      Selecto.configure(domain, :recording,
        adapter: Adapter,
        validate: false,
        rollup_sort_fix: false
      )
      |> Selecto.with_tenant(8)
      |> Selecto.filter({"name", "Optional"})

    action = engine |> Selecto.action(:archive) |> SelectoUpdato.target(1)

    assert {:ok, _} =
             SelectoUpdato.execute(action, capability_resolver: fn _, _, _ -> :enabled end)

    assert_receive {:write, command}
    filters = inspect(command)
    assert filters =~ "Eligible"
    refute filters =~ "Optional"
  end

  test "action helper uses fresh native authorization and refuses conflicting context" do
    observer = self()

    policy = fn request, _, _ ->
      send(observer, {:phase, request.phase})
      :enabled
    end

    action =
      engine() |> Selecto.action(:archive) |> SelectoUpdato.target(1) |> SelectoUpdato.inputs(%{})

    assert {:ok, _} = SelectoUpdato.preview(action, capability_resolver: policy)
    assert_receive {:phase, :preview}
    refute_receive {:write, _}
    assert {:ok, _} = SelectoUpdato.execute(action, capability_resolver: policy)
    assert_receive {:phase, :execute}
    assert_receive {:write, _}
    assert {:error, _} = SelectoUpdato.execute(action)

    assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} =
             SelectoUpdato.execute(action, context: %{tenant_id: 9}, capability_resolver: policy)

    refute_receive {:write, _}
  end
end
