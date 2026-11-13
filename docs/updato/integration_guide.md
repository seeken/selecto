# Integrating Portable Writes

This guide describes the supported `selecto_updato` architecture. Updato is a
domain-policy and portable-intent package. It does not own a database driver,
SQL compiler, connection pool, application repository, schema module, or ORM
configuration.

## 1. Configure Selecto with a write-capable adapter

The host configures one `%Selecto{}` value in the same way it configures reads.
The selected database adapter decides whether it implements the
`Selecto.DB.WriteAdapter` callbacks. Adapters that do not implement those
callbacks remain read-only.

Updato receives the configured Selecto value at preview or execution time. It
never discovers a repository from application configuration.

## 2. Author the write contract in the domain

Writes fail closed. A readable field is not writable unless its colocated
`write` map (or the equivalent canonical `writes.fields` registry) grants the
relevant operation, and a database constraint discovered at runtime does not
grant policy.

```elixir
source: %{
  columns: %{
    tenant_id: %{type: :integer, write: %{insertable: true, immutable: true}},
    external_id: %{type: :string, write: %{insertable: true, immutable: true}},
    project_id: %{type: :integer, write: %{insertable: true, updatable: true}},
    title: %{type: :string, write: %{insertable: true, updatable: true}},
    state: %{type: :string, write: %{insertable: true, updatable: true}}
  }
},
writes: %{
  operations: %{
    insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
    update: %{enabled: true, require_filter: true},
    upsert: %{
      enabled: true,
      conflict_targets: [[:tenant_id, :external_id]],
      expected_cardinality: {:exactly, 1}
    },
    delete: %{enabled: true, require_filter: true}
  },
  scope: %{
    tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
  },
  constraints: %{
    foreign_keys: %{
      project_id: %{
        source: {:context, :project_id},
        references: %{relation: "projects", field: :id}
      }
    }
  }
}
```

The four executable operation declarations are `insert`, `update`, `upsert`,
and `delete`. Soft deletion is an update to an explicitly writable archival
field. Nested insert and update reuse those operations through an authored
owned-relationship graph; lifecycle callbacks, changesets, bulk builder
variants, and database-specific update expressions are not executable Updato
operations.

### Declare owned nested relationships

Nested values are accepted only for a source association with explicit write
policy, a complete child domain, and a generated ownership key:

```elixir
source: %{
  associations: %{
    line_items: %{
      queryable: :line_items,
      field: :line_items,
      cardinality: :many,
      owner_key: :id,
      related_key: :order_id,
      write: %{
        enabled: true,
        ownership: :owned,
        allowed_ops: [:insert, :update],
        domain: line_item_domain,
        identity_fields: [:id],
        strategy: :sync,
        delete_missing: true
      }
    }
  }
}
```

Normalization projects these colocated declarations into canonical
`writes.fields` and `writes.relationships`. Authors may still use the canonical
registries directly, but a field or relationship must not be declared in both
locations; duplicates fail closed.

Submit ordinary nested maps or lists. Do not include `order_id`; Updato rejects
an attempted override and binds it from the successful parent result. See
[Portable Nested-Write Architecture](nested_write_architecture.md).

## 3. Supply trusted execution context

Tenant ids and context-owned foreign keys must come from authenticated host
context, not a request form. Updato binds those values into assignments and
predicates and rejects conflicting caller values.

```elixir
operation =
  domain
  |> SelectoUpdato.new()
  |> SelectoUpdato.with_tenant(%{tenant_id: current_tenant.id})
  |> SelectoUpdato.insert(%{title: params["title"], state: "open"})

context = %{tenant_id: current_tenant.id, project_id: current_project.id}
```

Pass the same trusted context when previewing and executing:

```elixir
{:ok, preview} = SelectoUpdato.preview(operation, selecto, context: context)
{:ok, result} = SelectoUpdato.execute(operation, selecto, context: context)
```

Preview is explanatory, not authorization and not a transaction reservation.
The host must authorize execute separately, and the adapter must enforce the
same predicate and cardinality atomically.

## 4. Use concrete targets for actions

Domain actions may target a row or a concrete set of selected primary keys.
Selected ids become a parameterized `IN` predicate and derive exact
cardinality. Transition preconditions and tenant scope remain in the mutation
predicate.

```elixir
intent = %{
  action: :archive,
  target: %{ids: [41, 42, 43]},
  inputs: %{reason: "superseded"}
}

{:ok, plan} = SelectoUpdato.plan_domain_action(domain, intent, context: context)
```

If any selected row no longer satisfies the governed predicate, the adapter
must roll the whole mutation back and return `:cardinality_mismatch`.

## 5. Keep application responsibilities outside Updato

The host owns authentication, capability decisions, UI state, API envelopes,
and optional action audit delivery. A host action adapter may coordinate
application-specific collection workflows, but it must not weaken the portable
command's tenant, foreign-key, transition, or cardinality invariants.

The database adapter owns dialect identifiers, placeholders, parameter
encoding, transactions, result normalization, and rollback. Adding a future
write-capable database therefore means implementing the Selecto adapter
contract in that database package; it never means adding a dialect branch to
Updato.

## 6. Query-enforced inserts compare by the verified column type

An insert under a host predicate (domain `required_filters`, a captured
query from `SelectoUpdato.enforce_query/3`) is admitted in process only when
the candidate satisfies the predicate under the column's real type
(query_enforced_scalar v2, certification specification 2.37). Text compares
by its UTF-8 bytes and text ranges are refused; numeric columns compare exact
decimals and refuse candidates the column would round or truncate; every
other type decides only byte-identical operands.

The column type comes from one of these trust levels:

- **verified**: the adapter's optional `Selecto.DB.WriteAdapter.column_catalog/2`
  (PostgreSQL, MySQL, MariaDB and DuckDB implement it), read when an insert's
  candidate is evaluated, at most once per table per write transaction (an
  execute or a `SelectoUpdato.Multi` batch) and never cached across
  transactions. PostgreSQL resolves the relation exactly as the write quotes
  it and resolves domains to their base type and typmod; a domain it cannot
  resolve is reported `base_verified`.
- **host-supplied `:column_metadata`** (`%{table => %{column => %{type:,
  deterministic:}}}` in the execute options) is taken as verified. It is the
  host's statement of the DDL it issued: Updato does not check it, so
  metadata that is wrong (a `text` claim over a `varchar(2)` column, a
  deterministic claim over a case-insensitive collation) fails open. Pass it
  only for tables whose DDL the host owns. A host or adapter may lower a
  column's `trust:` to `:base_verified` or `:unverified`, never raise it.
- **unverified**: a field known only by its declared domain type (no
  callback, standalone `PortableCommand.compile/2`, document-store adapters,
  MSSQL). It decides nothing in process.

A comparison that cannot be decided in process defers to the MySQL/MariaDB
stored-row admission inside the write transaction, or to SQLite's
storage-typed admission; on every other backend the insert is refused with
`query_rule_not_evaluable`. An absent field or a column operand is refused
before any write.

Writes that compile inside the adapter's transaction (nested graphs,
protected record state, protected Multi batches) read the catalog before
that transaction opens, because the pool may hold a single connection. DDL
committed between that read and the write (an `ALTER COLUMN ... TYPE` that
narrows the column) is not seen by the in-process decision; on MySQL and
MariaDB the stored-row re-check still decides, on PostgreSQL the stale type
does. Avoid concurrent DDL on governed tables, or run such writes after it.

## Release checks

Before shipping an integration:

1. validate the domain and action intents;
2. test all four operation previews without changing data;
3. test trusted tenant and foreign-key mismatch rejection;
4. test missing predicates fail closed for update and delete;
5. validate nested relationship ownership, cardinality, identity, and item bounds;
6. run the database adapter conformance suite;
7. prove a graph cardinality or ownership mismatch rolls back root and children;
8. test the host UI/API for both authorized and unavailable actions.

See [Portable Write Architecture](portable_write_architecture.md) for ownership
boundaries and the command flow.
