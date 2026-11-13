# Portable Nested-Write Architecture

Nested writes are a domain-governed command tree compiled into an atomic,
adapter-neutral `Selecto.Write.Graph`. They are not a sequence of unrelated
flat writes and they are not delegated to a Phoenix form, schema callback, or
application repository.

## Ownership boundaries

The domain owns:

- which relationship key may appear in submitted nested data;
- whether the relationship is an owned composition, shared association, or
  join association;
- one-to-one or one-to-many cardinality and item bounds;
- exact append-only, delta, full-set, replace-one, or link-delta
  representations and allowed child operations;
- the complete child domain;
- the parent key and generated child foreign key;
- child identity fields;
- explicit omission and delete-missing policy;
- stable child identity, temporary client identity, conflict predicates,
  path capabilities, idempotency, offline, and output policy;
- tenant scope, writable fields, foreign-key sources, and command cardinality
  at every domain level.

Updato owns:

- splitting each submitted map into flat and declared relationship values;
- compiling every flat row through the same portable command compiler;
- rejecting caller-supplied generated ownership keys;
- topological ordering and path-addressed errors;
- generated-key bindings and required internal returning fields;
- compiling each declared representation without converting it to another;
- compiling full-set intent into a `:sync` graph node and link-delta intent
  into join-row commands only;
- proving the result is a valid atomic graph before dispatch.

The configured database adapter owns:

- dialect-specific statements and bound parameter encoding;
- resolving generated values from successful parent results;
- native transaction behavior;
- optimized set reconciliation when its dialect and server version can
  preserve every graph invariant;
- safe ordered fallback when an optimization is insufficient;
- per-row and whole-graph cardinality checks, commit, and rollback.

The host owns authentication, path-capability authorization, trusted context,
forms, API envelopes, shared-target choice validation, and audit delivery. It
does not own graph persistence ordering. Updato carries capability policy into
the graph contract; the authorized host or Operations gateway must prove the
caller holds it before dispatch.

## Relationship contract

Nested input is recognized only when `writes.relationships` declares an
explicit policy. Database foreign keys never grant ownership or mutation
authority. New contracts use the general vocabulary below; the compiler also
normalizes the delivered `:owned`, `:shared_reference`, and `:join_only`
aliases.

```elixir
%{
  source: %{
    source_table: "orders",
    primary_key: :id,
    columns: order_columns
  },
  writes: %{
    operations: %{
      update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
    },
    scope: %{tenant: %{required: true, field: :tenant_id}},
    fields: %{status: %{updatable: true}},
    relationships: %{
      items: %{
        ownership: :composition,
        cardinality: :many,
        path_id: "orders.items",
        parent_key: :id,
        child_key: :order_id,
        identity_fields: [:id],
        client_identity: :client_id,
        domain: item_domain,
        read: %{allowed: true, max_depth: 2, max_rows: 100},
        write: %{
          modes: [:delta, :full_set],
          create: true,
          update: true,
          delete: true,
          omission: :delete_missing,
          min_items: 1,
          max_items: 100,
          max_mutations: 100
        },
        tenant_scope: %{mode: :recursive},
        capabilities: %{
          create: "order.items.create",
          update: "order.items.update",
          delete: "order.items.delete"
        },
        conflict: %{child_fields: [:lock_version]},
        idempotency: %{request_key: true, client_identity: :client_id},
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
        },
        output: %{identity_mapping: true, stable_error_paths: true}
      }
    }
  }
}
```

`domain` is a complete child Selecto domain, not merely a table name. Its
write contract independently controls child fields, tenant policy, foreign-key
sources, and expected cardinality. Relationships may nest recursively.

Canonical `selecto.data_rules.v1` bindings are the portable data-validation
path. Put child scalar rules, such as `quantity > 0`, in the child Domain and
bind parent collection rules, such as count or `collection.unique_by`, to the
writable relationship path in the parent Domain. Updato evaluates both before
emitting or dispatching the graph and prefixes child failures with the stable
nested row path. Candidate collection bindings run only for a complete insert,
`full_set`, or `replace_one` representation; a partial `delta` returns
`required_data_rule_pending` instead of treating submitted mutations as the
complete collection. The relationship-local `validation` shape above remains
a compatibility input for older domains and for aggregate policies that do not
yet have a canonical v1 operator.

### Nested failure paths

`SelectoUpdato.Error.details.path` is the public location of a nested graph or
validation failure. For a field error inside a to-many row, the path contains:

1. the relationship path;
2. a stable identity segment for the row; and
3. the failing child field path.

For example, an invalid quantity in a newly added row may produce
`[:items, "client_id=new-1", "quantity"]`. The identity segment is encoded as
`field=value`; consumers split on the first `=` and treat the remaining value
as opaque. Persisted identities and client identities use the same path
position. Nested relationships repeat this relationship/identity structure at
each collection depth.

Stable identity segments are intentionally independent of a submitted array
index. Reordering, adding, or removing sibling rows therefore cannot move the
failure to a different logical row. A form integration may resolve the stable
segment to its current framework index for presentation, but it MUST preserve
the original structured error when it cannot resolve the identity. Scalar
child validation MUST append the failing field to the stable row path; returning
only the row path is insufficient for inline field errors.

A trusted host may discharge that pending candidate obligation by passing a
`candidate_state_provider` to `SelectoUpdato.execute/3`. The provider receives
a bounded `%Selecto.Write.CandidateRequest{}` containing the scoped parent
portable command, parent and child relationship keys, trusted context,
requested fields, identity fields, and a maximum of 1,000 prior rows. It must
return a typed `%Selecto.Write.CandidateState{complete?: true}` with an explicit
protection value. Updato validates complete unique identities and applies the
submitted create/update/delete operations itself before evaluating parent
collection rules. An absent provider, an incomplete result, duplicate or
missing identities, or an over-limit collection cannot dispatch.

Adapters may instead implement Core's `execute_prepared_write/3` boundary and
report `prepared_candidate_state: true`. Updato then compiles the nested graph
inside the adapter-owned transaction using the adapter's candidate loader. The
PostgreSQL adapter locks the scoped parent row, loads its children, evaluates
the candidate rules, executes the graph, and commits or rolls back as one
transaction. A caller-supplied `:snapshot` provider remains useful for bounded
synthetic validation, but it does not establish this race-safe commit boundary.

Only `ownership: :composition` permits nested child create, update, or delete.
`link_delta` is limited to `:shared_association` or `:join_association` and
compiles commands for relationship/join rows; it does not mutate or delete the
shared target. Updating a shared target requires its own separately authorized
root Operation.

`child_key` is generated by the graph and must not be accepted from submitted
data. `parent_key` defaults to the parent primary key. General contracts
declare `identity_fields` explicitly. Creates carry a non-persisted
`client_identity`; successful graph results return stable
client-to-authoritative identity mappings.

## Exact mutation representations

The compiler preserves the representation named by `mode`:

- `append_only` accepts `items` and emits creates only;
- `delta` accepts explicit `create`, `update`, and `delete` groups and retains
  omitted rows;
- `full_set` accepts `items` and applies the authored omission policy;
- `replace_one` accepts exactly one explicit create, update, or delete intent;
- `link_delta` accepts `link` and `unlink` groups for a shared or join path.

An undeclared or mismatched mode fails before adapter dispatch. Compatibility
list/map payloads remain available only where the relationship's delivered
legacy policy gives them one unambiguous meaning.

For example, a delta update is explicit and path-stable:

```elixir
SelectoUpdato.update(write, %{
  status: "submitted",
  items: %{
    mode: :delta,
    create: [%{client_id: "new-1", product_id: 5, quantity: 2}],
    update: [%{id: 11, lock_version: 7, quantity: 3}],
    delete: [%{id: 12, lock_version: 2}]
  }
})
```

The corresponding full-set payload uses `mode: :full_set` and `items`; it is
never silently converted to or from delta.

Before command compilation, the delivered portable validation subset checks
numeric child-field bounds, complete submitted cross-child uniqueness tuples,
and sum aggregate limits. Aggregate rules name their representations; the
Order fixture scopes its complete-collection total to `full_set`. Without
candidate state, delta can validate only fields and identities present in the
submitted mutation batch. Canonical count and uniqueness rules can use the
bounded candidate provider described above. Legacy aggregate rules still
require migration to a canonical operator and an authoritative execution
strategy. Unknown relationship-validation keys fail closed rather than being
ignored.

## Portable graph contract

The graph contains ordered relation nodes. Every row contains one validated
`Selecto.Write.Command` plus zero or more generated bindings:

```text
root orders/root INSERT ... RETURNING id
  |
  +-- items/0 INSERT ... bind order_id <- orders/root.id RETURNING id
  |     |
  |     +-- allocations/0 INSERT ... bind item_id <- items/0.id
  |
  +-- items/1 INSERT ... bind order_id <- orders/root.id RETURNING id
```

A graph is valid only when:

- it is non-empty and atomic;
- node and row ids are unique;
- every command targets its node relation;
- every generated reference points to an earlier row;
- the source command returns the referenced field;
- submitted assignments do not override a generated binding;
- sync nodes declare identity fields and an ownership predicate;
- predicates and metadata contain no raw SQL.

Portable field types travel with relation nodes so adapters can encode set
sources without guessing. The type vocabulary remains domain-level data; any
dialect cast belongs to the adapter.

## Insert semantics

For a nested insert, Updato compiles the root and every child as ordered insert
commands. Parent primary keys are added to returning only when required for a
binding or requested by the caller. Child foreign keys are resolved after the
parent succeeds and before the child statement runs.

Pure inserts are not forced through an upsert or set-reconciliation primitive.
The adapter is free to use its normal insert-returning path, provided the
entire graph remains inside one transaction.

## Update, delta, and synchronization

For a nested root update, each relationship node preserves its declared
representation:

- delta create/update/delete groups compile to ordered child commands and do
  not touch omitted children;
- full-set items with complete identity compile as exact-cardinality updates,
  while items without identity compile as inserts;
- full-set `delete_missing` removes rows inside the owned predicate but absent
  from the post-write identity set;
- replace-one compiles one explicit lifecycle intent;
- link-delta compiles only link-table insert/delete commands;
- every affected child command is additionally constrained to the generated
  parent key and its declared conflict fields;
- tenant scope is present on each child command when the child domain requires
  it;
- sync rows return their identity fields internally, including newly generated
  identities, so an ordered fallback cannot delete a row it just inserted.

An identity that exists under a different owner must affect zero rows and
therefore fail exact cardinality. The adapter rolls back the root update and
every earlier child action.

## Tenant scope

Each domain level enforces its own declared tenant scope. Trusted context is
merged once and passed to every child compiler. A caller-provided tenant value
must match trusted context; missing context fails before adapter dispatch.

When a child table has no tenant column, ownership can still be transitively
scoped through a tenant-filtered parent result and the generated child foreign
key. That is an authored domain choice, not an inferred database rule.

## Result and failure semantics

The public result is a normalized graph result whose rows are the root
returning projection. Portable metadata contains per-child outcomes at stable
semantic paths and client-to-server identity mappings. Adapter metadata may
also report which safe execution strategy each node used, but callers cannot
request a dialect strategy through Updato.

Any of these conditions aborts the graph:

- invalid nested shape or item bounds;
- undeclared or non-owned relationship;
- forbidden child field or generated-key override;
- missing tenant or foreign-key context;
- missing generated result value;
- per-row or root cardinality mismatch;
- incomplete set-reconciliation action;
- statement or transaction failure.

No partial graph result is successful. Adapters that cannot provide atomic
execution must reject `Selecto.Write.Graph` rather than emulate success.

## Deliberate limits

The general contract supports owned compositions plus shared/join link rows.
It does not mutate a shared target through a parent payload, execute arbitrary
hooks, accept caller-authored SQL expressions, or claim atomicity across
databases, remote systems, people, or slow Assurance waits. Those boundaries
require separately authorized Operations or explicit durable staged workflows.

An update currently requires at least one writable scalar change on the root
and on every submitted existing child. This avoids inventing a no-op update or
adapter-specific locking statement merely to anchor descendants. A future
portable lock-anchor command can remove that limit without hidden trigger or
timestamp side effects.
