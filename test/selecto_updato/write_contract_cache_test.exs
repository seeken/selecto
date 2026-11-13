defmodule SelectoUpdato.WriteContractCacheTest do
  # Governance compiles each domain's write contract once
  # (Selecto.Domain.WriteContract caches it by exact domain); these tests pin
  # that a cached contract governs exactly like a freshly compiled one.
  # Not async: the contract cache is one 256-entry table that empties when
  # full, so another test's domains could evict an entry mid-assertion; and
  # the call trace is global.
  use ExUnit.Case, async: false

  alias Selecto.Domain.WriteContract
  alias Selecto.Write.{Batch, Command, Preview, Result}
  alias SelectoUpdato.PortableCommand

  defmodule PreviewAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :contract_cache_test
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

    def preview_write(_connection, command, opts),
      do: {:ok, %Preview{statements: [%{text: "preview", params: [command, opts[:context]]}]}}

    def execute_write(_connection, %Batch{commands: commands}, _opts) do
      {:ok, Enum.map(commands, &%Result{operation: &1.operation, affected_rows: 1})}
    end
  end

  test "cached and freshly compiled contracts govern identically" do
    for {label, build, opts} <- commands() do
      # A domain no other test has compiled, so the first call misses.
      domain = unique_domain()
      operation = build.(domain)

      {cold, 1} = compilations(fn -> govern(operation, opts) end)
      {warm, 0} = compilations(fn -> govern(operation, opts) end)
      {copied, 0} = compilations(fn -> govern(build.(copy(domain)), opts) end)

      assert warm == cold, label

      assert match?({{:ok, _, _}, {:ok, _}}, cold) == not String.starts_with?(label, "refused"),
             label

      assert copied == cold, label
    end
  end

  test "refusal codes come from the domain actually passed, not a cached neighbour" do
    domain = unique_domain()
    update_tenant = fn domain -> update(domain, %{tenant_id: 9}) end

    assert {{:error, %{type: :write_field_not_writable}},
            {:error, %{type: :write_field_not_writable}}} =
             govern(update_tenant.(domain), [])

    widened =
      put_in(domain, [:writes, :fields, :tenant_id], %{insertable: true, updatable: true})

    assert {{:ok, %Command{operation: :update}, _context}, 1} =
             compilations(fn -> PortableCommand.compile(update_tenant.(widened)) end)

    # And the original is still refused.
    assert {{:error, %{type: :write_field_not_writable}},
            {:error, %{type: :write_field_not_writable}}} =
             govern(update_tenant.(domain), [])
  end

  test "a batch compiles its domain's contract once" do
    domain = unique_domain()

    multi =
      Enum.reduce(1..100, SelectoUpdato.multi(), fn n, multi ->
        multi
        |> SelectoUpdato.multi_insert(:"insert_#{n}", domain, %{name: "row #{n}", tenant_id: 1})
        |> SelectoUpdato.multi_update(:"update_#{n}", domain,
          filters: [{:id, n}],
          changes: %{name: "renamed #{n}"}
        )
      end)

    selecto = %Selecto{adapter: PreviewAdapter, connection: :none}

    assert {{:ok, results}, 1} = compilations(fn -> SelectoUpdato.run(multi, selecto) end)
    assert map_size(results) == 200
  end

  defp commands do
    [
      {"insert", &SelectoUpdato.insert(SelectoUpdato.new(&1), %{name: "new", tenant_id: 1}), []},
      {"update", &update(&1, %{name: "renamed"}), []},
      {"delete",
       &(&1 |> SelectoUpdato.new() |> SelectoUpdato.filter({:id, 7}) |> SelectoUpdato.delete()),
       []},
      {"refused: insert-only field", &update(&1, %{tenant_id: 9}), []},
      {"refused: unknown field", &update(&1, %{missing: 1}), []},
      {"refused: unfiltered update", &SelectoUpdato.update(SelectoUpdato.new(&1), %{name: "x"}),
       []},
      {"tenant scoped", &update(scoped(&1), %{name: "renamed"}), [context: %{tenant_id: 3}]},
      {"refused: tenant missing", &update(scoped(&1), %{name: "renamed"}), []}
    ]
  end

  defp update(domain, changes) do
    domain
    |> SelectoUpdato.new()
    |> SelectoUpdato.filter({:id, 7})
    |> SelectoUpdato.update(changes)
  end

  # The governed results: the portable compile (governance) and the public
  # preview path.
  defp govern(operation, opts) do
    selecto = %Selecto{adapter: PreviewAdapter, connection: :none}

    compiled =
      operation
      |> SelectoUpdato.apply_execution_scope(opts)
      |> PortableCommand.compile(Keyword.put(opts, :action_phase, :execute))

    {compiled, SelectoUpdato.preview(operation, selecto, opts)}
  end

  # Runs `fun` in a fresh process and counts its uncached contract compilations.
  defp compilations(fun) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:result, fun.()})
        end
      end)

    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    :erlang.trace_pattern({Code.ensure_loaded!(WriteContract), :compile_uncached, 1}, true, [
      :local
    ])

    send(pid, :go)
    assert_receive {:result, result}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}, 5_000

    {result, count_calls(0)}
  end

  defp count_calls(count) do
    receive do
      {:trace, _pid, :call, {WriteContract, :compile_uncached, _args}} -> count_calls(count + 1)
    after
      0 -> count
    end
  end

  defp copy(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  defp scoped(domain),
    do:
      put_in(domain, [:writes, :scope], %{
        tenant: %{required: true, field: "tenant_id", satisfied_by: ["trusted_context"]}
      })

  defp unique_domain do
    %{
      name: "ContractCache#{System.unique_integer([:positive])}",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :tenant_id],
        columns: %{id: %{type: :integer}, name: %{type: :string}, tenant_id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true},
          delete: %{enabled: true, require_filter: true}
        },
        fields: %{name: %{insertable: true, updatable: true}, tenant_id: %{insertable: true}}
      }
    }
  end
end
