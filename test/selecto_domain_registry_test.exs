defmodule Selecto.DomainRegistryTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.{Ref, Registry, RegistryError}

  defmodule OrdersRegistry do
    @behaviour Registry

    @impl true
    def fetch(id, context) when id in ["orders", :orders] do
      if Map.get(context, :allowed, true) do
        {:ok, Selecto.DomainRegistryTest.domain(), %{source: :test_registry}}
      else
        {:error, :forbidden}
      end
    end

    def fetch(_id, _context), do: {:error, :not_found}
  end

  defmodule GeneratedDomain do
    use Registry, id: "generated"

    def domain, do: Selecto.DomainRegistryTest.domain("Generated")
  end

  defmodule BareMapRegistry do
    @behaviour Registry
    @impl true
    def fetch(_id, _context), do: Selecto.DomainRegistryTest.domain()
  end

  defmodule InvalidDomainRegistry do
    @behaviour Registry
    @impl true
    def fetch(_id, _context), do: {:ok, %{name: "Invalid"}}
  end

  defmodule AliasedJoinRegistry do
    use Registry, id: "aliased_join"

    def domain do
      Selecto.DomainRegistryTest.domain()
      |> put_in([:source, :fields], [:id, :customer_id])
      |> put_in([:source, :columns], %{
        id: %{type: :integer},
        customer_id: %{type: :integer}
      })
      |> put_in([:source, :associations], %{
        customer: %{
          queryable: :customers,
          field: :customer,
          owner_key: :customer_id,
          related_key: :id
        }
      })
      |> Map.put(:schemas, %{
        customers: %{
          source_table: "customers",
          primary_key: :id,
          fields: [:id, :name],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      })
      |> Map.put(:joins, %{customer: %{type: :star_dimension, display_field: :name}})
      |> Map.put(:default_selected, [:id, "customer.name", "customer_display"])
    end
  end

  test "resolves a named domain with validated provenance" do
    assert {:ok, domain, %Ref{} = ref} = Registry.resolve(OrdersRegistry, "orders")
    assert domain.name == "Orders"
    assert ref.id == "orders"
    assert ref.registry == OrdersRegistry
    assert ref.version == "1.0.0"
    assert ref.fingerprint == "sha256:orders"
    assert ref.metadata == %{source: :test_registry}
  end

  test "generated single-domain registries accept atom/string identity without creating atoms" do
    assert GeneratedDomain.domain_id() == "generated"
    assert %Ref{id: "generated", registry: GeneratedDomain} = GeneratedDomain.domain_ref()
    assert {:ok, %{name: "Generated"}, _ref} = Registry.resolve(GeneratedDomain, :generated)
  end

  test "generated registry ids must be stable atoms or non-empty strings" do
    assert_raise ArgumentError, ~r/non-empty atom or string/, fn ->
      Code.compile_string("""
      defmodule InvalidGeneratedDomain do
        use Selecto.Domain.Registry, id: ""
        def domain, do: %{}
      end
      """)
    end
  end

  test "portable validation recognizes runtime join aliases" do
    assert {:ok, domain, _ref} = Registry.resolve(AliasedJoinRegistry, "aliased_join")
    assert domain.default_selected == [:id, "customer.name", "customer_display"]
  end

  test "unknown and forbidden domains fail closed" do
    assert {:error, %RegistryError{reason: :not_found}} =
             Registry.resolve(OrdersRegistry, "missing")

    assert {:error, %RegistryError{reason: :forbidden}} =
             Registry.resolve(OrdersRegistry, "orders", %{allowed: false})
  end

  test "bare maps and invalid domains are rejected" do
    assert {:error, %RegistryError{reason: :invalid_registry_result}} =
             Registry.resolve(BareMapRegistry, "orders")

    assert {:error, %RegistryError{reason: :invalid_domain_contract}} =
             Registry.resolve(InvalidDomainRegistry, "orders")
  end

  test "configure_registered records provenance and never permits validation bypass" do
    selecto =
      Selecto.configure_registered("orders", :mock_connection,
        registry: OrdersRegistry,
        mode: :strict
      )

    assert Selecto.domain(selecto).name == "Orders"
    assert %Ref{id: "orders", registry: OrdersRegistry} = Selecto.domain_ref(selecto)

    assert_raise ArgumentError, ~r/require validation/, fn ->
      Selecto.configure_registered("orders", :mock_connection,
        registry: OrdersRegistry,
        validate: false
      )
    end
  end

  test "configure_registered accepts an opaque ref and rejects registry substitution" do
    ref = Ref.new("orders", OrdersRegistry)
    assert %Selecto{} = Selecto.configure_registered(ref, :mock_connection)

    assert_raise ArgumentError, ~r/does not match/, fn ->
      Selecto.configure_registered(ref, :mock_connection, registry: GeneratedDomain)
    end
  end

  def domain(name \\ "Orders") do
    %{
      schema_version: 1,
      domain_version: "1.0.0",
      domain_fingerprint: "sha256:orders",
      name: name,
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
