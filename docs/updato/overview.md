# SelectoUpdato

SelectoUpdato includes bounded formal-verification suites for write scope,
action planning, capability fail-closed behavior, authorization lifecycle
traces, tenant non-interference, and atomic Multi composition. Run
`mix selecto_updato.verify`; see
[`docs/formal_verification.md`](formal_verification.md) for the precise
proof boundary and JSON artifact support.

See [`docs/portable_write_architecture.md`](portable_write_architecture.md)
for package ownership, command flow, and the bulk-write safety boundary.
See [`docs/nested_write_architecture.md`](nested_write_architecture.md)
for the portable command-tree contract and owned-set synchronization semantics.
See [`docs/integration_guide.md`](integration_guide.md) for the supported
domain and host integration path.
See [`docs/document_actions.md`](document_actions.md) for the approved
document release and authorized `reserve_part` action example.
See [`integration/required_scope/README.md`](integration/required_scope/README.md)
for opt-in native PostgreSQL required-predicate graph/action regressions.
See [`integration/broad_writes/README.md`](integration/broad_writes/README.md)
for native broad-write counts, public bulk gates and late atomic-batch rollback.

> Alpha software. Write-path APIs are still evolving.

`selecto_updato` adds write operations to Selecto domains.

Use it when you want Selecto-style domain awareness for:

- insert
- update
- upsert
- delete
- atomic nested insert and owned-child synchronization
- tenant-aware write operations

## Installation

```elixir
def deps do
  [
    {:selecto, ">= 0.5.0 and < 0.6.0"},
    {:selecto_db_postgresql, "~> 0.5.0"}
  ]
end
```

For local multi-repo development against sibling ecosystem packages:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=true
```

## Quick Start

```elixir
alias SelectoDBPostgreSQL.Adapter

{:ok, connection} = Adapter.connect(database: "orders", hostname: "localhost")

domain = %{
  name: "Orders",
  source: %{
    source_table: "orders",
    primary_key: :id,
    tenant_field: :tenant_id,
    fields: [:id, :tenant_id, :status],
    columns: %{
      id: %{type: :integer, write: %{server_managed: true}},
      tenant_id: %{type: :integer, write: %{insertable: true, immutable: true}},
      status: %{type: :string, write: %{insertable: true, updatable: true}}
    },
    associations: %{}
  },
  schemas: %{},
  joins: %{},
  writes: %{
    operations: %{insert: %{enabled: true}, update: %{enabled: true}},
    scope: %{tenant: %{required: true, field: :tenant_id}}
  }
}

selecto = Selecto.configure(domain, connection, adapter: Adapter) |> Selecto.with_tenant(42)

{:ok, result} =
  selecto
  |> Selecto.write()
  |> SelectoUpdato.insert(%{status: "pending"})
  |> SelectoUpdato.execute()
```

The domain declares the tenant field once. The configured engine binds the
trusted value once; ordinary calls omit the matching tenant assignment. Use
`SelectoUpdato.preview(operation)` to inspect SQL and bound values. Explicit
`new(domain)` and `execute(operation, selecto, opts)` remain supported.

Named actions share the engine and retain native phase-bound authorization:

```elixir
selecto
|> Selecto.action(:archive)
|> SelectoUpdato.target(42)
|> SelectoUpdato.inputs(%{reason: "Closed"})
|> SelectoUpdato.execute(capability_resolver: host_policy, context: %{actor: actor})
```

The action and inputs must be declared by the domain. Preview and execution
authorize separately. The default action execution adapter handles flat
governed writes; collection and event-stream actions require a host
`action_execution_adapter`. They never fall back to a flat write.

`Selecto.transaction(selecto, fn tx -> ... end)` supplies a callback engine with
the same domain, required predicates and tenant on the adapter's transaction
connection. Match `{:ok, result}` inside the callback so a failed write aborts
it; native adapter return and rollback semantics apply.

Updato never chooses a database driver, emits SQL, or accepts a Repo target.
The configured Selecto adapter owns previewing, compiling, executing, and
transactional behavior. The domain owns the enabled operations, writable
fields, tenant policy, and expected cardinality.

`SelectoUpdato` is the governed entry point for every write. Each execution
validates the operation against the domain's `writes` contract and hands the
adapter a single-use authorization for exactly the compiled command, batch, or
graph. Adapters refuse a write without one (`:ungoverned_write`), so a command
built by hand cannot skip governance. A domain without `writes.operations`
fails every write with `:write_policy_missing`; a domain without
`writes.fields` (or column `write` grants) fails every write except a delete
the same way. There is no permissive mode.

## Nested data

Declare `write` policy beside the source association, including its complete
child domain, ownership, identity, and synchronization policy. The association's
cardinality and key mapping are reused by the normalized write contract. Then
submit ordinary nested data:

```elixir
domain
|> SelectoUpdato.new(tenant: %{tenant_id: 42})
|> SelectoUpdato.insert(%{
  reference: "SO-100",
  items: [
    %{sku: "A", quantity: 2},
    %{sku: "B", quantity: 1}
  ]
})
|> SelectoUpdato.execute(selecto)
```

The caller does not submit each item's parent foreign key. Updato compiles an
atomic `Selecto.Write.Graph`; the configured adapter resolves generated keys,
owns the transaction, and chooses any safe native set optimization. Nested
updates use declared identity fields and may delete missing owned rows when the
domain enables that behavior.

## Core Operations

### Insert

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.insert(%{name: "Widget", price: 19.99})
|> SelectoUpdato.execute(selecto)
```

### Update

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.filter({"status", "pending"})
|> SelectoUpdato.update(%{status: "expired"})
|> SelectoUpdato.execute(selecto)
```

### Query-enforced writes

Use the same Selecto query that established a row's eligibility as an atomic
write precondition. Here, an update succeeds only while order `123` is still
pending:

```elixir
eligible_order =
  selecto
  |> Selecto.filter({"id", 123})
  |> Selecto.filter({"status", "pending"})
  |> Selecto.limit(1)

with {:ok, order} <- Selecto.Context.one(eligible_order) do
  domain
  |> SelectoUpdato.new()
  |> SelectoUpdato.update(%{status: "approved"})
  |> SelectoUpdato.enforce_query(eligible_order)
  |> SelectoUpdato.execute(selecto)
end
```

The update predicate includes both `id = 123` and `status = 'pending'`. If
another writer changes the status after the read, the guarded update affects
zero rows and the declared cardinality check reports the stale or ineligible
write. Query predicates narrow canonical tenant scope; they never replace its
trusted context requirement.

Domain `required_filters` also constrain every write without requiring
`enforce_query/2`. Updates and deletes combine them with caller filters and
trusted tenant scope in the atomic write predicate. Owned-set synchronization
also retains required child predicates in cleanup and collection snapshot scope,
so omitted ineligible children remain untouched. Required or captured query
predicates explicitly refuse upserts until both branches can be proved safe.

For inserts, required and captured query predicates apply to the final candidate
values. SQLite evaluates the complete guard through its typed insert admission
port inside the write transaction, using the actual ordinary table's affinity
and collation. Missing/default-dependent guard fields, unsupported types and
unstable schemas fail closed before insertion. Other adapters retain portable
candidate evaluation. Root-field boolean groups, comparisons, null checks, and
non-empty `IN` predicates are supported. Association predicates and
database-dependent query expressions are rejected for all write operations.
Projection, ordering, limit, and offset remain read concerns.

Required insert fields may be declared with `writes.fields.<field>.required: true`
or `required_on: [:insert]`. Missing, NULL and blank values fail with
`missing_required_write_fields`. Trusted tenant and foreign-key values can
satisfy these declarations; the final values are checked again after normalization.

### Bounded mutation expressions

`SelectoUpdato.Mutation` builds portable arithmetic and coalesce assignments:

```elixir
alias SelectoUpdato.Mutation

domain
|> SelectoUpdato.new()
|> SelectoUpdato.filter({:id, 123})
|> SelectoUpdato.update(%{
  quantity: Mutation.increment(:quantity, 2),
  note: Mutation.coalesce([Mutation.field(:note), "fallback"])
})
|> SelectoUpdato.execute(selecto)
```

The closed operators are literal, root field, add, subtract, multiply, divide,
and coalesce. `Mutation.null(:string)` carries a typed NULL. Trees are limited
to 32 levels and 256 nodes, with 2–16 coalesce operands. Types and declared root
field ownership are checked before dispatch. Field references require updates;
inserts and upserts cannot read a prior row. SQL fragments and DEFAULT are
unavailable. The configured adapter must report the `mutation_expressions`
write capability; the SQLite adapter binds operands and uses native arithmetic.

Native SQLite CANDIDATE rules evaluate expressions against protected prior row
values using the same compiler as DML. Candidate normalization cannot rewrite
an expression result. INPUT rules with expression assignments, nonliteral
required insert values, and prospective strategies outside protected single-row
updates refuse when their values cannot be proved.

`SelectoUpdato.DirectWrite.execute/4` accepts bounded JSON commands naming the
logical `root` relation and delegates to ordinary governed Updato execution.
`execute_batch/4` validates 1–64 commands before atomic execution. Tenant context
and captured queries come from host options; submitted command data never
creates that authority. Upsert update-field selection currently must match the
domain-derived fields. `import_domain/1` maps contract vocabulary to native
keys while retaining field and relationship identifiers as data. A captured
query or host tenant option on a source declaring `tenant_field` requires
trusted tenant context; submitted query predicates cannot satisfy it.

`DirectWrite.execute_graph/4` accepts creation-only nested values through the
configured adapter's protected graph-domain inference capability. Each
relationship must already grant exactly insert, and SQLite must prove a
NOT NULL single-column foreign key to a unique, comparable parent key in
`main`. Native child-key uniqueness determines one or many cardinality.
Composition applies only to these new rows; no cleanup, update or delete
permission is added. SQLite rechecks the physical edges before dispatch.
Candidate rules use adapter-owned native storage projection inside the
transaction. Captured-query options are refused for this creation graph bridge.
The bridge bounds payloads to 256 nodes and 32 levels, each collection to
64 entries, and inference to 128 declared domains. It returns the portable
`Selecto.Write.Result`; ordinary nested Updato builders remain available for
fully declared relationship policies.

### Upsert

The domain must declare its allowed conflict target. When it declares exactly
one, Updato derives it; callers do not repeat or override domain policy.

```elixir
# In the domain:
# writes.operations.upsert = %{
#   enabled: true,
#   conflict_targets: [[:tenant_id, :external_id]]
# }

SelectoUpdato.new(domain)
|> SelectoUpdato.with_tenant(%{tenant_id: 42})
|> SelectoUpdato.upsert(%{tenant_id: 42, external_id: "EXT-123", name: "Widget"})
|> SelectoUpdato.execute(selecto)
```

If the domain declares multiple allowed targets, use `conflict_target/2` to
choose one of those declared targets. Adapter conflict updates include only
fields the domain marks updatable; immutable and server-managed fields never
enter the update set. In a tenant-scoped domain, every allowed conflict target
must include the tenant field so conflict selection itself cannot cross tenant
scope.

### Delete

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.filter({"id", 123})
|> SelectoUpdato.delete()
|> SelectoUpdato.execute(selecto)
```

## Filters

Portable writes accept equality filters and non-empty `IN` filters. Concrete
bulk action targets compile selected ids to `IN`; callers should not construct
an `IN` filter from untrusted arbitrary scope. The domain controls which
operation is enabled and its expected cardinality:

```elixir
SelectoUpdato.new(domain)
  |> SelectoUpdato.filter({"status", "pending"})
|> SelectoUpdato.update(%{status: "expired"})
```

## Tenant Scope Safety

`SelectoUpdato` requires a trusted tenant value for a tenant-scoped write. It
adds the tenant field to insert values and update/delete predicates, and
requires it in upsert conflict targets. Schema-prefix routing, if desired,
belongs to the configured adapter.

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.with_tenant(%{tenant_id: "acme", required: true})
|> SelectoUpdato.apply_tenant_scope()
|> SelectoUpdato.update(%{status: "archived"})
|> SelectoUpdato.filter({"id", 42})
|> SelectoUpdato.execute(selecto)
```

## API Generator

The full API scaffolding generator now lives in `selecto_api`.

Use:

```bash
mix selecto_api.gen.api orders --domain MyApp.OrdersDomain
```

## Developer Guide

See [`docs/developer_action_guide.md`](developer_action_guide.md) for the complete write/action integration
path: write contracts, domain actions, preview/apply flow, capability
authorization, choice-source membership validation, bulk safety, host API
patterns, and testing expectations.

## Verification

Run the normal suite:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=1 mix test
```

Run the package suite with the sibling Selecto checkout:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=1 mise exec -- mix test
```

Set `SELECTO_ECOSYSTEM_USE_LOCAL=0` to exercise Updato's standalone dependency
graph. In that mode, `mix.exs` resolves Selecto from the pinned Git revision
rather than from the sibling workspace checkout.

Database-specific live verification belongs to the selected adapter package.

Run the bounded-exhaustive scope, portable-command, nested-graph,
action-capability, and final trust-boundary models:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=1 mise exec -- mix selecto_updato.verify
```

See [`docs/formal_verification.md`](formal_verification.md) for the exact
finite state spaces and proof limits.

## Status

Current scope is focused on domain-aware write execution. Expect churn around adapters, generator wrappers, and broader ecosystem integration details.

### Native SQLite guard regression

With `selecto`, `selecto_updato` and the real `selecto_db_sqlite` adapter compiled
on the code path, run
`elixir scripts/sqlite_required_predicate_guard_regression.exs`.
This optional integration checks actual public writes, transaction rollback,
collation, tenant scope and fail-closed schema handling. Every SQLite database
is opened with `database: ":memory:"`; the normal unit suite remains driver-free.

SQLite prospective rule admission checks every consumed CANDIDATE, TRANSACTION
and EVIDENCE field before applicability or advisory enforcement. Conditions and
all logical branches contribute dependencies. INPUT-only values remain original
submitted intent, including a literal NULL that SQLite will later replace with
a generated rowid. Updates load protected prior state even for advisory final
stages. Atomic SQLite batches that require such native rule values refuse until
a protected batch preparation strategy exists; caller-provided completeness or
context cannot bypass this boundary. External adapters retain the protected
provider seam for stronger prospective evidence.
