defmodule SelectoUpdato.PortableCommandTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.Choices
  alias Selecto.Domain.Choices.Request
  alias Selecto.Write.{Command, Result}
  alias SelectoUpdato.{Operation, PortableCommand}

  test "null-test filters preserve declared fields and trusted tenant scope" do
    for {comparator, operator} <- [{:is_null, :is_null}, {"not_null", :not_null}] do
      operation =
        tenant_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:name, comparator, nil})
        |> SelectoUpdato.update(%{name: "renamed"})

      assert {:ok, command, _} = PortableCommand.compile(operation)

      assert command.predicate ==
               {:and,
                [
                  {operator, {:field, "name"}},
                  {:eq, {:field, "tenant_id"}, {:literal, 7}}
                ]}

      assert {:error, _} =
               PortableCommand.compile(%{operation | filters: [{:name, comparator, "not nil"}]})

      assert {:error, _} =
               PortableCommand.compile(%{operation | filters: [{:undeclared, comparator, nil}]})

      assert {:error, _} =
               PortableCommand.compile(%{operation | filters: [{:tenant_id, comparator, nil}]})
    end
  end

  test "declared text_case normalizes write assignments before adapter dispatch" do
    domain = put_in(tenant_domain(), [:source, :columns, :name, :text_case], :uppercase)

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "mixed Case"})

    assert {:ok, %Command{assignments: [%{field: "name", value: {:literal, "MIXED CASE"}}]}, _} =
             PortableCommand.compile(operation)
  end

  test "values-backed foreign keys reject undeclared assignments after normalization" do
    domain = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :status_id],
        columns: %{id: %{type: :integer}, status_id: %{type: :string, text_case: :uppercase}},
        associations: %{
          status: %{
            queryable: :status,
            owner_key: :status_id,
            related_key: :id,
            cardinality: :one
          }
        }
      },
      schemas: %{
        status: %{
          primary_key: :id,
          fields: [:id, :name],
          columns: %{id: %{type: :string}, name: %{type: :string}},
          values: [%{id: "A", name: "Active"}]
        }
      },
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{status_id: %{insertable: true}}
      }
    }

    valid = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{status_id: "a"})

    assert {:ok, %Command{assignments: [%{value: {:literal, "A"}}]}, _} =
             PortableCommand.compile(valid)

    invalid = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{status_id: "z"})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{code: :write_foreign_key_violation, allowed_values: ["A"]}
            }} = PortableCommand.compile(invalid)
  end

  defmodule RecordingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :recording
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
        write_graph: true,
        committed_effect_sink: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Command{} = command, opts) do
      send(self(), {:portable_write, command, opts})
      {:ok, %Result{operation: command.operation, affected_rows: 1}}
    end
  end

  test "compiles a domain-governed tenant update and delegates to the configured adapter" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}

    operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.filter({:tenant_id, 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:ok, %Result{operation: :update}} = SelectoUpdato.execute(operation, selecto)

    assert_receive {:portable_write, %Command{} = command, opts}
    assert command.relation == "items"
    assert command.expected_cardinality == {:exactly, 1}
    assert Keyword.get(opts, :context)[:tenant_id] == 7
  end

  describe "lesson 47: a trusted engine tenant bounds every write" do
    defp no_scope_domain do
      tenant_domain()
      |> put_in([:source, :tenant_field], :tenant_id)
      |> update_in([:writes], &Map.delete(&1, :scope))
    end

    # tenant_id reads, site_id write scope (lesson 47a).
    defp two_column_domain do
      tenant_domain()
      |> put_in([:source, :fields], [:id, :tenant_id, :site_id, :name])
      |> put_in([:source, :columns, :site_id], %{type: :integer})
      |> put_in([:source, :tenant_field], :tenant_id)
      |> put_in([:writes, :fields, :site_id], %{insertable: true, immutable: true})
      |> put_in([:writes, :scope], %{tenant: %{required: true, field: :site_id}})
    end

    defp recording, do: %Selecto{adapter: RecordingAdapter, connection: :recording}

    defp engine(tenant_id),
      do: %{recording() | tenant: Selecto.Tenant.normalize_context(%{tenant_id: tenant_id})}

    defp written(result) do
      assert {:ok, _} = result
      assert_receive {:portable_write, %Command{} = command, _opts}
      command
    end

    test "update and delete bind the tenant without a write scope", %{} do
      for build <- [
            &SelectoUpdato.update(&1, %{name: "renamed"}),
            &SelectoUpdato.delete/1
          ],
          {operation, target} <- [
            {no_scope_domain()
             |> SelectoUpdato.new()
             |> SelectoUpdato.with_tenant(%{tenant_id: 7}), recording()},
            {SelectoUpdato.new(no_scope_domain()), engine(7)}
          ] do
        command =
          operation
          |> SelectoUpdato.filter({:id, 12})
          |> build.()
          |> SelectoUpdato.execute(target)
          |> written()

        assert command.predicate ==
                 {:and,
                  [
                    {:eq, {:field, "id"}, {:literal, 12}},
                    {:eq, {:field, "tenant_id"}, {:literal, 7}}
                  ]}
      end
    end

    test "a write plan inspects the same engine-tenant binding as execution" do
      assert {:ok, %Command{predicate: predicate}} =
               no_scope_domain()
               |> SelectoUpdato.new()
               |> SelectoUpdato.filter({:id, 12})
               |> SelectoUpdato.update(%{name: "renamed"})
               |> SelectoUpdato.Executor.build_write_plan(engine(7))

      assert predicate ==
               {:and,
                [
                  {:eq, {:field, "id"}, {:literal, 12}},
                  {:eq, {:field, "tenant_id"}, {:literal, 7}}
                ]}
    end

    test "an excluding tenant predicate is refused and an admitting IN set is intersected" do
      base = SelectoUpdato.new(no_scope_domain())

      assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} =
               base
               |> SelectoUpdato.filter({:tenant_id, 8})
               |> SelectoUpdato.update(%{name: "renamed"})
               |> SelectoUpdato.execute(engine(7))

      refute_received {:portable_write, _command, _opts}

      command =
        base
        |> SelectoUpdato.filter({:tenant_id, :in, [7, 8]})
        |> SelectoUpdato.delete()
        |> SelectoUpdato.execute(engine(7))
        |> written()

      assert command.predicate == {:eq, {:field, "tenant_id"}, {:literal, 7}}

      assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} =
               base
               |> SelectoUpdato.filter({:id, 12})
               |> SelectoUpdato.update(%{name: "renamed"})
               |> SelectoUpdato.execute(engine(7), context: %{tenant_id: 8})

      # A Selecto-style IN conjunct that admits the tenant is intersected too.
      command =
        base
        |> SelectoUpdato.filter({:tenant_id, {:in, [7, 8]}})
        |> SelectoUpdato.delete()
        |> SelectoUpdato.execute(engine(7))
        |> written()

      assert command.predicate == {:eq, {:field, "tenant_id"}, {:literal, 7}}
    end

    test "an insert carries the engine tenant and refuses another" do
      command =
        no_scope_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{name: "x"})
        |> SelectoUpdato.execute(engine(7))
        |> written()

      assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments

      for domain <- [no_scope_domain(), two_column_domain()] do
        assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} =
                 domain
                 |> SelectoUpdato.new()
                 |> SelectoUpdato.with_tenant(%{tenant_id: 7})
                 |> SelectoUpdato.insert(%{tenant_id: 8, site_id: 7, name: "x"})
                 |> SelectoUpdato.execute(recording())
      end
    end

    test "an upsert under the engine tenant needs the tenant in its conflict target" do
      upsert = fn targets ->
        no_scope_domain()
        |> put_in([:writes, :operations, :upsert], %{enabled: true, conflict_targets: targets})
        |> SelectoUpdato.new()
        |> SelectoUpdato.upsert(%{name: "new item"})
        |> SelectoUpdato.execute(engine(7))
      end

      assert {:error, %SelectoUpdato.Error{details: %{code: :tenant_conflict_target_missing}}} =
               upsert.([[:name]])

      command = written(upsert.([[:tenant_id, :name]]))
      assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments
    end

    test "a two-column domain binds tenant_id, never the site column, to the engine value" do
      command =
        two_column_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.with_tenant(%{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 12})
        |> SelectoUpdato.update(%{name: "renamed"})
        |> SelectoUpdato.execute(recording())
        |> written()

      assert command.predicate ==
               {:and,
                [
                  {:eq, {:field, "id"}, {:literal, 12}},
                  {:eq, {:field, "tenant_id"}, {:literal, 7}}
                ]}
    end

    test "only a host-scope query pins sites, and a pinned fill skips insertability" do
      pinned_query = fn domain ->
        %Selecto{
          adapter: RecordingAdapter,
          connection: :recording,
          domain: Map.put(domain, :required_filters, []),
          set: %{
            selected: [],
            filtered: [{"site_id", 70}],
            required_filters: [],
            post_retarget_filters: [],
            order_by: [],
            group_by: []
          }
        }
      end

      insert = fn domain, opts ->
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.with_tenant(%{tenant_id: 7})
        |> SelectoUpdato.insert(%{site_id: 70, name: "x"})
        |> SelectoUpdato.enforce_query(pinned_query.(domain), opts)
        # The catalog type a configured target would report for site_id.
        |> SelectoUpdato.execute(recording(),
          column_metadata: %{"items" => %{"site_id" => %{type: "integer"}}}
        )
      end

      # Ordinary query evidence never adds tenant authority.
      assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
               insert.(two_column_domain(), [])

      command = written(insert.(two_column_domain(), host_scope: true))
      assert %{field: "site_id", value: {:literal, 70}} in command.assignments

      # A site filled from a single trusted pin is governed autofill.
      locked = update_in(two_column_domain(), [:writes, :fields], &Map.delete(&1, :site_id))

      command =
        locked
        |> SelectoUpdato.new()
        |> SelectoUpdato.with_tenant(%{tenant_id: 7, required_filters: [{:site_id, 70}]})
        |> SelectoUpdato.insert(%{name: "x"})
        |> SelectoUpdato.execute(recording())
        |> written()

      assert %{field: "site_id", value: {:literal, 70}} in command.assignments

      # A caller-supplied site is checked for insertability even when it
      # equals the pin; only the governed fill skips it.
      assert {:error, %SelectoUpdato.Error{type: :write_field_not_writable}} =
               locked
               |> SelectoUpdato.new()
               |> SelectoUpdato.with_tenant(%{tenant_id: 7, required_filters: [{:site_id, 70}]})
               |> SelectoUpdato.insert(%{name: "x", site_id: 70})
               |> SelectoUpdato.execute(recording())
    end

    test "site writes need a trusted site pin and stay inside it (lesson 47b)" do
      domain =
        put_in(two_column_domain(), [:writes, :fields, :site_id], %{
          insertable: true,
          updatable: true
        })

      write = fn tenant, build ->
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.with_tenant(tenant)
        |> build.()
        |> SelectoUpdato.execute(recording())
      end

      unpinned = %{tenant_id: 7}
      one = %{tenant_id: 7, required_filters: [{:site_id, 70}]}
      two = %{tenant_id: 7, required_filters: [{:site_id, :in, [70, 71]}]}
      insert = &SelectoUpdato.insert(&1, &2)
      relabel = &(&1 |> SelectoUpdato.filter({:id, 12}) |> SelectoUpdato.update(%{site_id: &2}))

      # Unpinned: any write setting the site is refused, even one the caller's
      # own filter "pins"; writes that leave the site alone are unaffected.
      for build <- [
            &insert.(&1, %{site_id: 70, name: "x"}),
            &insert.(&1, %{name: "x"}),
            &relabel.(&1, 70),
            &(&1 |> SelectoUpdato.filter({:site_id, 7}) |> insert.(%{site_id: 7, name: "x"}))
          ] do
        assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
                 write.(unpinned, build)
      end

      refute_received {:portable_write, _command, _opts}

      assert {:ok, _} =
               write.(
                 unpinned,
                 &(&1 |> SelectoUpdato.filter({:id, 12}) |> SelectoUpdato.update(%{name: "r"}))
               )

      assert_receive {:portable_write, _command, _opts}

      # Pinned: the value must lie inside the pin; one pinned site fills an
      # omitted insert value, two do not.
      for {tenant, build} <- [
            {one, &insert.(&1, %{site_id: 7, name: "x"})},
            {two, &relabel.(&1, 7)}
          ] do
        assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} = write.(tenant, build)
      end

      assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
               write.(two, &insert.(&1, %{name: "x"}))

      command = written(write.(one, &insert.(&1, %{name: "x"})))
      assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments
      assert %{field: "site_id", value: {:literal, 70}} in command.assignments

      command = written(write.(two, &relabel.(&1, 71)))
      assert %{field: "site_id", value: {:literal, 71}} in command.assignments
    end
  end

  test "validates and forwards the transaction-local committed-effect sink" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}
    sink = fn _connection, _result, _context -> :ok end

    operation =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:ok, %Result{operation: :update}} =
             SelectoUpdato.execute(operation, selecto, committed_effect_sink: sink)

    assert_receive {:portable_write, %Command{}, opts}
    assert Keyword.fetch!(opts, :committed_effect_sink) == sink

    assert_raise NimbleOptions.ValidationError, fn ->
      SelectoUpdato.execute(operation, selecto, committed_effect_sink: fn -> :ok end)
    end
  end

  test "compile_flat ignores injected contracts and compiles from the operation domain" do
    {:ok, foreign_contract} = Selecto.Domain.WriteContract.compile(tenant_domain())

    # A domain that declares no writes must fail even if a valid contract
    # from another domain is injected via opts.
    operation = %Operation{
      domain: %{
        source: %{
          source_table: "items",
          primary_key: :id,
          fields: [:id],
          columns: %{id: %{type: :integer}},
          associations: %{}
        },
        schemas: %{}
      },
      type: :update,
      changes: %{name: "renamed"},
      filters: [{:id, 12}]
    }

    assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
             PortableCommand.compile_flat(operation, precompiled_contract: foreign_contract)
  end

  test "delegates previews to the configured adapter rather than generating SQL in Updato" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}

    operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:ok, %{command: %Command{operation: :update}}} =
             SelectoUpdato.preview(operation, selecto)
  end

  test "enforces domain-required insert fields before adapter preview or execution" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}

    operation =
      tenant_domain()
      |> put_in([:writes, :fields, :name, :required_on], [:insert])
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{errors: [{["name"], "is required"}]}
            }} = SelectoUpdato.preview(operation, selecto)
  end

  test "canonical required flags refuse missing, null and blank insert fields" do
    domain = put_in(tenant_domain(), [:writes, :fields, :name, :required], true)

    for attrs <- [%{}, %{name: nil}, %{name: "  \t"}] do
      operation =
        domain |> SelectoUpdato.new(tenant: %{tenant_id: 7}) |> SelectoUpdato.insert(attrs)

      assert {:error,
              %SelectoUpdato.Error{
                details: %{code: :missing_required_write_fields, fields: ["name"]}
              }} =
               SelectoUpdato.PortableCommand.compile(operation)
    end

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{name: "valid"})

    assert {:ok, _, _} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "required insert fields include trusted tenant and foreign-key sources" do
    tenant_operation =
      tenant_domain()
      |> put_in([:writes, :fields, :tenant_id, :required], true)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{name: "valid"})

    assert {:ok, _, _} = SelectoUpdato.PortableCommand.compile(tenant_operation)

    foreign_operation =
      foreign_key_domain()
      |> put_in([:writes, :fields, :account_id, :required], true)
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "valid"})

    assert {:ok, _, _} =
             SelectoUpdato.PortableCommand.compile(foreign_operation, context: %{account_id: 6})
  end

  test "normalizes a tenant supplied when constructing an operation" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new(tenant: "tenant-43")
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:ok, %Command{}, %{tenant_id: "tenant-43"}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "allows callers to narrow a domain-owned many cardinality for a concrete target" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :update, :expected_cardinality], :many)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, :in, [12, 13, 14]})
      |> SelectoUpdato.expected_cardinality({:exactly, 3})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:ok, %Command{} = command, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert command.predicate ==
             {:and,
              [
                {:in, {:field, "id"}, [{:literal, 12}, {:literal, 13}, {:literal, 14}]},
                {:eq, {:field, "tenant_id"}, {:literal, 7}}
              ]}

    assert command.expected_cardinality == {:exactly, 3}
  end

  test "rejects duplicate identifiers after atom and string normalization" do
    duplicate_assignments =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{:tenant_id => 7, "tenant_id" => 8, :name => "item"})

    assert {:error, %{details: %{code: :duplicate_assignment_identifier, fields: ["tenant_id"]}}} =
             SelectoUpdato.PortableCommand.compile(duplicate_assignments)

    duplicate_filters =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.filter({"id", 13})
      |> SelectoUpdato.update(%{name: "item"})

    assert {:error, %{details: %{code: :duplicate_filter_identifier, fields: ["id"]}}} =
             SelectoUpdato.PortableCommand.compile(duplicate_filters)

    duplicate_returning =
      tenant_domain()
      |> put_in([:writes, :operations, :update, :returning], :all)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})
      |> SelectoUpdato.returning([:id, "id"])

    assert {:error, %{details: %{code: :duplicate_returning_identifier, fields: ["id"]}}} =
             SelectoUpdato.PortableCommand.compile(duplicate_returning)
  end

  test "preserves repeated same-form filter fields for bounded ranges" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, :gte, 18})
      |> SelectoUpdato.filter({:id, :lt, 65})
      |> SelectoUpdato.update(%{name: "adult item"})

    assert {:ok, %Command{} = command, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert command.predicate ==
             {:and,
              [
                {:gte, {:field, "id"}, {:literal, 18}},
                {:lt, {:field, "id"}, {:literal, 65}},
                {:eq, {:field, "tenant_id"}, {:literal, 7}}
              ]}
  end

  test "rejects every conflicting repeated tenant filter before command dispatch" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:tenant_id, 7})
      |> SelectoUpdato.filter({:tenant_id, 8})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})

    assert {:error, %{type: :tenant_mismatch}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "rejects undeclared filter and returning fields" do
    unknown_filter =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:secret_column, 12})
      |> SelectoUpdato.update(%{name: "item"})

    assert {:error,
            %{
              details: %{
                code: :undeclared_write_identifier,
                identifier_kind: :filter,
                fields: ["secret_column"]
              }
            }} = SelectoUpdato.PortableCommand.compile(unknown_filter)

    unknown_returning =
      tenant_domain()
      |> put_in([:writes, :operations, :update, :returning], :all)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})
      |> SelectoUpdato.returning([:secret_column])

    assert {:error,
            %{
              details: %{
                code: :undeclared_write_identifier,
                identifier_kind: :returning,
                fields: ["secret_column"]
              }
            }} = SelectoUpdato.PortableCommand.compile(unknown_returning)
  end

  test "domain cardinality and returning policy cannot be weakened by raw callers" do
    weakened_cardinality =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})
      |> SelectoUpdato.expected_cardinality(:many)

    assert {:error, %{details: %{code: :expected_cardinality_policy_violation}}} =
             SelectoUpdato.PortableCommand.compile(weakened_cardinality)

    expanded_returning =
      tenant_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})
      |> SelectoUpdato.returning(:all)

    assert {:error, %{details: %{code: :returning_policy_violation}}} =
             SelectoUpdato.PortableCommand.compile(expanded_returning)
  end

  test "callers may narrow domain-owned returning policy to declared fields" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :update, :returning], :all)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "item"})
      |> SelectoUpdato.returning([:id])

    assert {:ok, %Command{returning: ["id"]}, _context} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "explicit bulk counts and declared RETURNING projections respect authored ceilings" do
    bulk_domain = put_in(tenant_domain(), [:writes, :operations, :update, :bulk], true)

    operation =
      bulk_domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:name, "old"})
      |> SelectoUpdato.update(%{name: "new"})
      |> SelectoUpdato.expected_cardinality({:exactly, 2})
      |> SelectoUpdato.returning([:id, :name])

    assert {:ok, %Command{expected_cardinality: {:exactly, 2}, returning: ["id", "name"]}, _} =
             PortableCommand.compile(operation)

    cardinality_ceiling =
      put_in(bulk_domain, [:writes, :operations, :update, :expected_cardinality], {:exactly, 1})

    assert {:error, %{details: %{code: :expected_cardinality_policy_violation}}} =
             PortableCommand.compile(%{operation | domain: cardinality_ceiling})

    returning_ceiling = put_in(bulk_domain, [:writes, :operations, :update, :returning], :none)

    assert {:error, %{details: %{code: :returning_policy_violation}}} =
             PortableCommand.compile(%{operation | domain: returning_ceiling})
  end

  test "rejects a Repo-like target before any legacy execution path can run" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.insert(%{name: "new item"})

    assert {:error, %{type: :configured_selecto_required}} =
             SelectoUpdato.execute(operation, :not_a_selecto_value)
  end

  test "rejects tenant-scoped updates without trusted context and mismatched caller filters" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:error, %{type: :missing_tenant_scope}} =
             SelectoUpdato.PortableCommand.compile(operation)

    mismatched_operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.filter({:tenant_id, 8})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{name: "renamed"})

    assert {:error, %{type: :tenant_mismatch}} =
             SelectoUpdato.PortableCommand.compile(mismatched_operation)
  end

  test "fails before execution if a caller tries to write an undeclared field" do
    operation =
      tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.filter({:tenant_id, 7})
      |> SelectoUpdato.filter({:id, 12})
      |> SelectoUpdato.update(%{dangerous: true})

    assert {:error, %{type: :unknown_field}} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "derives a sole domain-owned upsert conflict target and update set" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :upsert], %{
        enabled: true,
        conflict_targets: [[:tenant_id]]
      })
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.upsert(%{tenant_id: 7, name: "new item"})

    assert {:ok,
            %Command{
              operation: :upsert,
              metadata: %{
                conflict_target: [:tenant_id],
                upsert_update_fields: ["name"]
              }
            } = command, _context} = SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(command.assignments, &(&1.field == "tenant_id"))
  end

  test "rejects tenant-scoped upserts whose conflict target can select another tenant" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :upsert], %{
        enabled: true,
        conflict_targets: [[:id]]
      })
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.upsert(%{id: 12, tenant_id: 7, name: "new item"})

    assert {:error,
            %SelectoUpdato.Error{
              type: :invalid_operation,
              details: %{code: :tenant_conflict_target_missing, tenant_field: :tenant_id}
            }} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "rejects upsert when the domain does not declare a conflict target" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :upsert], %{enabled: true})
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.upsert(%{tenant_id: 7, name: "new item"})
      |> SelectoUpdato.conflict_target([:tenant_id])

    assert {:error, %{type: :invalid_operation, details: %{required: required}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert required == [:writes, :operations, :upsert, :conflict_targets]
  end

  test "rejects a caller-selected upsert conflict target outside domain policy" do
    operation =
      tenant_domain()
      |> put_in([:writes, :operations, :upsert], %{
        enabled: true,
        conflict_targets: [[:tenant_id]]
      })
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7})
      |> SelectoUpdato.upsert(%{tenant_id: 7, name: "new item"})
      |> SelectoUpdato.conflict_target([:name])

    assert {:error, %{type: :invalid_operation, details: %{conflict_target: [:name]}}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "binds a domain-owned foreign key from trusted execution context and carries a portable reference guard" do
    operation =
      foreign_key_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "new item"})

    assert {:ok, %Command{} = command, %{account_id: 42}} =
             SelectoUpdato.PortableCommand.compile(operation, context: %{account_id: 42})

    assert %{field: "account_id", relation: "accounts", target_field: "id"} =
             hd(command.metadata.foreign_key_guards)

    assert %{field: "account_id", value: {:literal, 42}} =
             Enum.find(command.assignments, &(&1.field == "account_id"))
  end

  test "rejects missing or caller-overridden trusted foreign-key values" do
    operation =
      foreign_key_domain() |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: "new item"})

    assert {:error, %{type: :missing_foreign_key_context}} =
             SelectoUpdato.PortableCommand.compile(operation)

    overridden =
      foreign_key_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "new item", account_id: 7})

    assert {:error, %{type: :foreign_key_source_mismatch}} =
             SelectoUpdato.PortableCommand.compile(overridden, context: %{account_id: 42})
  end

  test "accepts portable cardinality and foreign-key constraint metadata" do
    domain =
      foreign_key_domain()
      |> put_in([:writes, :operations, :insert, :expected_cardinality], {:exactly, 1})

    assert :ok = SelectoUpdato.validate_domain(domain)
  end

  test "rejects invalid portable cardinality metadata" do
    domain =
      foreign_key_domain()
      |> put_in([:writes, :operations, :insert, :expected_cardinality], {:exactly, 0})

    assert {:error, %{type: :invalid_operation, details: %{errors: errors}}} =
             SelectoUpdato.validate_domain(domain)

    assert {[:writes, :operations, :insert, :expected_cardinality], "is invalid"} in errors
  end

  test "validates choice membership with portable equality-filter context" do
    test_pid = self()

    resolver = fn %Request{} = request ->
      send(test_pid, {:choice_request, request})
      Choices.valid(:fixture_member)
    end

    operation =
      choice_domain()
      |> SelectoUpdato.new(choice_source_membership_resolver: resolver)
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{assignee_id: 7})

    assert {:ok, %Command{}, _context} = SelectoUpdato.PortableCommand.compile(operation)
    assert_receive {:choice_request, request}
    assert request.record.id == 42
    assert request.record.assignee_id == 7
    assert request.metadata == %{surface: :updato, operation: :update}
  end

  test "fails closed when a choice-backed write has no membership resolver" do
    operation =
      choice_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{assignee_id: 7})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{
                code: :choice_membership_resolver_required,
                fields: ["assignee_id"]
              }
            }} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "choice membership resolver receives trusted tenant scope and rejects cross-tenant values" do
    test_pid = self()

    resolver = fn %Request{} = request ->
      send(test_pid, {:tenant_choice_request, request})

      if request.tenant == 7 and request.filters == [{:tenant_id, 7}] and request.value == 7 do
        Choices.valid(:tenant_member)
      else
        Choices.invalid(:outside_tenant)
      end
    end

    operation =
      choice_domain()
      |> SelectoUpdato.new(
        tenant: %{tenant_id: 7},
        choice_source_filters: [{:tenant_id, 7}],
        choice_source_membership_resolver: resolver
      )
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{assignee_id: 7})

    assert {:ok, %Command{}, _context} = SelectoUpdato.PortableCommand.compile(operation)
    assert_receive {:tenant_choice_request, %{tenant: 7, filters: [{:tenant_id, 7}]}}

    cross_tenant = %{operation | changes: %{assignee_id: 8}}

    assert {:error, %SelectoUpdato.Error{type: :validation}} =
             SelectoUpdato.PortableCommand.compile(cross_tenant)

    assert_receive {:tenant_choice_request, %{value: 8}}
  end

  defp tenant_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          delete: %{enabled: true}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{insertable: true, updatable: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}}
      }
    }
  end

  defp foreign_key_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :account_id, :name],
        columns: %{id: %{type: :integer}, account_id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{account_id: %{insertable: true, immutable: true}, name: %{insertable: true}},
        constraints: %{
          foreign_keys: %{
            account_id: %{
              source: {:context, :account_id},
              references: %{relation: "accounts", field: :id},
              required: true
            }
          }
        }
      }
    }
  end

  defp choice_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :assignee_id],
        columns: %{
          id: %{type: :integer},
          assignee_id: %{type: :integer, choice_source: :assignees}
        },
        associations: %{}
      },
      schemas: %{},
      choice_sources: %{
        assignees: %{
          domain: :assignees,
          value_field: :id,
          label_field: :name
        }
      },
      writes: %{
        operations: %{update: %{enabled: true}},
        fields: %{assignee_id: %{updatable: true}}
      }
    }
  end
end
