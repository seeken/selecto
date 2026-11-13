defmodule SelectoUpdato.TrustedRequiredFiltersTest do
  # A trusted context's required filters bound every write whether or not
  # the domain declares writes.scope.tenant (w3exrev14 HIGH: they were
  # dropped silently on a domain without it). They join the pre-image
  # predicate and the post-image scope, refuse a scoped upsert, and a
  # compile that never applied them is refused rather than run unscoped.
  use ExUnit.Case, async: true

  alias Selecto.Write.Command
  alias SelectoUpdato.{Error, PortableCommand, Tenant}

  defp domain do
    %{
      name: "rq",
      source: %{
        source_table: "rq",
        primary_key: :id,
        fields: [:id, :code, :site, :name],
        columns: %{
          id: %{type: :integer},
          code: %{type: :string},
          site: %{type: :string},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          upsert: %{enabled: true, conflict_targets: [[:code]]}
        },
        fields: %{
          id: %{insertable: true},
          code: %{insertable: true},
          site: %{insertable: true, updatable: true},
          name: %{insertable: true, updatable: true}
        }
      }
    }
  end

  @pin [{"site", "S1"}]
  @catalog %{
    "rq" =>
      Map.new(~w(code site name), &{&1, %{type: "text"}}) |> Map.put("id", %{type: "integer"})
  }

  defp forms do
    [
      {"opts", &SelectoUpdato.new(&1), [required_filters: @pin]},
      {"context", &SelectoUpdato.new(&1), [context: %{required_filters: @pin}]},
      {"new(tenant:)", &SelectoUpdato.new(&1, tenant: %{required_filters: @pin}), []}
    ]
  end

  # What the executor does: apply the execution scope, then compile.
  defp compile(operation, opts) do
    operation
    |> Tenant.apply_execution_scope(opts)
    |> PortableCommand.compile(Keyword.put(opts, :column_metadata, @catalog))
  end

  defp conjuncts({:and, predicates}), do: Enum.flat_map(predicates, &conjuncts/1)
  defp conjuncts(predicate), do: [predicate]

  test "a host filter equal to a trusted one, named as an atom, is the same filter" do
    site = {:eq, {:field, "site"}, {:literal, "S1"}}

    for {label, new, opts} <- forms() do
      assert {:ok, %Command{predicate: predicate}, _} =
               domain()
               |> new.()
               |> SelectoUpdato.filter({:id, 1})
               |> SelectoUpdato.filter({:site, "S1"})
               |> SelectoUpdato.update(%{name: "u"})
               |> compile(opts),
             label

      assert site in conjuncts(predicate), label
    end

    # A different value is another filter, and the mixed names refuse as before.
    assert {:error, %Error{details: %{code: :duplicate_filter_identifier}}} =
             domain()
             |> SelectoUpdato.new()
             |> SelectoUpdato.filter({:site, "S2"})
             |> SelectoUpdato.update(%{name: "u"})
             |> compile(required_filters: @pin)
  end

  test "every call form bounds the update's pre-image and post-image" do
    site = {:eq, {:field, "site"}, {:literal, "S1"}}

    for {label, new, opts} <- forms() do
      assert {:ok, %Command{predicate: predicate, metadata: metadata}, _} =
               domain()
               |> new.()
               |> SelectoUpdato.filter({:id, 1})
               |> SelectoUpdato.update(%{name: "u"})
               |> compile(opts),
             label

      assert site in conjuncts(predicate), label
      assert site in conjuncts(metadata.post_image.predicate), label
    end
  end

  test "every call form puts the trusted scope into the insert's full guard" do
    for {label, new, opts} <- forms() do
      assert {:ok, %Command{metadata: %{post_image: %{predicate: predicate}}}, _} =
               domain()
               |> new.()
               |> SelectoUpdato.insert(%{id: 5, site: "S1", name: "n"})
               |> compile(opts),
             label

      assert {:eq, {:field, "site"}, {:literal, "S1"}} in conjuncts(predicate), label
    end
  end

  test "a scoped upsert is refused in every call form" do
    for {label, new, opts} <- forms() do
      assert {:error, %Error{details: %{code: :query_enforcement_unsupported_operation}}} =
               domain()
               |> new.()
               |> SelectoUpdato.upsert(%{id: 3, code: "b", site: "S1", name: "n"})
               |> SelectoUpdato.conflict_target([:code])
               |> compile(opts),
             label
    end
  end

  test "a compile that never applied the trusted filters is refused" do
    for {label, new, opts} <- forms() do
      assert {:error, %Error{details: %{code: :trusted_required_filters_unapplied}}} =
               domain()
               |> new.()
               |> SelectoUpdato.filter({:id, 1})
               |> SelectoUpdato.update(%{name: "u"})
               |> PortableCommand.compile(opts),
             label
    end
  end
end
