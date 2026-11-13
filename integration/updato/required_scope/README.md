# Native required-predicate graph and action slice

This opt-in TW-07 suite invokes the public Updato SDK and actual
`SelectoApi.EngineWriteHandler.execute/3` against real PostgreSQL. Each test
runs the baseline, changed foreign-row, and changed secret-value datasets,
checks full trusted state before and after every probe, and compares actual
native outcomes across variants. No capture adapter supplies success or rows.

The input-only JSON matches the central required-scope fixture at SHA-256
`5e7b546a4e4c09ff0973f1be7aebea521884fc20188f64f77e75dabc3f701118`.
Its dedicated seven-column people table includes `owner_id`; orders retain
their five-column layout. Expectations live in tests, outside the fixture.
The loader translates only a closed set of committed domain names and values.

The host predicate is `owner_id = 42 AND amount < 25`, combined with trusted
tenant 7 and `writes.scope.tenant`. The wrong-owner row satisfies the amount
guard, the wrong-amount row satisfies the owner guard, and the foreign-tenant
row satisfies both host guards. Tests assert this separation in every variant
before invoking native operations. Concrete mixed targets must roll back all
effects. Successful graph, row-action, and bulk-action controls demonstrate
that the same public methods execute in-scope requests.

The native regression exposed an action-planner defect: passing a scoped
`Selecto` kept its domain but discarded its eligibility predicates. A wrong
owner's row was actually updated. Action planning now captures a nonempty
query guard before sealing the plan, so the action authorization grant binds
the same guard later used by execution. Raw domain plans and actions without
a declared capability retain their existing trusted SDK behavior.

## Run and verification

Supply a compiled host runtime containing `db_connection`, `postgrex`,
`selecto_db_postgresql`, and `selecto_api`, built with the same Elixir/OTP as
this package. The verified run used Elixir 1.20 / OTP 29. Database packages
remain outside Updato's production dependency graph.

```sh
mise exec -- env MIX_ENV=test \
  MIX_BUILD_PATH=/tmp/selecto-required-scope-adversarial-build \
  SELECTO_ECOSYSTEM_USE_LOCAL=1 \
  SELECTO_ADVERSARIAL_RUNTIME_PATH=/tmp/selecto-mcp-adversarial-build/lib \
  SELECTO_REQUIRED_SCOPE_DATABASE_URL=postgres://postgres@127.0.0.1:55471/selecto_adv_required_scope \
  mix test test/native_required_scope_test.exs

mise exec -- env MIX_ENV=test \
  MIX_BUILD_PATH=/tmp/selecto-required-scope-adversarial-build \
  SELECTO_ECOSYSTEM_USE_LOCAL=1 mix precommit
```

The database must be a disposable loopback `selecto_adv_*` database on a port
other than 5432. Tests create and drop only `selecto_cert_required_people` and
`selecto_cert_required_orders`. Missing native configuration fails explicitly
when the suite is enabled; omitting the host runtime variable excludes it from
the default gate.

On 2026-10-07, all three native tests passed. The combined native and existing
suite passed 332 checks (325 tests and seven properties). The required
precommit gate passed 329 checks (322 tests and seven properties), including compilation, formatting,
portable-boundary checks, strict Credo, atom audit, bounded verification suites,
and the compile-cycle check.

## Boundaries

Graph roots use the documented explicit `enforce_query/2` SDK method. Actions
use `plan_domain_action/3` with a scoped `Selecto`, followed by
`ActionExecutionAdapter.execute/4` and a host adapter that forwards the
authorized builder and unchanged context to native Updato execution.
The actual API handler test is a flat root write, not a graph/action HTTP
endpoint. Generated API action execution is a distinct native generator suite.

Central ARS001/ARS002 independently assert exact native codes and full state
before producing a common semantic comparison. Elixir reports
`cardinality_mismatch`; Perl reports `write_returning_missing` for a graph
whose root matches no rows and `cardinality_mismatch` for mixed graph/action
targets. These SDK outcomes use portable status classifications, not HTTP
status observations. Public root-handler errors are separately checked for
their actual 422 code and sanitized body.

This slice does not certify transport authentication, every graph representation,
child-domain host predicates, post-image owner reassignment, arbitrary upserts,
other SQL adapters, or a changed capability default. Native SDK diagnostics
remain trusted evidence, so ARS001/ARS002 make no public transport hygiene claim.
The named TW-07 slice remains narrower than the full plan.
