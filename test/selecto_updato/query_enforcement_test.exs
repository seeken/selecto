defmodule SelectoUpdato.QueryEnforcementTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.Command
  alias SelectoUpdato.{ActionAuthorization, Error, PortableCommand}

  defmodule SQLiteAdapter do
    def name, do: :sqlite
  end

  @domain %{
    name: "Items",
    source: %{
      source_table: "items",
      primary_key: :id,
      fields: [:id, :tenant_id, :name, :status, :priority],
      columns: %{
        id: %{type: :integer, write: %{server_managed: true}},
        tenant_id: %{type: :integer, write: %{insertable: true, immutable: true}},
        name: %{type: :string, write: %{insertable: true, updatable: true}},
        status: %{type: :string, write: %{insertable: true, updatable: true}},
        priority: %{type: :integer, write: %{insertable: true, updatable: true}}
      },
      associations: %{}
    },
    schemas: %{},
    writes: %{
      operations: %{
        insert: %{enabled: true},
        update: %{enabled: true},
        delete: %{enabled: true}
      }
    }
  }

  # The catalog types a configured PostgreSQL target reports (read by the
  # executor through SelectoUpdato.ColumnCatalog). Without them a field is
  # known only by its declared domain type, which is unverified.
  @catalog %{
    "items" => %{
      "id" => %{type: "integer", deterministic: true},
      "tenant_id" => %{type: "integer", deterministic: true},
      "name" => %{type: "text", deterministic: true},
      "status" => %{type: "text", deterministic: true},
      "priority" => %{type: "integer", deterministic: true}
    }
  }

  defp verified(opts \\ []), do: Keyword.put(opts, :column_metadata, @catalog)

  test "an update atomically reuses the predicates from the query that selected the row" do
    eligibility_query =
      query([
        {:id, 42},
        {:and,
         [
           {:or, [{:status, "active"}, {:status, "planned"}]},
           {:not, {:status, "archived"}}
         ]}
      ])

    operation =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(eligibility_query)

    assert {:ok, %Command{} = command, _context} = PortableCommand.compile(operation)

    assert command.predicate ==
             {:and,
              [
                {:eq, {:field, "id"}, {:literal, 42}},
                {:and,
                 [
                   {:or,
                    [
                      {:eq, {:field, "status"}, {:literal, "active"}},
                      {:eq, {:field, "status"}, {:literal, "planned"}}
                    ]},
                   {:not, {:eq, {:field, "status"}, {:literal, "archived"}}}
                 ]}
              ]}

    assert command.metadata.query_enforcement.source.relation == "items"
    assert is_binary(command.metadata.query_enforcement.predicate_fingerprint)
  end

  test "insert candidates must satisfy the query rule" do
    eligibility_query = query([{:status, "planned"}, {:priority, {:lte, 3}}])

    matching =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "eligible", status: "planned", priority: 2})
      |> SelectoUpdato.enforce_query(eligibility_query)

    assert {:ok, %Command{operation: :insert, predicate: nil}, _context} =
             PortableCommand.compile(matching, verified())

    ineligible =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "ineligible", status: "archived", priority: 2})
      |> SelectoUpdato.enforce_query(eligibility_query)

    assert {:error, %Error{type: :query_enforcement, details: %{code: :query_rule_violation}}} =
             PortableCommand.compile(ineligible, verified())

    # Declared domain types alone are unverified: nothing is decided in
    # process, and without verified storage the insert is refused.
    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             PortableCommand.compile(matching)
  end

  test "SQLite insert admission preserves the complete guard for storage-native evaluation" do
    eligibility_query = %{query([{:priority, {:lt, "16"}}]) | adapter: SQLiteAdapter}

    operation =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:status, "planned"})
      |> SelectoUpdato.insert(%{name: "candidate", status: "planned", priority: "0x10"})
      |> SelectoUpdato.enforce_query(eligibility_query)

    # Compilation cannot replace SQLite affinity checks with a BEAM comparison.
    # The adapter must explicitly advertise the admission port before execution.
    assert {:ok, %Command{} = command, _context} = PortableCommand.compile(operation)
    assert :typed_insert_admission in command.required_capabilities
    assert command.predicate == nil

    assert command.metadata.insert_admission == %{
             storage_backend: :sqlite,
             predicate:
               {:and,
                [
                  {:eq, {:field, "status"}, {:literal, "planned"}},
                  {:lt, {:field, "priority"}, {:literal, "16"}}
                ]}
           }

    assert command.metadata.field_types.priority == :integer
  end

  test "insert enforcement fails closed when the candidate omits a predicate field" do
    operation =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "unknown status"})
      |> SelectoUpdato.enforce_query(query([{:status, "planned"}]))

    assert {:error,
            %Error{
              type: :query_enforcement,
              details: %{
                code: :query_rule_not_evaluable,
                field: "status",
                reason: :missing_candidate_value
              }
            }} = PortableCommand.compile(operation)
  end

  test "insert evaluation preserves SQL null semantics through boolean negation" do
    operation =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "null status", status: nil})
      |> SelectoUpdato.enforce_query(query([{:not, {:status, "archived"}}]))

    assert {:error, %Error{type: :query_enforcement, details: %{code: :query_rule_violation}}} =
             PortableCommand.compile(operation)
  end

  test "query enforcement rejects another source and joined-field predicates" do
    other_domain = put_in(@domain, [:source, :source_table], "other_items")

    mismatched =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(query([{:id, 1}], other_domain))

    assert {:error, %Error{type: :query_enforcement, details: %{code: :query_source_mismatch}}} =
             PortableCommand.compile(mismatched)

    joined_field =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(query([{"owner.status", "active"}]))

    assert {:error,
            %Error{
              type: :query_enforcement,
              details: %{code: :query_rule_unsupported_field, fields: ["owner.status"]}
            }} = PortableCommand.compile(joined_field)
  end

  test "query predicates do not replace the trusted tenant write scope" do
    tenant_domain =
      put_in(@domain, [:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})

    operation =
      tenant_domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(query([{:id, 1}, {:tenant_id, 7}], tenant_domain))

    assert {:error, %Error{type: :missing_tenant_scope}} = PortableCommand.compile(operation)
  end

  test "an attached engine tenant is enforced with the query, applied or not" do
    # Lesson 43: a trusted engine tenant bounds every query-scoped write; an
    # unapplied tenant must not be dropped from the captured predicate.
    domain = put_in(@domain, [:source, :tenant_field], :tenant_id)
    attached = Selecto.with_tenant(query([{:name, "x"}], domain), %{tenant_id: 7})

    for eligibility <- [attached, Selecto.Tenant.apply_tenant_scope(attached)] do
      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.update(%{name: "renamed"})
        |> SelectoUpdato.enforce_query(eligibility)

      assert {:ok, %Command{predicate: predicate}, _context} = PortableCommand.compile(operation)
      assert inspect(predicate) =~ ~s({:eq, {:field, "tenant_id"}, {:literal, 7}})
    end
  end

  test "an enforced query must be a supported, non-empty root predicate" do
    empty =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(query([]))

    assert {:error,
            %Error{
              type: :query_enforcement,
              details: %{code: :query_enforcement_requires_filter}
            }} = PortableCommand.compile(empty)

    unsupported =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})
      |> SelectoUpdato.enforce_query(query([{:name, {:like, "%unsafe%"}}]))

    assert {:error,
            %Error{
              type: :query_enforcement,
              details: %{code: :query_rule_unsupported_predicate}
            }} = PortableCommand.compile(unsupported)
  end

  test "query evidence is covered by action authorization fingerprints" do
    base =
      @domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "renamed"})

    enforced = SelectoUpdato.enforce_query(base, query([{:id, 42}, {:status, "active"}]))

    refute ActionAuthorization.operation_fingerprint(base) ==
             ActionAuthorization.operation_fingerprint(enforced)
  end

  test "domain required filters constrain direct updates and deletes without query capture" do
    domain = Map.put(@domain, :required_filters, [{:status, "planned"}])

    for type <- [:update, :delete] do
      operation = domain |> SelectoUpdato.new() |> SelectoUpdato.filter({:id, 42})

      operation =
        if type == :update,
          do: SelectoUpdato.update(operation, %{name: "changed"}),
          else: SelectoUpdato.delete(operation)

      assert {:ok, command, _} = PortableCommand.compile(operation)

      assert command.predicate ==
               {:and,
                [
                  {:eq, {:field, "id"}, {:literal, 42}},
                  {:eq, {:field, "status"}, {:literal, "planned"}}
                ]}
    end
  end

  test "required and captured predicates both constrain the write" do
    domain = Map.put(@domain, :required_filters, [{:status, "planned"}])

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "changed"})
      |> SelectoUpdato.enforce_query(query([{:priority, {:lte, 3}}], domain))

    assert {:ok, command, _} = PortableCommand.compile(operation)

    assert command.predicate ==
             {:and,
              [
                {:eq, {:field, "status"}, {:literal, "planned"}},
                {:lte, {:field, "priority"}, {:literal, 3}}
              ]}
  end

  test "direct required-filter insert admission uses the configured storage backend" do
    domain = Map.put(@domain, :required_filters, [{:status, "planned"}])
    operation = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{status: "other"})

    assert {:error, %Error{details: %{code: :query_rule_violation}}} =
             PortableCommand.compile(operation, verified())

    assert {:ok, command, _} = PortableCommand.compile(operation, storage_backend: :sqlite)
    assert :typed_insert_admission in command.required_capabilities

    assert command.metadata.insert_admission.predicate ==
             {:eq, {:field, "status"}, {:literal, "planned"}}
  end

  test "insert candidates compare by the column's verified type (query_enforced_scalar v2)" do
    domain = Map.put(@domain, :required_filters, [{:priority, {:lt, "16"}}])

    insert = fn priority, opts ->
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{status: "planned", priority: priority})
      |> PortableCommand.compile(opts)
    end

    # "2" < "16" as integers, though "2" > "16" as text.
    assert {:ok, _command, _context} = insert.("2", verified())
    assert {:error, %Error{details: %{code: :query_rule_violation}}} = insert.("20", verified())

    for unparsable <- ["NaN", "Infinity", "abc", "0x10", "2.5"] do
      assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
               insert.(unparsable, verified()),
             unparsable
    end

    # On MySQL and MariaDB a comparison undecidable in process defers to the
    # stored-row re-read inside the write transaction.
    for backend <- [:mysql, :mariadb] do
      assert {:ok, command, _} = insert.("abc", storage_backend: backend)
      assert command.metadata.insert_admission.storage_backend == backend
    end
  end

  test "text compares by bytes, refuses ranges, and never reads numbers" do
    insert = fn filter, status ->
      @domain
      |> Map.put(:required_filters, [filter])
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{status: status, priority: 1})
      |> PortableCommand.compile(verified())
      |> case do
        {:ok, _command, _context} -> :accept
        {:error, %Error{details: %{code: code}}} -> code
      end
    end

    for operator <- ["!=", "<>", :!=] do
      assert insert.({"status", {operator, "closed"}}, "planned") == :accept
      assert insert.({"status", {operator, "planned"}}, "planned") == :query_rule_violation
    end

    for spelling <- ["1e1", "010", " 10", "+10", "10.0", "10 "],
        do: assert(insert.({"status", "10"}, spelling) == :query_rule_violation, spelling)

    assert insert.({"status", "10"}, "10") == :accept
    assert insert.({"status", {:in, ["10"]}}, "010") == :query_rule_violation
    assert insert.({"status", {">=", "t"}}, "u") == :query_rule_not_evaluable
    assert insert.({"priority", {">=", 1}}, "planned") == :accept

    assert insert.({"status", {"~", "planned"}}, "planned") == :query_rule_unsupported_predicate
    assert insert.({"status", {"=", {:ref, "id"}}}, "planned") == :query_rule_not_evaluable
    assert insert.({"status", {:ref, "id"}}, "planned") == :query_rule_not_evaluable

    for filter <- [{:in, [{:ref, "id"}]}, {:not_in, [{:ref, "id"}]}, [{:ref, "id"}]] do
      assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
               SelectoUpdato.QueryEnforcement.compile_scope_filters([{"status", filter}])
    end
  end

  test "identity types decide only byte-identical operands; temporals and floats included" do
    catalog =
      @catalog
      |> put_in(["items", "due"], %{type: "date", deterministic: true})
      |> put_in(["items", "at"], %{type: "timestamp without time zone", deterministic: true})
      |> put_in(["items", "at0"], %{type: "timestamp(0) without time zone", deterministic: true})
      |> put_in(["items", "active"], %{type: "boolean", deterministic: true})

    temporal =
      @domain
      |> put_in([:source, :fields], [
        :id,
        :tenant_id,
        :name,
        :status,
        :priority,
        :due,
        :at,
        :at0,
        :active
      ])
      |> put_in([:source, :columns, :due], %{type: :date, write: %{insertable: true}})
      |> put_in([:source, :columns, :at], %{type: :naive_datetime, write: %{insertable: true}})
      |> put_in([:source, :columns, :at0], %{type: :naive_datetime, write: %{insertable: true}})
      |> put_in([:source, :columns, :active], %{type: :boolean, write: %{insertable: true}})

    insert = fn filter, candidate ->
      temporal
      |> Map.put(:required_filters, [filter])
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(Map.put(candidate, :status, "planned"))
      |> PortableCommand.compile(column_metadata: catalog)
      |> case do
        {:ok, _command, _context} -> :accept
        {:error, %Error{details: %{code: code}}} -> code
      end
    end

    assert insert.({:at, "2024-01-01 10:00:00"}, %{at: "2024-01-01 10:00:00"}) == :accept

    assert insert.({:at, {"!=", "2024-01-01 10:00:00"}}, %{at: "2024-01-01T10:00:00"}) ==
             :query_rule_not_evaluable

    assert insert.({:at0, {"!=", "2024-01-01 10:00:00"}}, %{at0: "2024-01-01 10:00:00.4"}) ==
             :query_rule_not_evaluable

    assert insert.({:due, {:gt, "2024-01-10"}}, %{due: "2024-1-5"}) == :query_rule_not_evaluable
    assert insert.({:due, "2024-01-10"}, %{due: "now"}) == :query_rule_not_evaluable
    assert insert.({:active, {"!=", "true"}}, %{active: "t"}) == :query_rule_not_evaluable
    assert insert.({:active, "true"}, %{active: true}) == :accept

    # A native temporal or float is bound by the driver's conversion, which
    # cannot be reproduced as text: refused in process.
    assert insert.({:at, "2024-01-01 10:00:00"}, %{at: ~N[2024-01-01 10:00:00]}) ==
             :query_rule_not_evaluable
  end

  test "catalog typmods and collations refuse candidates the column stores differently" do
    # The catalog types SelectoDBPostgreSQL.Adapter.column_catalog/2 reports
    # (query_enforced_scalar_v2_migration.md live checks 3, 4, 5, 9, 10, 11).
    domain = fn columns, required ->
      %{
        name: "Live",
        source: %{
          source_table: "live",
          primary_key: :id,
          fields: [:id | Keyword.keys(columns)],
          columns:
            Map.new([{:id, :integer} | columns], fn {name, type} ->
              {name, %{type: type, write: %{insertable: true}}}
            end),
          associations: %{}
        },
        schemas: %{},
        required_filters: required,
        writes: %{operations: %{insert: %{enabled: true}}}
      }
    end

    insert = fn columns, catalog, required, attrs ->
      columns
      |> domain.(required)
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(Map.put(attrs, :id, 1))
      |> PortableCommand.compile(column_metadata: %{"live" => catalog})
      |> case do
        {:ok, _command, _context} -> :accept
        {:error, %Error{details: %{code: code}}} -> code
      end
    end

    vc2 = %{"org_key" => %{type: "character varying(2)", deterministic: true}}
    text = [org_key: :string]

    assert insert.(text, vc2, [{"org_key", {"!=", "t1"}}], %{org_key: "t1 "}) ==
             :query_rule_not_evaluable

    assert insert.(text, vc2, [{"org_key", {:not_in, ["t1"]}}], %{org_key: "t1 "}) ==
             :query_rule_not_evaluable

    assert insert.(text, vc2, [{"org_key", "t1"}], %{org_key: "t1"}) == :accept

    price = %{"price" => %{type: "numeric(10,2)", deterministic: true}}
    amount = %{"amount" => %{type: "numeric(20,3)", deterministic: true}}

    assert insert.([price: :decimal], price, [{"price", {:gt, 0}}], %{price: Decimal.new("0.004")}) ==
             :query_rule_not_evaluable

    assert insert.([price: :decimal], price, [{"price", {:gt, 0}}], %{price: Decimal.new("0.01")}) ==
             :accept

    assert insert.([amount: :decimal], amount, [{"amount", {"!=", 1}}], %{amount: "1.0004"}) ==
             :query_rule_not_evaluable

    for filter <- [{"amount", {:gt, 1}}, {"amount", {:not_in, [1]}}],
        do:
          assert(
            insert.([amount: :decimal], amount, [filter], %{amount: "0.9996"}) ==
              :query_rule_not_evaluable
          )

    # Nondeterministic collations, whatever their name (ci, ci_bin).
    ci = %{"org_key" => %{type: "text", deterministic: false}}

    assert insert.(text, ci, [{"org_key", {"!=", "t1"}}], %{org_key: "T1"}) ==
             :query_rule_not_evaluable

    assert insert.(text, ci, [{"org_key", "t1"}], %{org_key: "t1"}) == :accept

    # A declared decimal over DECIMAL(12,2): the catalog scale decides.
    dec12 = %{"amount" => %{type: "numeric(12,2)", deterministic: true}}

    assert insert.([amount: :decimal], dec12, [{"amount", {:lt, 16}}], %{amount: "15.999"}) ==
             :query_rule_not_evaluable

    # An integer declared over a text column: the catalog type decides.
    over_text = %{"org_key" => %{type: "text", deterministic: true}}

    assert insert.([org_key: :integer], over_text, [{"org_key", "10"}], %{org_key: "010"}) ==
             :query_rule_violation

    # An adapter that could not resolve a domain reports it base_verified:
    # nothing but identity-safe decisions, and a domain name decides nothing.
    unresolved = %{
      "org_key" => %{type: "org_key_domain", deterministic: true, trust: :base_verified}
    }

    assert insert.(text, unresolved, [{"org_key", "t1"}], %{org_key: "t1"}) ==
             :query_rule_not_evaluable

    # A host or adapter can lower trust but never raise it above verified.
    lowered = %{"org_key" => %{type: "text", deterministic: true, trust: :unverified}}

    assert insert.(text, lowered, [{"org_key", "t1"}], %{org_key: "t1"}) ==
             :query_rule_not_evaluable

    # Without catalog metadata the declared integer is unverified: refused.
    assert insert.([org_key: :integer], %{}, [{"org_key", "10"}], %{org_key: "010"}) ==
             :query_rule_not_evaluable
  end

  test "host :column_metadata keys and trust values normalise; anything unrecognised is unverified" do
    domain = Map.put(@domain, :required_filters, [{:status, "t1"}])

    insert = fn metadata, status ->
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{status: status})
      |> PortableCommand.compile(column_metadata: metadata)
      |> case do
        {:ok, _command, _context} -> :accept
        {:error, %Error{details: %{code: code}}} -> code
      end
    end

    column = &%{"items" => %{"status" => &1}}

    # Documented forms: atom or string keys and trust values.
    for info <- [
          %{type: "text"},
          %{"type" => "text"},
          %{type: "text", trust: :verified},
          %{"type" => "text", "trust" => "verified"},
          %{"type" => "text", "deterministic" => "true"}
        ] do
      assert insert.(column.(info), "t1") == :accept, inspect(info)
      assert insert.(column.(info), "T1") == :query_rule_violation, inspect(info)
    end

    assert insert.(%{items: %{status: %{type: "text"}}}, "T1") == :query_rule_violation

    # Lowered trust, as a string or an atom, decides nothing for text.
    for trust <- [:unverified, "unverified"],
        do:
          assert(
            insert.(column.(%{type: "text", trust: trust}), "t1") == :query_rule_not_evaluable
          )

    # base_verified text still decides byte-identical operands only.
    for trust <- [:base_verified, "base_verified"] do
      assert insert.(column.(%{"type" => "text", "trust" => trust}), "t1") == :accept

      assert insert.(column.(%{"type" => "text", "trust" => trust}), "T1") ==
               :query_rule_not_evaluable
    end

    # Unrecognised trust, malformed or untyped info: unverified, never a crash.
    for info <- [
          %{type: "text", trust: "trusted"},
          %{type: "text", trust: :sure},
          %{type: "text", trust: 1},
          %{"trust" => "verified"},
          %{type: :text},
          %{type: ""},
          "text",
          nil,
          [type: "text"]
        ],
        do: assert(insert.(column.(info), "t1") == :query_rule_not_evaluable, inspect(info))

    # A table entry that is not a map provides no columns.
    assert insert.(%{"items" => "text"}, "t1") == :query_rule_not_evaluable

    # An unrecognised determinism value is nondeterministic (identity).
    assert insert.(column.(%{type: "text", deterministic: "maybe"}), "T1") ==
             :query_rule_not_evaluable
  end

  test "MySQL-family insert admission carries one primary-key column or refuses" do
    domain = Map.put(@domain, :required_filters, [{:status, "planned"}])

    insert = fn domain ->
      domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{status: "planned"})
    end

    for backend <- [:mysql, :mariadb] do
      # The portable check still runs first and refuses what it decides.
      catalog = %{"items" => %{"status" => %{type: "varchar(20) collate utf8mb4_bin"}}}

      assert {:error, %Error{details: %{code: :query_rule_violation}}} =
               domain
               |> SelectoUpdato.new()
               |> SelectoUpdato.insert(%{status: "other"})
               |> PortableCommand.compile(storage_backend: backend, column_metadata: catalog)

      assert {:ok, command, _} =
               PortableCommand.compile(insert.(domain), storage_backend: backend)

      assert command.metadata.insert_admission.storage_backend == backend
      assert command.metadata.insert_admission.primary_key == "id"
      assert :typed_insert_admission in command.required_capabilities

      # A composite key cannot name one stored row: a typed refusal, never a
      # concatenated column name or a crash.
      composite = put_in(domain, [:source, :primary_key], [:tenant_id, :id])

      assert {:error,
              %Error{type: :query_enforcement, details: %{code: :query_rule_not_evaluable}}} =
               PortableCommand.compile(insert.(composite), storage_backend: backend)

      single = put_in(domain, [:source, :primary_key], [:id])

      assert {:ok, command, _} =
               PortableCommand.compile(insert.(single), storage_backend: backend)

      assert command.metadata.insert_admission.primary_key == "id"
    end
  end

  test "association and malformed required predicates fail closed on every operation" do
    for filter <- [{"owner.status", "active"}, {:status, {:like, "%unsafe%"}}],
        type <- [:insert, :update, :delete, :upsert] do
      domain =
        @domain
        |> with_owner()
        |> Map.put(:required_filters, [filter])
        |> put_in([:writes, :operations, :upsert], %{enabled: true, conflict_targets: [[:id]]})

      operation = SelectoUpdato.new(domain)

      operation =
        case type do
          :insert -> SelectoUpdato.insert(operation, %{name: "changed"})
          :update -> SelectoUpdato.update(operation, %{name: "changed"})
          :delete -> SelectoUpdato.delete(operation)
          :upsert -> SelectoUpdato.upsert(operation, %{name: "changed"})
        end

      assert {:error, %Error{}} = PortableCommand.compile(operation)
    end
  end

  test "required predicates explicitly refuse upsert before dispatch" do
    domain =
      @domain
      |> Map.put(:required_filters, [{:status, "planned"}])
      |> put_in([:writes, :operations, :upsert], %{enabled: true, conflict_targets: [[:id]]})

    operation = domain |> SelectoUpdato.new() |> SelectoUpdato.upsert(%{status: "other"})

    assert {:error, %Error{details: %{code: :query_enforcement_unsupported_operation}}} =
             PortableCommand.compile(operation)
  end

  defp with_owner(domain) do
    domain
    |> put_in([:source, :associations], %{
      owner: %{queryable: :owner, owner_key: :id, related_key: :id}
    })
    |> Map.put(:schemas, %{
      owner: %{
        source_table: "owners",
        primary_key: :id,
        fields: [:id, :status],
        columns: %{id: %{type: :integer}, status: %{type: :string}},
        associations: %{}
      }
    })
  end

  defp query(filters, domain \\ @domain) do
    %Selecto{
      domain: domain,
      set: %{
        selected: [],
        filtered: filters,
        required_filters: [],
        post_retarget_filters: [],
        order_by: [],
        group_by: [],
        limit: 1,
        offset: 0,
        applied_query_library: %{
          segments: ["eligible_items"],
          projection: "item_detail",
          projections: ["item_detail"],
          ordering: nil,
          views: []
        }
      }
    }
  end
end
