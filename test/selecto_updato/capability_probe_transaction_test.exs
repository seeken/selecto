defmodule SelectoUpdato.CapabilityProbeTransactionTest do
  # Regression: the executor used to probe `write_capabilities/1` through the
  # Selecto's pool connection from inside the adapter's prepared-write
  # transaction. With a pool of one (PostgreSQL), that second checkout waits on
  # the connection the transaction already holds and deadlocks.
  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, UpsertCandidateRequest, UpsertCandidateState}

  defmodule SingleConnectionAdapter do
    @moduledoc false
    # Models a pool of size one: the prepared write owns the only connection
    # while its preparation runs, so a capability probe through the pool
    # cannot check one out.
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    @transaction_key {__MODULE__, :transaction_open}

    def name, do: :sqlite
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(pid) do
      in_transaction? = Process.get(@transaction_key, false)
      send(pid, {:capability_probe, in_transaction?})

      if in_transaction?, do: exit({:timeout, :pool_checkout_while_transaction_open})

      %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        prepared_candidate_state: true,
        native_rule_candidates: true,
        protected_upsert_candidates: true,
        committed_effect_sink: true
      }
    end

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}
    def execute_write(_connection, _command, _opts), do: raise("prepared path must be used")

    def execute_prepared_write(pid, prepare, _opts) do
      prepare = Selecto.Write.Authorization.governed_preparation(prepare)

      in_transaction(fn ->
        with {:ok, %Command{} = command, _context} <- prepare.(loader(pid)) do
          send(pid, {:prepared_command, command})
          {:ok, %Selecto.Write.Result{operation: command.operation, affected_rows: 1}}
        end
      end)
    end

    def preview_prepared_write(pid, prepare, _opts) do
      in_transaction(fn ->
        with {:ok, %Command{} = command, _context} <- prepare.(loader(pid)) do
          send(pid, {:previewed_command, command})
          {:ok, %{command: command}}
        end
      end)
    end

    defp in_transaction(fun) do
      Process.put(@transaction_key, true)

      try do
        fun.()
      after
        Process.delete(@transaction_key)
      end
    end

    defp loader(pid) do
      fn %UpsertCandidateRequest{} = request ->
        send(pid, {:upsert_candidate_request, request})
        prior = %{"id" => 1, "start" => "5", "finish" => "5"}
        updated = MapSet.new(request.command.metadata.upsert_update_fields)

        changes =
          Map.new(
            Enum.filter(request.command.assignments, &MapSet.member?(updated, &1.field)),
            fn %{field: field, value: {:literal, value}} -> {field, value} end
          )

        {:ok,
         %UpsertCandidateState{
           values: Map.merge(prior, changes),
           prior_values: prior,
           branch: :conflict,
           effect: :update,
           complete?: true,
           protection: :locked,
           receipt: make_ref()
         }}
      end
    end
  end

  setup do
    {:ok, selecto: %Selecto{adapter: SingleConnectionAdapter, connection: self()}}
  end

  test "protected upsert execution probes capabilities only before the transaction", %{
    selecto: selecto
  } do
    assert {:ok, %Selecto.Write.Result{operation: :upsert}} =
             SelectoUpdato.execute(upsert_operation(), selecto)

    assert_received {:upsert_candidate_request, %UpsertCandidateRequest{}}
    assert_received {:prepared_command, %Command{operation: :upsert} = command}
    assert :protected_upsert_candidates in command.required_capabilities
    assert_received {:capability_probe, false}
    refute_received {:capability_probe, true}
  end

  test "protected upsert preview probes capabilities only before the transaction", %{
    selecto: selecto
  } do
    assert {:ok, %{command: %Command{operation: :upsert}}} =
             SelectoUpdato.preview(upsert_operation(), selecto)

    assert_received {:previewed_command, %Command{operation: :upsert}}
    assert_received {:capability_probe, false}
    refute_received {:capability_probe, true}
  end

  defp upsert_operation do
    %{
      source: %{
        source_table: "ranges",
        primary_key: :id,
        fields: [:id, :start, :finish],
        columns: %{id: %{type: :integer}, start: %{type: :decimal}, finish: %{type: :decimal}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          upsert: %{enabled: true, conflict_targets: [[:id]], update_fields: [:start, :finish]}
        },
        fields: %{
          id: %{insertable: true},
          start: %{insertable: true, updatable: true},
          finish: %{insertable: true, updatable: true}
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          finish_after_start: %{
            version: 1,
            test: %{op: "value.compare_path", comparison: "gt", path: [:start]}
          }
        },
        normalizers: %{},
        bindings: %{
          finish_after_start: %{
            subject: %{scope: :candidate, path: [:finish]},
            rule: %{id: :finish_after_start, version: 1}
          }
        }
      }
    }
    |> SelectoUpdato.new()
    |> SelectoUpdato.upsert(%{id: 1, start: "5", finish: "6"})
  end
end
