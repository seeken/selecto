defmodule Selecto.Domain.CompositionFixtures do
  @moduledoc """
  Independently authored reference Domains for nested contract and runtime
  certification. These are finite fixtures, not claims about arbitrary schemas.
  """

  @spec all() :: %{required(atom()) => map()}
  def all do
    %{
      order_document: order_document(),
      vehicle_inspection: vehicle_inspection(),
      shared_tags: shared_tags(),
      deep_repeated_roles: deep_repeated_roles()
    }
  end

  @spec order_document() :: map()
  def order_document do
    item_domain =
      child_domain("order_items", %{
        "id" => column(:integer),
        "order_id" => column(:integer),
        "tenant_id" => column(:integer),
        "product_id" => column(:integer),
        "quantity" => column(:integer),
        "lock_version" => column(:integer)
      })
      |> put_in(
        [:writes, :fields, "quantity", :validators],
        [{:number, [greater_than: 0]}]
      )

    domain(
      "orders",
      %{
        "id" => column(:integer),
        "tenant_id" => column(:integer),
        "lock_version" => column(:integer),
        "status" => column(:string)
      },
      %{
        "items" =>
          composition(
            "order_items",
            "order_id",
            item_domain.source.columns,
            child_domain: item_domain,
            modes: [:delta, :full_set],
            operations: [:create, :update, :delete],
            min_items: 1,
            max_items: 200,
            validation: %{
              unique_fields: ["product_id"],
              field_rules: [
                %{field: "quantity", type: :number, required: true, greater_than: 0}
              ],
              aggregate_rules: [
                %{
                  operation: :sum,
                  field: "quantity",
                  maximum: 100,
                  representations: [:full_set]
                }
              ]
            }
          )
      }
    )
  end

  @spec vehicle_inspection() :: map()
  def vehicle_inspection do
    domain(
      "inspections",
      %{
        "id" => column(:integer),
        "tenant_id" => column(:integer),
        "lock_version" => column(:integer),
        "vin_snapshot" => column(:string)
      },
      %{
        "photos" =>
          composition(
            "inspection_photos",
            "inspection_id",
            %{
              "id" => column(:integer),
              "inspection_id" => column(:integer),
              "tenant_id" => column(:integer),
              "photo_url" => column(:string)
            },
            modes: [:append_only],
            operations: [:create],
            assurance: %{
              "gate" => "photo-matches-vin",
              "identity_binding" => "client_id",
              "staged" => true
            },
            offline: true
          )
      }
    )
  end

  @spec shared_tags() :: map()
  def shared_tags do
    domain(
      "products",
      %{"id" => column(:integer), "tenant_id" => column(:integer)},
      %{
        "tags" => %{
          ownership: :join_association,
          cardinality: :many,
          target: "tags",
          child_key: "product_id",
          identity_fields: ["tag_id"],
          read: %{allowed: true, default_depth: 1, max_depth: 1, max_rows: 100},
          write: %{
            modes: [:link_delta],
            link: true,
            unlink: true,
            omission: :unchanged,
            max_mutations: 100
          },
          tenant_scope: %{mode: :membership},
          capabilities: %{
            read: "product.read",
            link: "product.tag.link",
            unlink: "product.tag.unlink"
          },
          conflict: %{target_version: false},
          idempotency: %{request_key: true},
          offline: %{eligible: false},
          physical_provenance: %{
            join_table: "product_tags",
            parent_key: "product_id",
            target_key: "tag_id"
          }
        }
      }
    )
  end

  @spec deep_repeated_roles() :: map()
  def deep_repeated_roles do
    address =
      child_domain("addresses", %{
        "id" => column(:integer),
        "party_id" => column(:integer),
        "tenant_id" => column(:integer),
        "line_1" => column(:string)
      })

    party =
      child_domain(
        "parties",
        %{
          "id" => column(:integer),
          "document_id" => column(:integer),
          "tenant_id" => column(:integer),
          "name" => column(:string)
        },
        %{
          "addresses" =>
            composition("addresses", "party_id", address.source.columns,
              child_domain: address,
              modes: [:delta],
              operations: [:create, :update, :delete]
            )
        }
      )

    domain(
      "documents",
      %{"id" => column(:integer), "tenant_id" => column(:integer)},
      %{
        "bill_to" =>
          composition("parties", "document_id", party.source.columns,
            child_domain: party,
            path_id: "document.bill_to",
            cardinality: :one,
            modes: [:replace_one],
            operations: [:create, :update, :delete]
          ),
        "ship_to" =>
          composition("parties", "document_id", party.source.columns,
            child_domain: party,
            path_id: "document.ship_to",
            cardinality: :one,
            modes: [:replace_one],
            operations: [:create, :update, :delete]
          )
      }
    )
  end

  defp domain(table, columns, relationships) do
    %{
      schema_version: 1,
      domain_version: "1.0.0",
      domain_fingerprint: "sha256:#{table}-fixture-v1",
      name: table,
      source: %{
        source_table: table,
        primary_key: "id",
        fields: Map.keys(columns),
        columns: columns
      },
      schemas: %{},
      writes:
        %{
          operations: %{
            insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
            update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
          },
          fields: root_write_fields(columns),
          scope: %{tenant: %{required: true, field: "tenant_id"}},
          relationships: relationships
        }
        |> maybe_put_optimistic_lock(columns)
    }
  end

  defp child_domain(table, columns, relationships \\ %{}) do
    %{
      schema_version: 1,
      name: table,
      source: %{
        source_table: table,
        primary_key: "id",
        fields: Map.keys(columns),
        columns: columns
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}},
          delete: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields: root_write_fields(columns),
        scope: %{tenant: %{required: true, field: "tenant_id"}},
        relationships: relationships
      }
    }
  end

  defp composition(table, child_key, columns, opts) do
    child = Keyword.get(opts, :child_domain, child_domain(table, columns))
    cardinality = Keyword.get(opts, :cardinality, :many)
    modes = Keyword.fetch!(opts, :modes)
    operations = Keyword.fetch!(opts, :operations)

    write = %{
      modes: modes,
      create: :create in operations,
      update: :update in operations,
      delete: :delete in operations,
      omission: if(:full_set in modes, do: :delete_missing, else: :unchanged),
      min_items: Keyword.get(opts, :min_items, 0),
      max_items: Keyword.get(opts, :max_items, if(cardinality == :one, do: 1, else: 100)),
      max_mutations: Keyword.get(opts, :max_items, if(cardinality == :one, do: 1, else: 100))
    }

    %{
      ownership: :composition,
      cardinality: cardinality,
      path_id: Keyword.get(opts, :path_id),
      target: table,
      parent_key: "id",
      child_key: child_key,
      identity_fields: ["id"],
      client_identity: "client_id",
      domain: child,
      read: %{allowed: true, default_depth: 1, max_depth: 2, max_rows: 100},
      write: write,
      tenant_scope: %{mode: :recursive},
      capabilities: %{
        read: "#{table}.read",
        create: "#{table}.create",
        update: "#{table}.update",
        delete: "#{table}.delete"
      },
      conflict: %{root_field: "lock_version", child_field: "lock_version"},
      idempotency: %{request_key: true, client_identity: "client_id"},
      offline: %{eligible: Keyword.get(opts, :offline, false)},
      ordering: Keyword.get(opts, :ordering, %{}),
      validation: Keyword.get(opts, :validation, %{}),
      assurance: Keyword.get(opts, :assurance, %{}),
      output: %{identity_mapping: true, stable_error_paths: true}
    }
  end

  defp column(type), do: %{type: type}

  defp root_write_fields(columns) do
    columns
    |> Map.drop(["id", "tenant_id"])
    |> Map.new(fn {field, _spec} -> {field, %{insertable: true, updatable: true}} end)
  end

  defp maybe_put_optimistic_lock(writes, columns) do
    if Map.has_key?(columns, "lock_version") do
      Map.put(writes, :constraints, %{optimistic_lock: %{field: "lock_version"}})
    else
      writes
    end
  end
end
