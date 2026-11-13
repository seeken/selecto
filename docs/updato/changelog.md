# Changelog

## 0.5.0 - 2026-11-12

- Governed update and delete filters in Selecto's operator form
  (`{field, {:>, v}}`, `{:in, list}`, `{:not_in, list}`, `{:between, a, b}`,
  `{"!=", v}`, a list, `:not_null`, ...) refuse typed
  (`unsupported_filter_operator`) before any SQL runs; bound as one literal
  they failed in the driver (`:transaction_failed`). A field equal to a value
  or nil, and the three-element forms already accepted, are unchanged.
- Domain required filters, host-scope (enforce_query) filters and tenant
  pins, in the write predicate and the post-image/insert-candidate checks,
  compile BETWEEN on a date-like field half-open (`>= a AND < b`) as the read
  does; it was closed and let a row on the upper bound pass. (A trusted
  required filter joins the operation's filters, so an operator form there
  refuses as above.) The field's type comes from `source.columns` with the
  domain's top-level `columns` settings merged over it, as the read configures
  the column.
- A planned action's grant binds the trusted required filters: a grant issued
  under one set refuses to write under another, or under none
  (`action_authorization_mismatch`). Leaving the scope's filters out of the
  operation fingerprint had let a changed filter write.
- A host filter equal to a trusted required filter, naming the field as an atom
  where the trusted one names it as a string, is the same filter: it no longer
  refuses as `duplicate_filter_identifier`.
- Filters the execution scope adds are left out of a planned action's grant
  fingerprint, as the tenant filter already was: a trusted context's required
  filters voided the grant with `action_authorization_mismatch`.
- Preserve non-interned tenant field identifiers when projecting portable JSON
  write contracts, so cold release startup retains required tenant scope.

- Bound status flows from the root or any node to every graph descendant at
  every depth (w3exrev18 item 33/33a): every child node is marked
  `bound_scope` (its delete-missing cleanup runs the bound delete contract)
  and every descendant row command carries it, so explicit delta deletes,
  link_delta unlinks and descendant inserts and updates on tables without a
  tenant field are checked for statement-level triggers and rules too.

- A sync node compiled under a bound scope (scoped collection, engine
  tenant, trusted pin, or a bound parent or child command) is marked
  `bound_scope`, so its delete-missing cleanup runs the adapter's bound-scope
  delete contract (w3exrev17 HIGH 1).

- A DELETE under a bound scope (engine tenant, trusted or host scope, any
  required filter, query enforcement) carries `metadata.bound_scope`, so the
  adapter refuses statement-level DELETE triggers and DELETE rules that act
  on rows the guard excludes.

- Fixed: tenant-pin detection is fail-closed. A domain required filter that
  names the declared tenant column anywhere, at any depth and under any
  operator (ranges, OR arms, NOT, a nested AND given as one filter), bounds
  the post-image whole; before, only filters whose every compared field was
  the tenant field counted, and only for =, <>, IN and NOT IN.

- Fixed: nested graph children ignored a trusted context's required
  filters. Each child having the pinned field is now bound to it (pre-image
  predicate and post-image scope); a child that cannot be bound refuses the
  graph (`missing_tenant_scope`, `trusted_scope_unbound_child`). No compile
  option exempts a command from the unapplied-filters check any longer
  (`record_state_ownership` did).
- A domain required filter pinning the declared tenant column
  (`source.tenant_field` or `writes.scope.tenant.field`) bounds the
  post-image too; other required filters stay pre-image only.
- A nil trusted pin (`{"site", nil}`) compiles to IS NULL in the pre-image
  and the post-image.
- A tenant upsert carries `metadata.post_image` (the engine tenant), so the
  adapter re-reads or refuses it.

- Fixed: a trusted context's required filters (`execute(..., required_filters:
  ...)`, `context: %{required_filters: ...}`, `new(domain, tenant:
  %{required_filters: ...})`) were dropped on a domain without
  writes.scope.tenant. They now always join the pre-image predicate and the
  post-image scope (an insert's full guard), and an upsert carrying them is
  refused (`query_enforcement_unsupported_operation`). A compile that never
  applied them (a direct `PortableCommand.compile/2`) is refused
  (`invalid_tenant_scope`, `trusted_required_filters_unapplied`) instead of
  running unscoped; nested graph children inherit their root's check.

- TW-09 post-image (user decision 2026-10-24): a guarded INSERT/UPDATE
  command carries `metadata.post_image` (the predicate its stored rows must
  still satisfy and the key to re-read them by). The scope is recorded by
  provenance: the engine tenant on every tenant column the contract
  declares, the trusted context's required filters, and a host-scope
  query's own filters (`scope_filters`, captured without the domain's
  required_filters). Plain required filters and query enforcement bound only
  an UPDATE's pre-image; an INSERT is checked against its full guard. A
  scoped update that would move the row's key is refused
  (`query_rule_not_evaluable`); restating the key it filters on is allowed.

- Fixed: catalog info (host `:column_metadata` and adapter `column_catalog/2`)
  normalises string and atom keys (`"type"`/`:type`, table and column names)
  and trust/determinism values (`"unverified"`, `:base_verified`, `"true"`).
  An unrecognised trust value, a missing or non-string type, or a malformed
  entry is unverified (decides nothing) and never raises; an unrecognised
  determinism value is nondeterministic. Before, `trust: "unverified"` was
  treated as verified and a string-keyed entry raised CaseClauseError.

- Catalog metadata may carry `trust: :base_verified | :unverified` (an
  adapter that could not fully resolve a column, e.g. a PostgreSQL domain
  chain); trust is only ever lowered, never raised above verified.
- `test/fixtures/query_enforced_scalar_v2.json` re-copied from harness
  2539564 (714 cases, U115-U124 on resolved and unresolved domains).
- Documented (integration guide section 6): host `:column_metadata` is
  host-owned DDL truth and fails open when wrong; prepared writes read the
  catalog before their transaction, so concurrent DDL in that window is not
  seen in process.

- The portable insert candidate check compares by the column's declared type
  (query_enforced_scalar v2, specification 2.37). Text compares by UTF-8
  bytes and text ranges are refused; numeric columns compare exact decimals
  and refuse candidates the column would not store unchanged (length,
  integer range, precision, scale); every other type (char(n), citext, uuid,
  boolean, temporals, floats, enum, json, custom names, nondeterministic
  collations, undeclared fields) decides only byte-identical operands.
  Native candidates compare as their bound text; native floats and
  temporals are refused in process.
- Trust levels: the insert target's catalog types (the adapter's optional
  `column_catalog/2`, read lazily when an insert's candidate is evaluated,
  or before the transaction for prepared writes, at most once per table per
  write transaction (an execute or a Multi batch) and never cached across
  transactions; or `:column_metadata` supplied by the host) are verified. A field known only by its declared domain type is
  unverified and decides nothing. A comparison not decidable in process
  defers to MySQL/MariaDB stored-row admission; on other backends it is
  refused with `query_rule_not_evaluable`. An absent field or a column
  operand is refused before any write.
- Behaviour change: an evaluated insert on PostgreSQL now reads the target's
  catalog types first (one SELECT), and without them (no adapter callback,
  standalone compile) a query-enforced insert is refused as not evaluable.
- `test/fixtures/query_enforced_scalar_v2.json` (704 cases) and
  `query_enforced_scalar_edges_v2.json` (532) are byte copies of the harness
  corpora (harness 11d845a); the evaluator's type classes ship as
  `priv/query_enforced_scalar_v2_type_classes.json`.

- Host fields for MySQL-family exactness come only from host-installed
  predicates: the domain's required filters, the trusted context's required
  filters and the enforced query. They are walked through AND/OR/NOT at any
  depth, for `=`, `<>`, `IN` and `NOT IN`. The caller's own write filters no
  longer count.
- Insert candidates under query enforcement compare in each field's declared
  type (decimal, integer, date, time, naive datetime). `"2" < "16"` is
  admitted, and a non-finite or unparsable value (`"NaN"`, `"0x10"`) is
  `query_rule_not_evaluable` instead of a lexicographic violation.


- `metadata.tenant_fields` also lists every column that a top-level eq/IN
  conjunct of the write predicate (or of a guarded insert's admission
  predicate) names. That covers host scopes and required filters on domains
  without tenant_field. MySQL-family adapters compare those columns by their
  stored bytes.


- A reference guard on a UUID tenant column carries `tenant_exact: :bytes`.
  MySQL-family adapters then compare its stored bytes unconverted.


- Portable commands carry `metadata.tenant_fields` (the root's tenant field
  and `writes.scope.tenant.field`). Reference guards whose tenant column the
  domain types as a non-text value everywhere carry `tenant_exact: false`.
  MySQL and MariaDB use both to compare tenant and site columns by their
  stored bytes. Other backends ignore them.


- Engine-backed `Selecto.write/1` and `Selecto.action/2` drafts inherit the
  configured domain, tenant and required predicates. Bound operations support
  `preview/1` and `execute/1`; named actions retain native planning and fresh
  authorization with an explicit host boundary for complex execution.

- MySQL and MariaDB guarded inserts carry `insert_admission` metadata
  (predicate plus the domain primary key) so their adapters re-read the stored
  row under the predicate; the portable candidate check still runs first. An
  undeclared key defaults to `id`; a composite key is refused with
  `query_rule_not_evaluable`.
- Graph children of a root tenanted only by `writes.scope.tenant` (no
  `source.tenant_field`) are checked on the root tenant column too: the root
  tenant column is source.tenant_field, else the write scope's tenant field.

- A graph child that declares its own tenant field (for example org_id) and
  also stores the root's tenant column keeps its own binding and binds the
  root tenant column to the trusted tenant as well. Only values Updato fills
  from trusted sources skip insertability; a caller-supplied site equal to
  the single pin is checked like any other value.

- Graph children are checked on every column that names a root tenant
  column, whatever they declare: a root tenant_field column is bound to the
  trusted tenant and a root scope column must lie in the root's trusted site
  pin (lesson 47b). Creation graphs (`DirectWrite.execute_graph`) and write
  plans resolve the target's engine tenant like execution. Only a query
  enforced as the host's trusted scope (`enforce_query(op, q, host_scope:
  true)`) can pin sites; a single pinned site is governed autofill; and an
  admitting Selecto-style tenant IN conjunct is intersected.

- Lesson 47b: on a two-column domain under a trusted tenant, a write that sets
  the site column (every insert or upsert, an update assigning it, batch
  members, graph roots and children, owned-sync rows) is refused with
  `missing_tenant_scope` unless a trusted predicate pins the sites: the
  domain's required filters, the trusted tenant context's required filters or
  an enforced host query (positive top-level eq/IN, intersected). Caller
  filters never pin. The value must lie inside the pin (`tenant_mismatch`
  otherwise), and an omitted insert site is filled only when exactly one site
  is pinned. Writes that leave the site alone are unaffected.

- Lesson 47: a trusted tenant (operation context, execution context or the
  target Selecto's engine tenant) bounds every write on a domain that declares
  `source.tenant_field`, with or without `writes.scope.tenant`: updates,
  deletes, upserts, batches and graph members AND `tenant_field = tenant`,
  inserts carry it, a tenant predicate that excludes it is `tenant_mismatch`
  and an admitting IN set is intersected. Bound upserts need the tenant column
  in their conflict target. Disagreeing trusted sources are `tenant_mismatch`.
- Lesson 47a: on a two-column domain (tenant_id with a `site_id` write scope)
  the trusted tenant binds `tenant_id`, never `site_id`. The site is pinned
  only by positive host/required site conjuncts, which confine inserted sites
  (a single pinned site fills an omitted one). A graph child whose tenant field
  is the root's scope column stays within the root's pinned site set, or is
  refused with `missing_tenant_scope`.

- Validate and normalize original INPUT before domain text-case formatting,
  trusted tenant injection and generated foreign-key assignments. Apply INPUT
  normalizers once, then evaluate the actual native storage candidate.

- Honor canonical `writes.fields.required` on inserts and upserts, preserve
  `required_on` declarations and refuse missing, NULL or blank required values
  before adapter dispatch with `missing_required_write_fields`.

- Enforce domain `required_filters` on direct and atomic Multi writes, alongside
  captured query predicates and trusted tenant scope. Preserve required child
  predicates in owned-sync cleanup and governed collection snapshots, including
  an empty authored set. Use the actual configured
  SQLite backend for transaction-bound typed insert admission; refuse unprovable
  candidates, association predicates and guarded upserts before mutation.

- Close the ungoverned-write boundary. Every `execute/3`, `run/3` and prepared
  execution now hands the adapter a single-use `Selecto.Write.Authorization`
  for exactly the compiled command, batch or graph (issued only by
  `SelectoUpdato.GovernedWrite`); adapters refuse writes without one with
  `:ungoverned_write`. Missing write policy fails closed with
  `:write_policy_missing`: a domain without `writes.operations`, a non-delete
  write without `writes.fields`, a nested relationship without `allowed_ops`
  (or an explicit `write` policy) or without a child domain. There is no
  permissive mode.

- An atomic `multi` may span domains: each operation is governed against its
  own domain, and the batch is refused only when the operations' trusted
  contexts differ (`:tenant_mismatch` for a tenant conflict, otherwise
  `:invalid_operation`; `code: :batch_context_conflict`).

- Report the contract's stable write error codes: a disabled operation or a
  nested operation the relationship does not allow is
  `:write_operation_not_enabled` (was `:invalid_operation`/`:invalid_graph`), a
  non-writable nested relationship is `:write_relation_mismatch` (was
  `:invalid_graph`), a declared but non-writable field is
  `:write_field_not_writable` (was `:forbidden_field`), and an assignment,
  filter or returning field the source does not declare is `:unknown_field`
  (was `:invalid_operation`/`:forbidden_field`). Details are unchanged.

- A `NULL` foreign-key assignment no longer emits a foreign-key guard, so
  clearing a reference needs no referenced parent row.

- Preserve the complete stable nested validation path through child scalar
  failures, including the failing field after the collection identity segment,
  so form consumers can attach errors after rows are added, removed, or
  reordered.

- Add governed root scalar set/unset actions with published field grants,
  protected-path and value bounds, and selected postimages bound into the
  idempotency payload. Preserve authored action returning selections through
  the canonical Updato contract and derive adapter gates from actual operations.

- Support explicitly declared portable ObjectId action inputs and targets,
  enforce approved root/child identity types, and gate document dispatch on
  ObjectId shape support without implicit string conversion.

- Verify that existing document actions require owned-object shape support,
  including typed scalar arrays inside objects, before adapter dispatch.

- Derive typed scalar-array shape capabilities from the approved release before
  document action dispatch; preserve existing feature-free idempotency hashes.

- Added `:event_stream` action planning that preserves aggregate, bounded
  context, stream identity, expected-version consistency, and declared possible
  events without materializing a database write operation.
- Added sealed, single-use preview and execution authorization grants for
  event-stream plans, binding the complete plan and authorization context before
  a host event adapter can consume it.
- Added `enforce_query/2` so Selecto query predicates can serve as atomic
  update/delete eligibility guards and fail-closed insert candidate rules,
  while preserving canonical tenant scope and cardinality enforcement.
- Removed the unused task supervisor and the
  `mix selecto_updato.gen.api` compatibility task.
- Removed legacy map-shaped Selecto filter extraction and permissive write
  fallbacks. Operations and writable/required fields now require explicit
  canonical `writes.*` declarations.

### 0.5.0 baseline - 2026-08-14

- Raised the Selecto baseline to `0.5.0` while keeping Updato restricted to
  portable governed write intent and `Selecto.Write` adapter dispatch.
- Added a blocking production/dependency boundary gate forbidding PostgreSQL,
  Postgrex, native SQL/types/errors, and concrete database adapters.
- Preserved flat, nested, batch, action, tenant, authorization, cardinality,
  and returning behavior across the explicit runtime-context migration.

## 0.4.3 - 2026-08-13

- Fail closed when an empty nested sync targets a tenant-scoped child without
  trusted tenant identity, preventing an unscoped parent-key cleanup delete.
- Bound action grants to sealed target and input payload digests and enforced
  nested relationship `allowed_ops` for actual child inserts and deletes.
- Made nested `delete_missing` opt-in, required delete permission when enabled,
  and capped nested relationship compilation at 32 levels.
- Preserved trusted tenant scope when a conflicting tenant-field filter is
  already present so later validation rejects ambiguity instead of treating
  the write as scoped.

## 0.4.2 - 2026-08-12

- Added portable field-type metadata to emitted write commands so adapters can
  bind guarded insert values without database-specific inference or SQL in
  Updato.
- Added the complete domain-declared conflict-target set to portable upsert
  metadata so dialects that cannot name a constraint can reject ambiguity.
- Reject tenant-scoped upserts unless the selected conflict target includes the
  tenant field, preventing a global unique key from selecting another tenant's
  row.
- Extended the bounded portable-command model with tenant-scoped conflict
  selection, bringing the complete formal suite to 115,492 checks.
- Updated verification adapters to the versioned Selecto write capability
  protocol and the Selecto 0.4.13 baseline.
- Deduplicated nested-graph generated-key projections by normalized identifier,
  allowing callers to request a primary key without producing atom/string
  duplicates in the portable root command.

## 0.4.1 - 2026-08-12

- Added support for source-colocated field and association write authoring by
  consuming Selecto's normalized canonical write contract.
- Normalized colocated nested relationship policy before strict Updato
  validation and graph compilation, so malformed derived parent/child keys
  still fail before adapter dispatch.
- Rejected ambiguous normalized assignment, filter, returning, and tenant
  identifiers before producing a portable command.
- Enforced domain-owned cardinality, returning, and declared-field policy at
  the final compile boundary so callers cannot weaken rollback guarantees.
- Made choice-backed writes require a membership resolver and forward trusted
  actor, tenant, filter, and choice-source context to revalidation.
- Replaced exposed planned-action builders, including contract-only plans, with
  opaque server-registered handles backed by immutable plan snapshots.
- Bound materialization to expiring, phase-specific, single-use authorization
  grants; resolver exceptions, exits, and bounded timeouts now fail closed.
- Bound authorization grants to immutable actor and tenant identity, propagated
  opts-only identity into trusted callbacks, and rejected conflicting context
  and opts or atom/string identity before resolver invocation and grant
  consumption.
- Moved grant consumption ahead of callback-backed choice validation so actor
  or tenant substitution cannot reach a host resolver; later compile failures
  deliberately leave the single-use grant burned.
- Rejected conflicting operation-bound, execution-time, direct compiler-context,
  tenant/tenant-id, nested/outer-field, and atom/string tenant scope sources
  before flat, nested, or batched dispatch.
- Made atomic Multi reject duplicate operation names and adapter result-count
  mismatches instead of overwriting or truncating result mappings.
- Added bounded authorization-lifecycle traces, tenant non-interference, atomic
  Multi, and adversarial trust-boundary models, bringing the executable formal
  suite to 115,444 checks.
- Replaced obsolete PostgreSQL CI jobs with adapter-neutral quality,
  production/no-Ecto, docs, package, Credo, and Dialyzer gates.
- Included the developer action guide and license in the Hex package, and
  updated the coordinated Selecto baseline to `0.4.12`.
- Bumped the package version to `0.4.1`.

## 0.4.0 - 2026-08-11

- Added portable nested insert and owned-child synchronization compiled as an
  atomic `Selecto.Write.Graph`, without SQL, driver, Repo, or Ecto ownership in
  Updato.
- Added recursive relationship contracts with complete child domains,
  cardinality and item bounds, generated parent/child keys, identity fields,
  sync strategy, and delete-missing policy.
- Enforced tenant scope and flat write contracts at every graph level, rejected
  caller ownership-key overrides, and required topological generated values.
- Nested compilation now runs the strict Updato relationship validator before
  graph construction, so misspelled parent, child, and identity fields fail
  before adapter dispatch.
- Added a 24-state bounded-exhaustive nested-graph model with six invariants,
  including invalid cross-domain child keys and bringing the formal suite to
  640 checks.
- Added the detailed portable nested-write architecture and integration guide.
- Updated the coordinated Selecto dependency baseline to `0.4.11`.

## 0.3.2 - 2026-08-10

- Added a bounded-exhaustive portable-command model covering 48 combinations
  of operation, trusted context, required-field presence, and foreign-key
  input, checked against eight domain-boundary invariants.
- Corrected the formal-verification guide so it describes the current four
  portable operations and no longer claims removed bulk or schema-prefix
  states.

## 0.3.1 - 2026-08-10

- Enforced domain-authored `required_on: [:insert]` fields in the portable
  compiler before adapter preview or execution, with form-friendly structured
  validation errors.

## 0.3.0 - 2026-08-10

- **Breaking:** reduced the executable operation surface to portable insert,
  update, upsert, and delete and removed retired bulk-builder, soft-delete,
  changeset, nested-write, hook, cascade, and database-expression APIs.
- Replaced the obsolete repository/changeset integration plan with the
  supported domain, configured-Selecto, and write-adapter integration guide.
- Restricted domain and action operation validation to the same four
  operations so public contracts cannot advertise commands execution rejects.
- Simplified structured errors to adapter-neutral fields and details without a
  changeset or repository compatibility object.
- Enforced domain-owned upsert conflict targets in the portable command path;
  a missing target policy or a caller-selected target outside that policy now
  fails before adapter compilation.
- Added a domain-derived upsert update-field list so immutable,
  non-updatable, and server-managed insert fields cannot be rewritten during
  conflict handling.
- Added release regression coverage proving the retired subsystem is absent.

## 0.2.1 - 2026-08-08

- Completed the adapter-owned write boundary: Updato now produces portable
  commands and requires an explicitly configured Selecto execution adapter,
  without Repo discovery or application persistence callbacks.
- Added concrete multi-row action targets, parameterized `IN` predicates,
  transition guards, trusted tenant filters, and derived exact cardinality for
  atomic bulk actions.
- Expanded domain action planning for variants, collection inputs, governed
  returning projections, foreign-key choice sources, and portable system-time
  values.
- Added the portable write architecture guide and replaced the legacy
  database-specific Livebook with an executable adapter-neutral system guide.
- Updated the packaged Selecto requirement to the 0.4.9+ portable write
  contract line.
- Hardened validation and regression coverage for tenant ownership,
  conditional actions, collection writes, and fail-closed constraints.

## 0.2.0 - 2026-08-05

- **Breaking:** removed the built-in PostgreSQL compiler, driver execution
  adapter, public adapter façade, and live verification task. Configure a
  write-capable Selecto adapter instead.
- Added the adapter-neutral `Selecto.Write` dispatch path for explicitly
  authored domain write contracts.
- Removed Postgrex from Updato dependencies and made the new path independent
  of Ecto application configuration.
- Added trusted tenant binding, portable upsert intent, fail-closed writable
  relationship declarations, and raw-SQL rejection in portable metadata.

## 0.1.5 - 2026-07-29

- Added `mix selecto_updato.verify` with JSON proof artifacts and
  bounded-exhaustive models for write scope, action planning, transition
  preconditions, and capability fail-closed behavior.
- Added package documentation for the exact bounded proof guarantees and
  included the verification guide in Hex package contents.
- Moved PostgreSQL and MSSQL write-adapter routing fully into
  `selecto_updato`, using the built-in generic adapter instead of relying on
  package-owned `UpdatoAdapter` modules.
- Moved MSSQL write-flow coverage into `selecto_updato` and added regression
  tests for generic-vs-specialized write-adapter routing.
- Added compatibility for Selecto `retarget` filter state so
  `filter_from_selecto/2` reads both `post_retarget_filters` and legacy
  `post_pivot_filters` during the pivot-to-retarget transition.
- Updated the packaged `selecto` dependency and README guidance to allow the
  coordinated 0.5 Selecto release line.
- Updated README installation guidance and bumped the package version to
  `0.1.5`.

## 0.1.4 - 2026-03-05

- Added `mix selecto_updato.gen.api` compatibility wrapper task that delegates
  to `mix selecto_api.gen.api` when `:selecto_api` is available.
- Updated README API-generator guidance to position `selecto_api` as canonical
  scaffolding home while preserving wrapper usage.
- Updated wrapper docs to match current generator options and defaults,
  including `/api/v1/updato/<name>`.
- Bumped package version to `0.1.4`.

## 0.1.3 - 2026-03-03

- Updated README installation snippets to `selecto_updato ~> 0.1.3` and
  `selecto ~> 0.3.9`.
- Added README tenant-scope examples for `with_tenant/2`,
  `apply_tenant_scope/2`, and `require_tenant_filter/2|3`, including fail-fast
  scope validation behavior.
- Added `SelectoUpdato.Application` runtime supervision with a dedicated task
  supervisor and startup coverage tests.
- Added execution lifecycle spans for execute/flat/nested/dry-run/transaction
  paths via `:telemetry.span/3`, including success/error/exception metadata.
- Added typed option validation (`NimbleOptions`) for public option-heavy APIs,
  covering `new/2`, `execute/3`, and `execute_in_transaction/3` known options.
- Refactored nested insert/update orchestration to explicit `Ecto.Multi.run`
  phases on Ecto repos, preserving transactional fallback for non-Ecto stubs.
- Added expanded tests for telemetry spans, options validation, supervision, and
  nested multi-step orchestration/rollback behavior.
- Bumped package version to `0.1.3`.

## 0.1.2 - 2026-03-02

- Implemented `insert_from_query` execution via Selecto source query execution and bulk insert.
- Applied lifecycle hook and audit parity for nested insert/update execution paths.
- Added `usage-rules.md` with package guidance for write-path safety in agentic
  workflows.
- Added `MULTI_TENANT_USAGE_PATTERNS.md` with concrete tenant-scoping guidance
  for write filters, prefixes, conflict targets, and audit metadata.
- Added first-class tenant operation helpers via `SelectoUpdato.Tenant` and
  top-level APIs (`with_tenant/2`, `tenant/1`, `apply_tenant_scope/2`,
  `require_tenant_filter/2|3`).
- Updated execution option handling to merge operation defaults and inject
  tenant-derived repo `:prefix` when no explicit prefix is provided.
- Added tenant-focused tests for tenant context normalization, scope filter
  application, and execution option merging behavior.
- Added tenant scope policy helpers (`tenant_required?/2`,
  `validate_tenant_scope/2`, `ensure_tenant_scope!/2`) and enforced scope
  validation in `execute/3` and `dry_run/2` paths.
- Added fail-fast coverage for tenant-required update and insert operations,
  including payload-based tenant scope satisfaction for insert flows.
- Added README/usage guidance for read-to-write pipelines that source data from
  `Selecto.execute_stream/2`, including explicit stream adapter contract
  expectations.
- Bumped package version to `0.1.2`.

## 0.1.1 - 2026-02-21

- Stabilized execution hooks for insert, update, and delete flows.
- Enforced cascade options during delete execution for related records.
- Added audit table persistence support with safe logging fallback.
- Clarified `insert_from_query` API behavior during stabilization.

## 0.1.0 - 2026-02-20

- Initial release of SelectoUpdato.
