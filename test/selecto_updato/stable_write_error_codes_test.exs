defmodule SelectoUpdato.StableWriteErrorCodesTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Result}
  alias SelectoUpdato.{Error, PortableCommand}

  defmodule BatchAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Authorization, Batch, Command, Result}

    def name, do: :stable_codes_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_pid) do
      %{
        protocol_version: 1,
        insert: true,
        update: true,
        delete: true,
        transactions: true,
        atomic_batch: true
      }
    end

    def preview_write(_pid, write, _opts), do: {:ok, %{write: write}}

    def execute_write(pid, write, opts) do
      with :ok <- Authorization.require_for(write, opts) do
        send(pid, {:executed, write})

        {:ok,
         Enum.map(write.commands, fn %Command{operation: operation} ->
           %Result{operation: operation, affected_rows: 1}
         end)}
      end
    end
  end

  describe "the contract's stable codes" do
    test "a disabled operation is write_operation_not_enabled" do
      operation =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.delete()

      assert {:error, %Error{type: :write_operation_not_enabled, details: %{operation: :delete}}} =
               PortableCommand.compile(operation)
    end

    test "a declared but non-writable field is write_field_not_writable" do
      operation =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{tenant_id: 8})

      assert {:error,
              %Error{
                type: :write_field_not_writable,
                details: %{field: :tenant_id, operation: :update, reason: :not_writable}
              }} = PortableCommand.compile(operation)
    end

    test "an assignment, filter, or returning field the source lacks is unknown_field" do
      assignment =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{name: "n", tenant_id: 7, ghost: 1})

      assert {:error, %Error{type: :unknown_field, details: %{field: :ghost}}} =
               PortableCommand.compile(assignment)

      filter =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:ghost, 1})
        |> SelectoUpdato.update(%{name: "n"})

      assert {:error,
              %Error{
                type: :unknown_field,
                details: %{code: :undeclared_write_identifier, fields: ["ghost"]}
              }} = PortableCommand.compile(filter)

      returning =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{name: "n", tenant_id: 7})
        |> SelectoUpdato.returning([:ghost])

      assert {:error, %Error{type: :unknown_field}} = PortableCommand.compile(returning)
    end

    test "a nested relationship that is not writable is write_relation_mismatch" do
      domain = put_in(order_domain(), [:writes, :relationships, :items, :writable], false)

      assert {:error, %Error{type: :write_relation_mismatch, details: %{relationship: :items}}} =
               domain
               |> SelectoUpdato.new(tenant: %{tenant_id: 7})
               |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "A"}]})
               |> PortableCommand.compile()
    end

    test "a nested operation the relationship does not allow is write_operation_not_enabled" do
      domain = put_in(order_domain(), [:writes, :relationships, :items, :allowed_ops], [:update])

      assert {:error, %Error{type: :write_operation_not_enabled}} =
               domain
               |> SelectoUpdato.new(tenant: %{tenant_id: 7})
               |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "A"}]})
               |> PortableCommand.compile()
    end
  end

  describe "a NULL foreign key" do
    test "needs no referenced parent row" do
      update =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{project_id: nil, country_code: nil})

      assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(update)
      assert Map.get(metadata, :foreign_key_guards, []) == []

      insert =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, project_id: nil, parent_id: 1, title: "t"})

      assert {:ok, %Command{metadata: %{foreign_key_guards: guards}}, _context} =
               PortableCommand.compile(insert)

      assert Enum.map(guards, & &1.field) == ["parent_id"]
    end
  end

  describe "an atomic multi across domains" do
    test "executes when every operation shares one trusted context" do
      multi =
        SelectoUpdato.multi()
        |> SelectoUpdato.multi_insert(:item, items_domain(), %{name: "new", tenant_id: 7})
        |> SelectoUpdato.multi_insert(:note, notes_domain(), %{body: "hello", tenant_id: 7})

      selecto = %Selecto{adapter: BatchAdapter, connection: self()}

      assert {:ok, %{item: %Result{}, note: %Result{}}} =
               SelectoUpdato.run(multi, selecto, context: %{tenant_id: 7})

      assert_received {:executed,
                       %Batch{
                         commands: [%Command{relation: "items"}, %Command{relation: "notes"}]
                       }}
    end

    test "is refused when the operations' trusted contexts differ" do
      item =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{name: "new"})

      note =
        notes_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 8})
        |> SelectoUpdato.insert(%{body: "hello"})

      multi = %SelectoUpdato.Multi{operations: [item: item, note: note]}
      selecto = %Selecto{adapter: BatchAdapter, connection: self()}

      assert {:error, %Error{type: :tenant_mismatch, details: %{code: :batch_context_conflict}}} =
               SelectoUpdato.run(multi, selecto)

      refute_received {:executed, _write}
    end
  end

  defp items_domain do
    %{
      name: "items",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{tenant_id: %{insertable: true}, name: %{insertable: true, updatable: true}},
        scope: %{tenant: %{required: true, field: :tenant_id}}
      }
    }
  end

  defp notes_domain do
    %{
      name: "notes",
      source: %{
        source_table: "notes",
        primary_key: :id,
        fields: [:id, :tenant_id, :body],
        columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, body: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{tenant_id: %{insertable: true}, body: %{insertable: true}},
        scope: %{tenant: %{required: true, field: :tenant_id}}
      }
    }
  end

  defp order_domain do
    items =
      nested_domain("order_items", [:id, :tenant_id, :order_id, :sku], %{
        sku: %{insertable: true, updatable: true}
      })

    nested_domain("orders", [:id, :tenant_id, :reference], %{
      reference: %{insertable: true, updatable: true}
    })
    |> put_in([:writes, :relationships], %{
      items: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: items,
        child_key: :order_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp nested_domain(relation, fields, write_fields) do
    %{
      name: relation,
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields: Map.merge(%{tenant_id: %{insertable: true, immutable: true}}, write_fields),
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end

  defp tasks_domain do
    %{
      name: "tasks",
      source: %{
        source_table: "tasks",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :project_id, :parent_id, :country_code, :title],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          project_id: %{type: :integer},
          parent_id: %{type: :integer},
          country_code: %{type: :string},
          title: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{
        projects: %{
          source_table: "projects",
          primary_key: :id,
          tenant_field: :tenant_id,
          fields: [:id, :tenant_id, :name],
          columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{
          id: %{insertable: true},
          tenant_id: %{insertable: true},
          project_id: %{insertable: true, updatable: true},
          parent_id: %{insertable: true, updatable: true},
          country_code: %{insertable: true, updatable: true},
          title: %{insertable: true, updatable: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}},
        constraints: %{
          foreign_keys: %{
            project_id: %{source: :input, references: %{relation: "projects", field: :id}},
            parent_id: %{source: :input, references: %{relation: "tasks", field: :id}},
            country_code: %{
              source: :input,
              references: %{relation: "countries", field: :code, tenant_field: false}
            }
          }
        }
      }
    }
  end
end
