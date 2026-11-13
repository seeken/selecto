defmodule SelectoUpdato.TenantPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "require_tenant_filter is idempotent and preserves existing filters" do
    check all(
            tenant_id <- string(:alphanumeric, min_length: 1, max_length: 20),
            extra_filters <- list_of(non_tenant_filter_generator(), max_length: 5)
          ) do
      op =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.update(%{name: "updated"})
        |> SelectoUpdato.filters(extra_filters)

      once = SelectoUpdato.require_tenant_filter(op, "tenant_id", tenant_id)
      twice = SelectoUpdato.require_tenant_filter(once, "tenant_id", tenant_id)

      assert once.filters == twice.filters
      assert Enum.count(twice.filters, &(&1 == {"tenant_id", tenant_id})) == 1

      Enum.each(extra_filters, fn filter ->
        assert filter in twice.filters
      end)
    end
  end

  property "apply_tenant_scope is idempotent and injects tenant filter" do
    check all(
            tenant_id <- string(:alphanumeric, min_length: 1, max_length: 20),
            required_filters <- list_of(non_tenant_filter_generator(), max_length: 3),
            extra_filters <- list_of(non_tenant_filter_generator(), max_length: 3)
          ) do
      base =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.update(%{name: "updated"})
        |> SelectoUpdato.filters(extra_filters)
        |> SelectoUpdato.with_tenant(%{tenant_id: tenant_id, required_filters: required_filters})

      scoped_once = SelectoUpdato.apply_tenant_scope(base)
      scoped_twice = SelectoUpdato.apply_tenant_scope(scoped_once)

      assert scoped_once.filters == scoped_twice.filters
      assert {"tenant_id", tenant_id} in scoped_once.filters

      Enum.each(extra_filters ++ required_filters, fn filter ->
        assert filter in scoped_once.filters
      end)
    end
  end

  property "validate_tenant_scope behavior matches tenant context presence" do
    check all(
            tenant_id <-
              one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 20)])
          ) do
      op =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.update(%{name: "updated"})
        |> SelectoUpdato.filter({"id", 1})
        |> SelectoUpdato.with_tenant(%{tenant_id: tenant_id})

      scoped = SelectoUpdato.apply_tenant_scope(op)

      has_scope = not is_nil(tenant_id)

      if has_scope do
        assert :ok = SelectoUpdato.validate_tenant_scope(scoped)
      else
        assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
                 SelectoUpdato.validate_tenant_scope(scoped)
      end
    end
  end

  defp non_tenant_filter_generator do
    one_of([
      map(integer(1..1000), &{"id", &1}),
      map(string(:alphanumeric, min_length: 1, max_length: 12), &{"name", &1}),
      map(string(:alphanumeric, min_length: 1, max_length: 12), &{"status", &1})
    ])
  end

  defp domain do
    %{
      source: %{source_table: "items"},
      columns: %{
        "id" => %{type: :integer},
        "tenant_id" => %{type: :string},
        "name" => %{type: :string},
        "status" => %{type: :string}
      }
    }
  end

  defp tenant_required_domain do
    Map.put(domain(), :tenant_required, true)
  end
end
