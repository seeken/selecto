# Native broad predicates and late atomic-batch rollback

This bounded TW-08/WI-05/WI-10 suite executes actual public root-write
handlers and the governed Updato atomic-batch SDK against PostgreSQL. The
input-only six-column people/five-column orders fixture is shared with the
central and Perl suites. Its SHA-256 is
`48a92d46d40b33b8e6d21f49eec9d4555eddef54b68fe6b00d8af1831dadde15`.
Expected outcomes and independent state models remain outside the fixture.

ABW001/ABW002 exercise missing predicates, `id >= 0`, `not_null`, mixed-tenant
IN lists and false expected counts. Successful broad writes affect only the
trusted tenant's rows; false counts must roll back the entire mutation.
ABW003 checks public `bulk: false`, missing bulk permission, and matched no-op
updates. ABW004 invokes actual `multi_update`/`run` with two governed writes,
requiring real first-statement `RETURNING id,name` before a later foreign-target
or cardinality rejection. Positive no-op and successful batches execute too.

Each of the four cases runs baseline, changed foreign-row and changed secret
datasets: 63 native requests per implementation. Complete trusted rows are
checked before and after every request. Native outcomes, counts and requested
returned rows must match independently computed state transitions.

The Elixir observer traces the actual `Postgrex.query/4` return from the SDK
transaction worker. It retains the real driver results without changing
execution, compilation or authorization. The Perl observer wraps the native
transactional write method's return boundary, calls it with unchanged arguments
and returns its unchanged result. Neither observer supplies a successful result.
Missing first-phase evidence fails the central ABW004 expectation even if
the final database is unchanged.

## Run

Provide an isolated host runtime containing `db_connection`, `postgrex`,
`selecto_db_postgresql` and `selecto_api`, compiled with the same Elixir/OTP.
These packages remain outside Updato's production dependencies. The verified
runtime was Elixir 1.20 / OTP 29.

```sh
mise exec -- env MIX_ENV=test \
  MIX_BUILD_PATH=/tmp/selecto-required-scope-adversarial-build \
  SELECTO_ECOSYSTEM_USE_LOCAL=1 \
  SELECTO_ADVERSARIAL_RUNTIME_PATH=/tmp/selecto-mcp-adversarial-build/lib \
  SELECTO_BROAD_WRITE_DATABASE_URL=postgres://postgres@127.0.0.1:55471/selecto_adv_broad_writes \
  mix test test/native_broad_write_test.exs

mise exec -- env MIX_ENV=test \
  MIX_BUILD_PATH=/tmp/selecto-required-scope-adversarial-build \
  SELECTO_ECOSYSTEM_USE_LOCAL=1 mix precommit
```

Use a disposable loopback `selecto_adv_*` database on a port other than 5432.
The suite creates and drops only `selecto_cert_adv_people` and
`selecto_cert_adv_orders`. Enabled native suites require working configuration;
without the host-runtime variable they are excluded from the default gate.

On 2026-10-07 all four native tests passed. The combined existing, TW-07 and
broad-write suites passed 336 checks (329 tests and seven properties). The
required precommit gate passed 329 checks, including strict compilation,
formatting, portable-boundary checks, Credo/atom audit, bounded formal checks
and compile-cycle checks.

## Boundaries

Public root handlers return actual 200/422 statuses. Missing predicates and
public bulk refusals return `invalid_api_write`; false scoped counts return
`cardinality_mismatch`. SDK batch outcomes use portable status classifications,
not an observed HTTP batch endpoint. Elixir returns `cardinality_mismatch` for
both late batch refusals; Perl returns `write_returning_missing` for the foreign
zero-row `RETURNING` and `cardinality_mismatch` for the false nonzero count.
Central comparison validates those exact native codes before normalizing their
shared atomic cardinality meaning.

The public cases claim O1–O5 with actual sanitized public bodies. ABW004 claims
O1–O4; native SDK diagnostics and phase receipts are trusted evidence, so it
does not claim public transport hygiene. No-op matched cardinality is proven
for PostgreSQL only. This slice does not certify MySQL FOUND_ROWS, other SQL
adapters, arbitrary upserts, authentication middleware, every batch shape or
the full adversarial plan. Existing trusted SDK bulk semantics and unresolved
capability/post-image policy decisions remain unchanged.
