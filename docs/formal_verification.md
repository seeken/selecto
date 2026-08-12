# Selecto Formal Verification

Selecto ships deterministic bounded model checkers and five built-in proof
suites. They provide stronger evidence than sampled tests: every invariant is
checked against every state in an explicitly defined finite model.

Run the suites with:

```sh
mise exec -- mix selecto.verify
mise exec -- mix selecto.verify --output tmp/selecto-verification.json
```

The command exits non-zero when it finds a counterexample. The optional JSON
artifact records the proof level, model identity, state count, invariant count,
check count, and any reproducible counterexamples.

## Current Proofs

### Query scope

`selecto.query_scope.v1` exhaustively crosses:

- tenant-required and tenant-optional domains;
- absent, row-tenant, mismatched/ambiguous row-tenant, schema-prefix, and
  compound prefix-plus-row contexts;
- applied and unapplied row scope;
- absent and present ordinary user filters.

For all 48 states it proves:

- required scope fails closed;
- row scope must match the attached tenant id and cannot contain multiple
  distinct required tenant values;
- the modeled required filter remains in the query filter collection;
- row-tenant values reach SQL through parameters rather than interpolation;
- an explicit execution prefix cannot substitute for an attached tenant
  prefix, though an exact match remains accepted;
- ordinary user filters cannot substitute for required tenant scope.

This model exposed and fixed a real fail-open condition: a tenant id attached as
context was previously accepted as sufficient scope before it had been applied
as a required query filter.

### Provider/consumer contracts

`selecto.domain_contract_compatibility.v1` exhaustively crosses compatible and
incompatible field, filter, required-scope, version, and fingerprint
dependencies.

For all 32 states it proves:

- only a fully compatible consumer is accepted;
- every incompatible dimension is rejected;
- each rejection includes its specific contract diagnostic.

This complements stable contract snapshots and breaking-change classification
in `Selecto.Domain.ContractVerification`.

### Write-registry identifier safety

`selecto.write_registry_identifier_safety.v1` exhaustively crosses:

- canonical write-operation and write-field registries;
- atom, string, and mixed atom/string identifier spellings;
- conflicting enabled and writable authority values.

For all 24 states it proves:

- atom/string aliases that normalize to one authority identifier fail closed;
- authored and already-normalized contract compilation both reject collisions;
- unambiguous atom-only and string-only registries remain accepted.

### Governed query composition

`selecto.governed_query_composition.v1` explores deterministic event traces to
depth two. Its six initial states cross strict and permissive policy with
required row-tenant and schema-prefix scope, plus strict rejection scenarios.
The event alphabet uses Selecto's public APIs for:

- declared joins;
- named CTEs, subqueries, and lateral sources;
- `UNION`, `INTERSECT`, and `EXCEPT`;
- structural composition attempted after a set result already exists;
- strict-mode attempts to introduce equivalent ad-hoc sources or a
  mixed-policy set operand.

Across the complete finite trace graph it structurally proves that the root and
modeled set branches retain tenant scope, required filters, and policy mode.
For named CTE and subquery bodies, which are evaluated during SQL generation
rather than retained as root query branches, the proof renders every supported
one- and two-event composition and requires exact required-filter and
row-tenant bind counts for the protected root, named member bodies, and set
operands present in the trace. Tenant values must remain parameters;
schema-prefix scope must remain in execution options. The named lateral event
uses a table function, not a nested query, so it adds no protected branch.

A set result is deliberately terminal for structural composition. Once a
`UNION`, `INTERSECT`, or `EXCEPT` exists, only further set-operation chaining
and outer `order_by`, `limit`, or `offset` are supported. The model exhausts
post-set attempts to add a declared join or named CTE, subquery, or lateral and
requires an explicit rejection with the query unchanged. Public mutators
enforce this boundary immediately. SQL generation independently verifies the
set-chain prefixes and compares every current non-outer `set` field plus the
current allowlist of query metadata fields with the latest left-operand state.
A missed mutation of those covered fields therefore fails closed instead of
being silently ignored. Strict rejection states prove
the expected policy violation for every modeled ad-hoc attempt, for
strict/permissive mixing, and for set operands carrying different row-tenant
identities or schema prefixes.

This is a closure and fail-closed boundary proof for these declared events and
two-event traces. It does not generalize to arbitrary callbacks, hand-authored
SQL, unlimited nesting, or database execution semantics.

### Write-authority non-escalation

`selecto.write_authority_non_escalation.v1` crosses 768 authored domain and
command states:

- absent, colocated, canonical, and duplicate colocated/canonical authority;
- field and relationship write surfaces;
- insert, update, and delete;
- writable and read-only declarations;
- enabled and disabled operations;
- present and absent required tenant scope, filter requirements, and command
  predicates.

Each state follows the explicit authored, normalized, validated, and compiled
lifecycle. The proof checks 3,072 reachable states and proves that normalization
does not invent authority, ambiguous duplicate authoring fails closed, compiled
field/relationship and operation grants equal the unambiguous authored grants,
and scope/filter/predicate metadata survives the modeled core boundaries.

Runtime enforcement of those compiled requirements during a mutation is proved
by the bounded writer and adapter suites, not by this core normalization model.

## Proof Meaning

Reports use `proof_level: bounded_exhaustive`. A passing report means there is
no counterexample in the complete, versioned finite model. It does not claim an
unbounded theorem about every possible domain, custom SQL fragment, adapter, or
database.

Both checkers are intentionally in normal package code:

```elixir
Selecto.Verification.BoundedModel.check("my.model.v1", states, invariants)

Selecto.Verification.BoundedTraceModel.check(
  "my.trace-model.v1",
  initial_states,
  events,
  invariants,
  max_depth: 3
)
```

Applications can therefore add finite models for their own tenant modes,
published contracts, domain compositions, and policy rules.

The trace checker explores breadth-first and applies events in declaration
order. It records a JSON-portable event trace for every counterexample and
reports transition, disabled-event, revisited-state, and reached-depth counts.
Both bounded checkers use the same portable-term encoder. Maps with keys that
are unsafe as JSON object keys, including atom/string keys with the same JSON
spelling, are encoded as typed `map_entries` so no entry is silently collapsed.
Structs use a separate `struct_module` and `fields` envelope, preserving a real
field named `struct` without colliding with module metadata.
Proper lists and valid UTF-8 binaries retain their ordinary JSON array and
string forms. Improper lists use a tagged `improper_list` envelope containing
an encoded proper `head` and `tail`; invalid UTF-8 binaries use a lossless
`binary_base64` tag.

A `state_key` callback may reduce equivalent visited states, but every piece of
history needed by an invariant must be present in that key. `trace_state` may
select a smaller diagnostic snapshot without weakening state equivalence or
invariant checking.

## Remaining Boundary

The PostgreSQL adapter adds a 232-case bounded live differential checker for
bag projection, null/comparison predicates, parameter binding and conjunction,
inner/left joins, grouping with count/sum, ordering, and limits. That is
executable evidence over its finite fixture model, but it does not prove full
relational equivalence between arbitrary Selecto intent and generated SQL. An
unbounded claim would require a far broader independent relational semantics
for SQL `NULL`, bags, joins, grouping, ordering, adapter behavior, and arbitrary
query construction. The existing SQL tests and live database suites therefore
remain necessary.
