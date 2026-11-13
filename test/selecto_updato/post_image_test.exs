defmodule SelectoUpdato.PostImageTest do
  # TW-09 (user decision 2026-10-24, "bound tenant-like scope only"): a
  # guarded INSERT/UPDATE command carries `metadata.post_image`, the scope the
  # stored rows must still satisfy after the statement. It is recorded by
  # provenance: the engine tenant, the trusted context's required filters and
  # a host-scope query. Plain required filters and query enforcement bound
  # only an UPDATE's pre-image; an INSERT is checked against its full guard.
  use ExUnit.Case, async: true

  alias Selecto.Write.Command
  alias SelectoUpdato.{Error, PortableCommand}

  defp domain(opts \\ []) do
    %{
      name: "TW",
      source:
        %{
          source_table: "tw",
          primary_key: :id,
          fields: [:id, :org_key, :site, :status, :name],
          columns: %{
            id: %{type: :integer},
            org_key: %{type: :string},
            site: %{type: :string},
            status: %{type: :string},
            name: %{type: :string}
          },
          associations: %{}
        }
        |> then(&if(opts[:tenant], do: Map.put(&1, :tenant_field, :org_key), else: &1)),
      schemas: %{},
      required_filters: Keyword.get(opts, :required, []),
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{
          id: %{insertable: true, updatable: true},
          org_key: %{insertable: true, updatable: true},
          site: %{insertable: true, updatable: true},
          status: %{insertable: true, updatable: true},
          name: %{insertable: true, updatable: true}
        }
      }
    }
  end

  defp catalog,
    do: %{
      "tw" =>
        Map.new(~w(org_key site status name), &{&1, %{type: "text"}})
        |> Map.put("id", %{type: "integer"})
    }

  defp compile(operation, opts \\ []),
    do: PortableCommand.compile(operation, Keyword.put(opts, :column_metadata, catalog()))

  defp post_image({:ok, %Command{metadata: metadata}, _context}),
    do: Map.get(metadata, :post_image)

  # What SelectoUpdato.Tenant.apply_execution_scope/2 records for a trusted
  # context's required filters (the executor applies it).
  defp trusted(operation, filters),
    do: %{operation | opts: Keyword.put(operation.opts || [], :trusted_required_filters, filters)}

  defp host_query(domain, filters) do
    %Selecto{
      domain: domain,
      set: %{
        selected: [],
        filtered: filters,
        required_filters: List.wrap(domain[:required_filters]),
        post_retarget_filters: [],
        order_by: [],
        group_by: []
      }
    }
  end

  test "an update under the engine tenant carries the tenant, even when a required filter restates it" do
    domain = domain(tenant: true, required: [{"org_key", "T1"}])

    image =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: "T1"})
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "u"})
      |> compile()
      |> post_image()

    assert image.key == ["id"]
    assert {:eq, {:field, "org_key"}, {:literal, "T1"}} in List.wrap(conjuncts(image.predicate))
  end

  test "trusted and host scope are post-image; plain required filters and QE are not" do
    trusted =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "u"})
      |> trusted([{"site", "S1"}])
      |> compile()
      |> post_image()

    assert trusted.predicate == {:eq, {:field, "site"}, {:literal, "S1"}}

    host =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "u"})
      |> SelectoUpdato.enforce_query(host_query(domain(), [{"site", "S1"}]), host_scope: true)
      |> compile()
      |> post_image()

    assert host.predicate == {:eq, {:field, "site"}, {:literal, "S1"}}

    # The domain's required filters ride in a host-scope capture too; they
    # stay pre-image only.
    required = domain(required: [{"status", "open"}])

    mixed =
      required
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{status: "closed"})
      |> SelectoUpdato.enforce_query(host_query(required, [{"site", "S1"}]), host_scope: true)
      |> compile()
      |> post_image()

    assert mixed.predicate == {:eq, {:field, "site"}, {:literal, "S1"}}

    for operation <- [
          required |> SelectoUpdato.new() |> SelectoUpdato.filter({:id, 1}),
          domain()
          |> SelectoUpdato.new()
          |> SelectoUpdato.filter({:id, 1})
          |> SelectoUpdato.enforce_query(host_query(domain(), [{"site", "S1"}]))
        ] do
      assert operation |> SelectoUpdato.update(%{status: "closed"}) |> compile() |> post_image() ==
               nil
    end
  end

  test "an insert is checked against its full guard" do
    required = domain(required: [{"status", "open"}])

    image =
      required
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: 2, site: "S1", status: "open"})
      |> trusted([{"site", "S1"}])
      |> compile()
      |> post_image()

    assert {:eq, {:field, "status"}, {:literal, "open"}} in conjuncts(image.predicate)
    assert {:eq, {:field, "site"}, {:literal, "S1"}} in conjuncts(image.predicate)
  end

  test "a scoped update cannot move the row's key; restating the filtered key is fine" do
    assert {:ok, _command, _context} =
             domain()
             |> SelectoUpdato.new()
             |> SelectoUpdato.filter({:id, 1})
             |> SelectoUpdato.update(%{id: 1, name: "u"})
             |> trusted([{"site", "S1"}])
             |> compile()

    assert {:error,
            %Error{details: %{code: :query_rule_not_evaluable, reason: :post_image_unavailable}}} =
             domain()
             |> SelectoUpdato.new()
             |> SelectoUpdato.filter({:id, 1})
             |> SelectoUpdato.update(%{id: 2})
             |> trusted([{"site", "S1"}])
             |> compile()
  end

  defp conjuncts({:and, predicates}), do: Enum.flat_map(predicates, &conjuncts/1)
  defp conjuncts(predicate), do: [predicate]
end
