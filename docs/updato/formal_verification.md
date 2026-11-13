# SelectoUpdato Formal Verification

SelectoUpdato uses Selecto's deterministic bounded model checker to prove
write-scope, action-planning, and capability-boundary invariants across finite,
versioned models.

Run:

```sh
SELECTO_ECOSYSTEM_USE_LOCAL=1 mise exec -- mix selecto_updato.verify
SELECTO_ECOSYSTEM_USE_LOCAL=1 mise exec -- \
  mix selecto_updato.verify --output tmp/selecto-updato-verification.json
```

The command exits non-zero on any counterexample. JSON artifacts state the
proof level and exact model sizes.

## Current Proofs

### Write scope

`selecto_updato.write_scope.v1` exhaustively crosses:

- insert, update, upsert, and delete;
- absent and trusted row-tenant contexts;
- absent and present unrelated caller filters.

For all 16 states it proves:

- required write scope fails closed;
- trusted tenant context becomes exactly one targeting filter;
- unrelated filters cannot satisfy tenant scope;
- applying scope preserves the operation and payload;
- applied scope remains explicit and auditable.

### Portable command boundary

`selecto_updato.portable_command.v1` exhaustively crosses:

- insert, update, upsert, and delete;
- absent and present trusted tenant/foreign-key context;
- absent and present domain-required insert fields;
- absent, matching, and mismatched caller foreign-key values.

For all 48 states it proves:

- every invalid state returns a structured error rather than a command;
- every valid state compiles a portable `Selecto.Write.Command`;
- domain-required insert fields fail closed;
- caller input cannot override a trusted foreign-key source;
- trusted tenant scope becomes the required predicate or insert assignment;
- a compiled tenant-scoped upsert conflict target includes the tenant field;
- domain foreign-key reference guards survive compilation;
- expected cardinality and returning policy survive compilation;
- command metadata contains no adapter, connection, Repo, driver, or dialect.

### Action and capability boundary

`selecto_updato.action_capability.v1` plans the canonical synthetic archive
transition and exhaustively crosses preview and execution phases with missing,
enabled, disabled, and hidden policy decisions.

For all eight states it proves:

- the declared capability survives contract projection and action planning;
- the action remains confined to its declared update operation, fields, and row
  target;
- the transition precondition survives planning;
- missing or non-enabled capability decisions fail closed.

### Nested graph boundary

`selecto_updato.nested_graph.v1` exhaustively crosses:

- insert and update roots;
- absent and present trusted tenant context;
- absent, valid, and invalid-child-key relationship policy;
- absent and present caller ownership-key override.

For all 24 states it proves:

- invalid nested states return a structured error before adapter dispatch;
- valid states compile atomic graphs that pass `Selecto.Write.Graph.validate/1`;
- generated ownership keys reference earlier returning rows and cannot be assigned by callers;
- tenant scope covers every graph row;
- updates preserve sync identity, delete-missing policy, and internal identity returning;
- graphs contain no adapter, connection, repository, driver, dialect, or statement strategy.

`selecto_updato.nested_composition.v1` separately crosses all five general
representations with present/missing stable child identity and absent/present
caller tenant override. Across 20 states and four invariants it proves:

- invalid identity or tenant states fail before adapter dispatch;
- valid append-only, delta, full-set, replace-one, and link-delta states compile
  valid atomic graphs;
- only full-set carries the authored delete-missing policy;
- collection rows use stable authoritative or client identity paths, while a
  to-one replace uses its stable relationship path.

This model does not prove arbitrary schemas, depths, graph sizes, adapters,
databases, callbacks, or concurrency schedules. Live adapter suites provide a
separate finite transaction/constraint/returning/rollback evidence layer.

### Final trust boundary

`selecto_updato.trust_boundary.v1` covers twelve adversarial attempts involving
normalized identifier ambiguity, undeclared fields, weakened cardinality,
expanded returning data, missing choice membership, missing action
authorization, and direct or forged opaque planned-operation handles.

For all twelve states it proves:

- adversarial intent fails with a structured error before a command exists;
- the reported reason identifies the exact trust boundary that rejected it.

### Authorization lifecycle traces

`selecto_updato.authorization_lifecycle.v1` starts from 960 finite protocol
configurations crossing:

- full and contract-only plans;
- preview and execute phases;
- actor A/B and tenant A/B;
- enabled, denied, timed-out, crashed, and delayed resolver outcomes;
- identity supplied through context, opts, both agreeing, conflicting actor or
  tenant sources, internally conflicting tenant/tenant-id sources, or
  conflicting atom/string identity spellings, ambiguous actor IDs, or
  conflicting nested/outer tenant fields.

`Selecto.Verification.BoundedTraceModel` then explores every reachable event
ordering through depth six across sealing, handle expiry, authorization and
resolver delivery, timeout and late delivery, matching consumption, actor,
tenant, and phase substitution, ambiguous actor/tenant-key consumption, replay,
grant expiry/revocation, service restart, and attempts to authorize invalidated
handles. The current model reaches 13,248 distinct states and executes 79,488
invariant checks.

For every reached state it proves:

- authority requires an immutable registered plan and an enabled matching-phase
  decision;
- resolver denial, crash, timeout, and late replies fail closed;
- grants are bound to phase, actor, and tenant and can succeed at most once;
- conflicting context/opts or atom/string identity sources fail before resolver
  invocation, or invalidate the grant during consumption;
- expiry, revocation, and service restart never revive authority;
- contract-only plans never materialize executable operations.

The trace model is a finite reference protocol. GenServer tests separately prove
that monitored resolver processes, timers, concurrent compilation, supervisor
restart, and pre-callback grant consumption conform to it.

### Tenant non-interference

`selecto_updato.tenant_non_interference.v1` exhaustively checks 5,832 states and
34,992 invariant evaluations across flat commands, nested graphs, and batches;
insert and update; operation-bound and execution-time tenant A/B context; absent, matching,
or mismatched caller values; atom, string, or ambiguous dual caller spellings;
agreeing or conflicting batch contexts; and conflicting tenant/tenant-id,
repeated keyword, atom/string, direct compiler-context, or nested/outer-field
trusted-source encodings.

It proves that valid states reach the portable data plane with only the agreed
trusted tenant, while missing context, caller mismatch, trusted-source conflict,
normalized ambiguity, and mixed-tenant batches fail before dispatch. Every
command and every graph row is inspected.

### Atomic Multi boundary

`selecto_updato.multi_atomicity.v1` executes 60 finite public-Multi states and
300 invariant evaluations crossing unique/duplicate names, no/first/second
compile failure, agreeing/conflicting trusted context, and
exact/short/long/non-list/failed adapter results.

It proves that all operations compile and their contexts agree before exactly
one ordered `%Selecto.Write.Batch{atomic?: true}` is dispatched; names and
results form a bijection; duplicate names and result-count mismatches fail
closed; and errors never produce a partial name map.

Database rollback is deliberately outside this model and must be proven by each
write adapter's live transactional integration suite.

## Proof Meaning

Reports use `proof_level: bounded_exhaustive`. Passing means no counterexample
exists in the complete declared finite state model, or in the reachable trace
model through its stated depth and state-equivalence function. It does not prove
arbitrary host callbacks, custom execution adapters, database transaction
behavior, scheduler fairness beyond the modeled event orderings, or external
side effects.

These proofs complement rather than replace property tests, adapter tests,
live adapter verification, and application-level authorization tests.
