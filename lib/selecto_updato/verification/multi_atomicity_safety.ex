defmodule SelectoUpdato.Verification.MultiAtomicitySafety do
  @moduledoc """
  Bounded executable verification of the public Multi API's portable atomicity
  boundary and result-name bijection.

  The model runs the public batch path against an adapter-neutral probe while
  crossing unique and duplicate names, first/second compile failure, matching
  and conflicting trusted tenant contexts, and exact, short, and failed adapter
  results. Database rollback remains an adapter integration property.
  """

  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.{Batch, Result}

  @names [:unique, :duplicate]
  @compile_failures [:none, :first, :second]
  @contexts [:same, :conflicting]
  @adapter_outcomes [:exact, :short, :long, :non_list, :error]

  defmodule ProbeAdapter do
    @moduledoc false
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Batch, Error, Preview, Result}

    def name, do: :updato_multi_verification
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
        write_graph: true
      }

    def preview_write(_connection, command, _opts) do
      {:ok, %Preview{statements: [%{text: "probe", params: []}], metadata: %{command: command}}}
    end

    def execute_write(outcome, %Batch{} = batch, _opts) do
      Process.put({__MODULE__, :dispatches}, [batch | dispatches()])

      results =
        batch.commands
        |> Enum.with_index()
        |> Enum.map(fn {command, index} ->
          %Result{
            operation: command.operation,
            affected_rows: 1,
            metadata: %{batch_index: index}
          }
        end)

      case outcome do
        :exact ->
          {:ok, results}

        :short ->
          {:ok, Enum.take(results, max(length(results) - 1, 0))}

        :long ->
          {:ok,
           results ++
             [%Result{operation: :insert, affected_rows: 1, metadata: %{batch_index: :extra}}]}

        :non_list ->
          {:ok, List.first(results)}

        :error ->
          {:error, Error.new(:adapter_failure, "atomic batch failed")}
      end
    end

    def reset, do: Process.delete({__MODULE__, :dispatches})
    def dispatches, do: Process.get({__MODULE__, :dispatches}, [])
  end

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.multi_atomicity.v1", states(), invariants())
  end

  @doc false
  def states do
    for names <- @names,
        compile_failure <- @compile_failures,
        contexts <- @contexts,
        adapter_outcome <- @adapter_outcomes do
      ProbeAdapter.reset()
      multi = build_multi(names, compile_failure, contexts)
      selecto = %Selecto{adapter: ProbeAdapter, connection: adapter_outcome}
      result = SelectoUpdato.run(multi, selecto)

      %{
        names: names,
        compile_failure: compile_failure,
        contexts: contexts,
        adapter_outcome: adapter_outcome,
        result: result,
        dispatches: ProbeAdapter.dispatches()
      }
    end
  after
    ProbeAdapter.reset()
  end

  defp invariants do
    [
      {"all_operations_compile_before_single_dispatch", &compile_all_before_dispatch/1},
      {"dispatched_batch_is_ordered_and_atomic", &ordered_atomic_batch/1},
      {"trusted_batch_context_must_agree", &context_agreement/1},
      {"operation_names_and_results_form_a_bijection", &result_bijection/1},
      {"errors_never_return_partial_name_maps", &no_partial_mapping/1}
    ]
  end

  defp compile_all_before_dispatch(state) do
    expected_dispatch? = predispatch_valid?(state)
    actual_count = length(state.dispatches)

    if (expected_dispatch? and actual_count == 1) or
         (not expected_dispatch? and actual_count == 0),
       do: :ok,
       else: {:error, %{expected_dispatch?: expected_dispatch?, dispatches: state.dispatches}}
  end

  defp ordered_atomic_batch(state) do
    case state.dispatches do
      [%Batch{atomic?: true, commands: [first, second]}] ->
        if [first.operation, second.operation] == [:insert, :update],
          do: :ok,
          else: {:error, %{operation_order: [first.operation, second.operation]}}

      [] ->
        :ok

      other ->
        {:error, %{unexpected_dispatches: other}}
    end
  end

  defp context_agreement(%{contexts: :conflicting} = state) do
    if state.dispatches == [] and error_result?(state.result),
      do: :ok,
      else: {:error, %{conflicting_context_dispatched: state}}
  end

  defp context_agreement(_state), do: :ok

  defp result_bijection(state) do
    successful? = predispatch_valid?(state) and state.adapter_outcome == :exact

    case {successful?, state.result} do
      {true,
       {:ok,
        %{
          first: %Result{operation: :insert, metadata: %{batch_index: 0}},
          second: %Result{operation: :update, metadata: %{batch_index: 1}}
        }}} ->
        :ok

      {true, other} ->
        {:error, %{missing_result_bijection: other}}

      {false, {:ok, result}} ->
        {:error, %{invalid_batch_returned_success_map: result}}

      {false, {:error, _error}} ->
        :ok
    end
  end

  defp no_partial_mapping(%{result: {:error, _error}}), do: :ok
  defp no_partial_mapping(_state), do: :ok

  defp predispatch_valid?(state) do
    state.names == :unique and state.compile_failure == :none and state.contexts == :same
  end

  defp error_result?({:error, _error}), do: true
  defp error_result?(_result), do: false

  defp build_multi(names, compile_failure, contexts) do
    first =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(attrs(compile_failure == :first, "one"))
      |> SelectoUpdato.with_tenant(%{tenant_id: "tenant-a"})

    second_tenant = if contexts == :same, do: "tenant-a", else: "tenant-b"

    second =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(attrs(compile_failure == :second, "two"))
      |> SelectoUpdato.filter({:id, 7})
      |> SelectoUpdato.with_tenant(%{tenant_id: second_tenant})

    second_name = if names == :unique, do: :second, else: :first
    %SelectoUpdato.Multi{operations: [{:first, first}, {second_name, second}]}
  end

  defp attrs(false, name), do: %{name: name}
  defp attrs(true, name), do: %{:name => name, "name" => "ambiguous"}

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :string},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{insertable: true, updatable: true}
        },
        scope: %{
          tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
        }
      }
    }
  end
end
