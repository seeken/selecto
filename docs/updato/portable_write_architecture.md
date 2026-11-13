# Portable Write Architecture

`selecto_updato` is the domain-governed write-intent layer. It does not know a
database dialect, emit SQL, open a connection, or require an application's ORM
configuration. A write crosses four explicit ownership boundaries.

1. The Selecto domain declares write policy: enabled operations, writable
   fields, tenant scope, transitions, foreign-key sources, bulk permission, and
   default cardinality.
2. Updato validates an intent and compiles a portable `Selecto.Write.Command`
   or atomic `Selecto.Write.Graph`, then issues a single-use
   `Selecto.Write.Authorization` for exactly that payload.
3. The configured Selecto database adapter refuses the write unless it carries
   that authorization, then compiles it for its dialect and executes it on its
   native connection.
4. The host app owns authentication, authorization policy, UI/API envelopes,
   and optional preflight explanations.

The execution target is a configured `%Selecto{}` value. Updato never accepts
an application repository as a substitute for that adapter boundary.

## Governed Execution

Updato is the only issuer of write authorizations. Every execution, including
an atomic `multi` batch, a nested graph, and a prepared write whose command is
built from protected database state inside the adapter's transaction,
revalidates the operation against its domain's `writes` contract at that
moment and authorizes exactly the result. An authorization is opaque,
single-use, bound to its payload, and valid only in the issuing process.

`Selecto.Write.execute/3` and every adapter's `execute_write/3` refuse a write
without one with `:ungoverned_write`, so a hand-built or retained command
cannot skip governance. The `*_unsafe` primitives in `Selecto.Write` and the
adapters exist for trusted tooling and adapter tests only.

The policy is strict. A domain without `writes.operations` fails every write
with `:write_policy_missing`. A domain without `writes.fields` fails every
write except a delete the same way. A nested relationship without
`allowed_ops` or an explicit `write` policy, or without its own child domain,
fails with `:write_policy_missing`. An atomic `multi` may span domains: each
operation is governed against its own domain, and the batch is refused when
the operations' trusted contexts differ (`code: :batch_context_conflict`).

## Command Flow

```text
domain + trusted context + user intent
                 |
                 v
        Updato action planner
          - validates fields
          - binds tenant scope
          - preserves transition guards
          - derives cardinality
                 |
                 v
    Selecto.Write.Command or Graph + single-use authorization
          - relation
          - assignments
          - predicate AST
          - expected cardinality
          - returning projection
          - generated row bindings
          - owned-set sync policy
                 |
                 v
     configured database adapter
          - refuses an unauthorized write
          - dialect compilation
          - bound parameters
          - transaction
          - cardinality check
          - commit or rollback
```

Tenant values and context-owned foreign keys are bound from trusted execution
context. Caller values may not override them. Foreign-key reference guards are
portable command metadata; the adapter decides how to enforce them for its
dialect.

## Concrete Bulk Targets

A selected-row bulk action uses this canonical target:

```elixir
%{target: %{ids: [41, 42, 43]}}
```

Updato rejects an empty list or duplicate ids, normalizes each id using the
domain primary-key type, and retains every id. It never converts the request to
`target.id = List.first(ids)`.

For a domain-enabled bulk update, the portable predicate is equivalent to:

```elixir
{:and,
 [
   {:in, {:field, "id"}, [{:literal, 41}, {:literal, 42}, {:literal, 43}]},
   {:eq, {:field, "state"}, {:literal, "done"}},
   {:eq, {:field, "tenant_id"}, {:literal, trusted_tenant_id}}
 ]}
```

The selected set derives `expected_cardinality: {:exactly, 3}`. The transition
guard and tenant guard are part of the mutation predicate, not merely preview
metadata.

## Atomic Cardinality Enforcement

Cardinality is an execution invariant, not a post-write warning. The adapter
must:

1. begin a transaction;
2. execute the parameterized mutation;
3. compare affected rows with the command cardinality;
4. commit only when it matches; otherwise roll back and return
   `:cardinality_mismatch`.

This prevents partial bulk transitions. If two ids are selected but only one
still satisfies `state = done`, neither row changes.

Host preflight may query current rows to explain that an action is unavailable.
That improves the form, but it is not the safety boundary: state can change
between preflight and apply, so the write predicate and transactional
cardinality check remain mandatory.

## Adapter Contract

Write-capable Selecto database adapters own:

- dialect-specific identifiers and placeholders;
- predicate compilation, including parameterized non-empty `IN`;
- native connection handling;
- returning syntax and result normalization;
- transaction boundaries;
- rollback on cardinality mismatch.

Updato owns none of those details. Adding a write-capable adapter should require
implementing the Selecto write-adapter contract, not adding a dialect branch or
application ORM dependency to `selecto_updato`.

See [Portable Nested-Write Architecture](nested_write_architecture.md) for the
relationship contract, graph invariants, generated-key flow, and sync safety
boundary.

## Verification Boundary

The critical test stack is layered:

- Updato planner tests prove target preservation, type normalization,
  transition predicates, and derived cardinality.
- Adapter compiler tests prove safe bound-parameter SQL generation.
- Adapter integration tests prove mismatch rollback leaves all rows unchanged.
- Host API and LiveView tests prove availability messages, editable eligible
  forms, disabled ineligible forms, apply results, and result refresh.

The non-negotiable release gate is the integration assertion that a mutation
which tentatively affects fewer rows than selected leaves the database exactly
as it was before the call.
