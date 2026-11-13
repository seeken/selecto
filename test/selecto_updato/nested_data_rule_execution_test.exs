defmodule SelectoUpdato.NestedDataRuleExecutionTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.CompositionFixtures
  alias Selecto.Write.{CandidateRequest, CandidateState, Graph}
  alias SelectoUpdato.Error
  alias SelectoUpdato.CandidateState, as: CandidateStateHelper

  defmodule RecordingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :nested_data_rule_recording
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        atomic_batch: true,
        write_graph: true,
        committed_effect_sink: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write({pid, token}, %Graph{} = graph, _opts) do
      send(pid, {token, graph})
      {:ok, %Selecto.Write.Result{operation: :graph, affected_rows: 4}}
    end
  end

  defmodule PreparedRecordingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :prepared_nested_data_rule_recording
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        atomic_batch: true,
        write_graph: true,
        prepared_candidate_state: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}
    def execute_write(_connection, _command, _opts), do: raise("ordinary path must not run")

    def execute_prepared_write({pid, token}, prepare_fun, _opts) do
      # A conforming adapter spends the governed preparation's authorization.
      prepare_fun = Selecto.Write.Authorization.governed_preparation(prepare_fun)

      loader = fn
        %Selecto.Write.RecordRequest{} = request ->
          send(pid, {token, :record_request, request})

          {:ok,
           %Selecto.Write.RecordState{
             values: %{id: 11, product_id: 5, quantity: 1, lock_version: 7},
             complete?: true,
             protection: :locked
           }}

        request ->
          candidate_state(pid, token, request)
      end

      with {:ok, %Graph{} = graph, _context} <- prepare_fun.(loader) do
        send(pid, {token, :graph, graph})
        {:ok, %Selecto.Write.Result{operation: :graph, affected_rows: 4}}
      end
    end

    defp candidate_state(pid, token, request) do
      send(pid, {token, :candidate_request, request})

      {:ok,
       %Selecto.Write.CandidateState{
         rows: [
           %{id: 11, product_id: 5, quantity: 1, lock_version: 7},
           %{id: 12, product_id: 6, quantity: 2, lock_version: 2},
           %{id: 13, product_id: 7, quantity: 3, lock_version: 4}
         ],
         complete?: true,
         protection: :locked
       }}
    end
  end

  test "canonical nested rules reject before graph dispatch and accept the valid control" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: {self(), :nested_rules}}

    invalid_count = operation([item("one", 5, 1), item("two", 6, 1)])

    assert {:error,
            %Error{
              details: %{code: :data_rule_failed, path: [:items], outcomes: count_outcomes}
            }} = SelectoUpdato.execute(invalid_count, selecto)

    assert Enum.any?(count_outcomes, &(&1.code == :invalid_collection_count))

    refute_receive {:nested_rules, _graph}

    invalid_child =
      operation([item("one", 5, 1), item("two", 6, 0), item("three", 7, 1)])

    assert {:error,
            %Error{
              details: %{
                code: :data_rule_failed,
                path: [:items, "client_id=two", "quantity"]
              }
            }} = SelectoUpdato.execute(invalid_child, selecto)

    refute_receive {:nested_rules, _graph}

    duplicate =
      operation([item("one", 5, 1), item("two", 5, 2), item("three", 7, 1)])

    assert {:error,
            %Error{
              details: %{code: :data_rule_failed, path: [:items], outcomes: unique_outcomes}
            }} = SelectoUpdato.execute(duplicate, selecto)

    assert Enum.any?(unique_outcomes, &(&1.code == :duplicate_collection_value))

    refute_receive {:nested_rules, _graph}

    valid = operation([item("one", 5, 1), item("two", 6, 2), item("three", 7, 3)])
    assert {:ok, %Selecto.Write.Result{operation: :graph}} = SelectoUpdato.execute(valid, selecto)
    assert_receive {:nested_rules, %Graph{} = graph}
    assert Enum.find(graph.nodes, &(&1.id == "items")).rows |> length() == 3
  end

  test "candidate collection rules fail closed for a partial nested delta" do
    operation =
      canonical_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{mode: :delta, create: [item("new", 5, 1)]}
      })

    assert {:error,
            %Error{
              details: %{
                code: :required_data_rule_pending,
                stage: :candidate,
                representation: :delta,
                path: [:items]
              }
            }} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "trusted candidate state materializes a delta before canonical collection rules" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: {self(), :candidate_rules}}
    test_pid = self()

    provider = fn %CandidateRequest{} = request ->
      send(test_pid, {:candidate_request, request})

      {:ok,
       CandidateStateHelper.complete(
         [
           %{id: 11, product_id: 5, quantity: 1, lock_version: 7},
           %{id: 12, product_id: 6, quantity: 2, lock_version: 2},
           %{id: 13, product_id: 7, quantity: 3, lock_version: 4}
         ],
         protection: :snapshot,
         revision: "items-v1"
       )}
    end

    valid = delta_operation(%{update: [%{id: 11, lock_version: 7, quantity: 4}]})

    assert {:ok, %Selecto.Write.Result{operation: :graph}} =
             SelectoUpdato.execute(valid, selecto, candidate_state_provider: provider)

    assert_receive {:candidate_request,
                    %CandidateRequest{
                      relationship: "items",
                      path: [:items],
                      representation: :delta,
                      identity_fields: ["id"],
                      max_rows: 1_000
                    }}

    assert_receive {:candidate_rules, %Graph{}}

    missing_item = delta_operation(%{delete: [%{id: 13, lock_version: 4}]})

    assert {:error, %Error{details: %{code: :data_rule_failed, path: [:items]}}} =
             SelectoUpdato.execute(missing_item, selecto, candidate_state_provider: provider)

    duplicate =
      delta_operation(%{
        delete: [%{id: 13, lock_version: 4}],
        create: [item("replacement", 5, 1)]
      })

    assert {:error, %Error{details: %{code: :data_rule_failed, path: [:items]}}} =
             SelectoUpdato.execute(duplicate, selecto, candidate_state_provider: provider)

    refute_receive {:candidate_rules, _graph}
  end

  test "execute automatically uses an adapter-owned protected candidate loader" do
    selecto = %Selecto{
      adapter: PreparedRecordingAdapter,
      connection: {self(), :prepared_candidate}
    }

    valid = delta_operation(%{update: [%{id: 11, lock_version: 7, quantity: 4}]})

    assert {:ok, %Selecto.Write.Result{operation: :graph}} = SelectoUpdato.execute(valid, selecto)

    assert_receive {:prepared_candidate, :candidate_request,
                    %CandidateRequest{
                      parent_key: "id",
                      child_relation: "order_items",
                      child_key: "order_id",
                      relationship: "items"
                    }}

    assert_receive {:prepared_candidate, :graph, %Graph{}}
  end

  test "governed nested updates carry the root membership-lock obligation" do
    valid = operation([item("one", 5, 1), item("two", 6, 2), item("three", 7, 3)])

    assert {:ok, %Graph{metadata: metadata}, _context} =
             SelectoUpdato.PortableCommand.compile(valid)

    assert metadata.membership_parent_lock == %{parent_key: "id"}
  end

  test "incomplete or ambiguous candidate state remains non-pass" do
    operation = delta_operation(%{update: [%{id: 11, lock_version: 7, quantity: 4}]})

    incomplete = fn _request ->
      {:ok, %CandidateState{rows: [], complete?: false, protection: :snapshot}}
    end

    assert {:error, %Error{details: %{code: :required_data_rule_pending, disposition: :pending}}} =
             SelectoUpdato.PortableCommand.compile(operation,
               candidate_state_provider: incomplete
             )

    ambiguous = fn _request ->
      {:ok,
       CandidateStateHelper.complete(
         [%{id: 11, product_id: 5}, %{id: 11, product_id: 6}],
         protection: :snapshot
       )}
    end

    assert {:error, %Error{details: %{code: :ambiguous_candidate_identity, disposition: :error}}} =
             SelectoUpdato.PortableCommand.compile(operation,
               candidate_state_provider: ambiguous
             )

    over_limit = fn _request ->
      rows = Enum.map(1..1_001, &%{id: &1, product_id: &1, quantity: 1})
      {:ok, CandidateStateHelper.complete(rows, protection: :snapshot)}
    end

    assert {:error, %Error{details: %{code: :candidate_state_limit_exceeded}}} =
             SelectoUpdato.PortableCommand.compile(operation,
               candidate_state_provider: over_limit
             )
  end

  defp operation(items) do
    canonical_domain()
    |> SelectoUpdato.new(tenant: %{tenant_id: 7})
    |> SelectoUpdato.filter({:id, 42})
    |> SelectoUpdato.update(%{status: "submitted", items: %{mode: :full_set, items: items}})
  end

  defp delta_operation(changes) do
    canonical_domain()
    |> SelectoUpdato.new(tenant: %{tenant_id: 7})
    |> SelectoUpdato.filter({:id, 42})
    |> SelectoUpdato.update(%{
      status: "submitted",
      items: Map.put(changes, :mode, :delta)
    })
  end

  defp item(client_id, product_id, quantity) do
    %{client_id: client_id, product_id: product_id, quantity: quantity, lock_version: 1}
  end

  defp canonical_domain do
    root = CompositionFixtures.order_document()
    child = get_in(root, [:writes, :relationships, "items", :domain])

    child =
      child
      |> put_in([:writes, :fields, "quantity", :validators], [])
      |> Map.put(:rules, %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          positive_quantity: %{version: 1, test: %{op: "number.gt", bound: "0"}}
        },
        normalizers: %{},
        bindings: %{
          positive_quantity: %{
            subject: %{scope: :candidate, path: [:quantity]},
            operations: [:insert, :update, :upsert],
            rule: %{id: :positive_quantity, version: 1}
          }
        }
      })

    root
    |> put_in([:writes, :relationships, "items", :domain], child)
    |> put_in([:writes, :relationships, "items", :validation], %{})
    |> Map.put(:rules, %{
      schema: "selecto.data_rules.v1",
      definitions: %{
        exactly_three: %{version: 1, test: %{op: "collection.count", exact: 3}},
        unique_product: %{
          version: 1,
          test: %{op: "collection.unique_by", paths: [[:product_id]]}
        }
      },
      normalizers: %{},
      bindings: %{
        exactly_three: %{
          subject: %{scope: :candidate, path: [:items]},
          operations: [:update],
          rule: %{id: :exactly_three, version: 1}
        },
        unique_product: %{
          subject: %{scope: :candidate, path: [:items]},
          operations: [:update],
          rule: %{id: :unique_product, version: 1}
        }
      }
    })
  end
end
