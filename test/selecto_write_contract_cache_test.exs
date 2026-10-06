defmodule Selecto.WriteContractCacheTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.WriteContract
  alias Selecto.Domain.WriteContract.Cache
  alias Selecto.Write.Error

  test "a cached contract is the one an uncached compilation produces" do
    for domain <- [write_domain(), delete_only_domain(), scoped_domain()] do
      expected = WriteContract.compile_uncached(domain)

      assert {:ok, %WriteContract{}} = expected
      # The first call compiles and stores; the second is served from the cache,
      # also for an equal copy of the domain and for a configured Selecto value.
      assert WriteContract.compile(domain) == expected
      assert WriteContract.compile(domain) == expected
      assert WriteContract.compile(copy(domain)) == expected
      assert WriteContract.compile(%Selecto{domain: domain}) == expected
    end
  end

  test "refusals are identical and never cached" do
    for domain <- [read_domain(), Map.put(read_domain(), :writes, %{operations: %{}}), %{}] do
      expected = WriteContract.compile_uncached(domain)
      assert {:error, %Error{}} = expected

      assert compilations(fn -> WriteContract.compile(domain) end) == {expected, 1}
      assert compilations(fn -> WriteContract.compile(domain) end) == {expected, 1}
    end

    assert WriteContract.compile(:not_a_domain) == WriteContract.compile_uncached(:not_a_domain)
  end

  test "an equal domain compiles once" do
    domain = unique(write_domain())

    assert {{:ok, contract}, 1} = compilations(fn -> WriteContract.compile(domain) end)

    assert compilations(fn ->
             for _ <- 1..100, do: {:ok, ^contract} = WriteContract.compile(copy(domain))
           end) == {List.duplicate({:ok, contract}, 100), 0}
  end

  test "a modified domain gets its own freshly compiled contract" do
    domain = unique(write_domain())
    {:ok, contract} = WriteContract.compile(domain)
    refute WriteContract.writable?(contract, :update, :tenant_id)

    # Same name and authored fingerprint, different write grants.
    widened =
      put_in(domain, [:writes, :fields, :tenant_id], %{insertable: true, updatable: true})

    assert {{:ok, widened_contract}, 1} =
             compilations(fn -> WriteContract.compile(widened) end)

    assert WriteContract.writable?(widened_contract, :update, :tenant_id)
    assert {:ok, ^widened_contract} = WriteContract.compile_uncached(widened)

    # Operations disabled after the fact are not served from the cache either.
    narrowed = put_in(domain, [:writes, :operations, :update], %{enabled: false})
    assert {{:ok, narrowed_contract}, 1} = compilations(fn -> WriteContract.compile(narrowed) end)
    refute WriteContract.operation_enabled?(narrowed_contract, :update)

    # A value that is equal but not identical (1 vs 1.0) is a different domain.
    float_column = put_in(domain, [:writes, :fields, :name, :max_length], 1.0)
    integer_column = put_in(domain, [:writes, :fields, :name, :max_length], 1)
    assert {_, 1} = compilations(fn -> WriteContract.compile(integer_column) end)
    assert {_, 1} = compilations(fn -> WriteContract.compile(float_column) end)

    # The original still gets its own contract.
    assert {{:ok, ^contract}, 0} = compilations(fn -> WriteContract.compile(domain) end)
  end

  test "the cache stays bounded" do
    for n <- 1..300, do: {:ok, _} = WriteContract.compile(unique(write_domain(), n))

    assert :ets.info(:selecto_write_contracts, :size) <= 256
  end

  test "clear empties the cache without changing results" do
    domain = unique(write_domain())
    {:ok, contract} = WriteContract.compile(domain)
    assert Cache.clear() == :ok
    assert {:ok, ^contract} = WriteContract.compile(domain)
  end

  # Runs `fun` in a fresh process and counts its uncached compilations.
  defp compilations(fun) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:result, fun.()})
        end
      end)

    :erlang.trace(pid, true, [:call, {:tracer, self()}])
    pattern = {Code.ensure_loaded!(WriteContract), :compile_uncached, 1}
    :erlang.trace_pattern(pattern, true, [:local])
    send(pid, :go)
    assert_receive {:result, result}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}

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

  defp unique(domain, n \\ System.unique_integer([:positive])),
    do: Map.put(domain, :name, "CacheTest#{n}")

  defp read_domain do
    %{
      name: "CacheTest",
      domain_fingerprint: "cache-test-v1",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :tenant_id],
        columns: %{id: %{type: :integer}, name: %{type: :string}, tenant_id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{}
    }
  end

  defp write_domain do
    Map.put(read_domain(), :writes, %{
      operations: %{insert: %{enabled: true}, update: %{enabled: true}},
      fields: %{
        name: %{insertable: true, updatable: true},
        tenant_id: %{insertable: true}
      }
    })
  end

  defp delete_only_domain,
    do: Map.put(read_domain(), :writes, %{operations: %{delete: %{enabled: true}}})

  defp scoped_domain do
    write_domain()
    |> put_in([:writes, :scope], %{
      tenant: %{required: true, field: :tenant_id, satisfied_by: ["trusted_context"]}
    })
  end
end
