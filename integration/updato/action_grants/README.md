# Native action-grant lifecycle slice

This opt-in suite tests native Updato action grants and real PostgreSQL writes.
The owned table contains tenant 7 eligible rows, a wrong-owner row, a
wrong-amount row, and a tenant 8 row that satisfies both host predicates.
The baseline, changed foreign data, and changed secret values run the same
probes. Tests independently assert the complete input state, every refused
operation's unchanged state, every accepted operation's exact affected count
and full effect, and identical native outcomes across the three datasets.

The explicit capability is `people.rename`. The host resolver authorizes the
exact phase, and the required predicate is `owner_id = 42 AND amount < 25`,
combined with canonical trusted tenant 7. Accepted row/bulk controls prove
the guarded native path actually writes. Mutations cover the materialized
payload, target filter, returning fields, domain fingerprint, captured query
guard, and the `choice_source_context` operation option. The option probe
proves grant binding of that key; it does not exhaust choice-source admission.
Separate probes cover actor/tenant substitution, consumed grants, grant expiry,
and fresh grants after expiry. A distinct preview grant returns the PostgreSQL
adapter's actual preview and leaves all rows unchanged. Preview receipts are
classified as `previewed`, never as database effects.

The initial runtime reproduced a documented defect: an execute grant survived
a rejected preview-phase substitution. Restoring the original context and
retrying the same builder then actually updated row 1. The complete native
before/after states and driver result are retained in
`/tmp/selecto-action-grants-native-red.test-a22714df247c.json`; the failed test
is in `/tmp/selecto-action-grants-native-red.log`. This was a grant-lifecycle
failure, not a tenant leak. A second real native-service reproduction showed
the same early-refusal problem for a registered contract-only plan:
`consume_plan(preview)` refused, but `consume_plan(execute)` then returned
`:ok`. That evidence is `/tmp/selecto-action-grants-contract-only-red.log`.

The compiler now synchronously invalidates an identified grant on any returned
compilation error. Contract-only consumption similarly invalidates its genuine
plan grant on early admission failure. First refusal types/codes are retained;
restoring the original builder/context produces
`unregistered_action_authorization`. Ordinary operations without an action
grant retain their existing behavior. The action resolver, grant issuer, TTL
bounds, and nil-capability defaults are unchanged. This implements the existing
phase/substitution invalidation contract in
`docs/developer_action_guide.md:265` and its validation-failure rule at line 270.

## Changed host eligibility

A privileged fixture update changes a row's owner after grant issuance. The
captured guard is checked inside the actual write: execution reports
`cardinality_mismatch`, retains all rows, and burns the grant. Fresh plans
under changed owner and amount predicates have both refusal and accepted
controls. Fresh action authorization under a disabled host permission refuses
before native dispatch.

The SDK execution target supplies the adapter and connection. Substituting only
that target's query leaves the original sealed predicate intact. The suite
retains this snapshot behavior explicitly, including its real accepted effect.
It does not claim automatic immediate revocation when an arbitrary host
permission or query changes after issuance. Hosts must establish the current
policy before creating and authorizing a new plan. The trusted execution
adapter must forward its authorized context unchanged.

## Run

Native database packages remain outside Updato's production dependency graph.
Use a compiled host runtime with compatible Elixir/OTP and the PostgreSQL
adapter. The database must be a fresh disposable loopback `selecto_adv_*`
database on a port other than 5432. The suite refuses to overwrite an existing
table and creates/drops only `selecto_cert_action_grant_people`.

```sh
mise exec -- env MIX_ENV=test SELECTO_ECOSYSTEM_USE_LOCAL=1 \
  MIX_BUILD_PATH=/tmp/selecto-action-grants-build \
  SELECTO_ACTION_GRANT_RUNTIME_PATH=/tmp/selecto-adversarial-certification-build/lib \
  SELECTO_ACTION_GRANT_DATABASE_URL=postgres://postgres@127.0.0.1:55471/selecto_adv_action_grants \
  SELECTO_ACTION_GRANT_EVIDENCE_PREFIX=/tmp/selecto-action-grants-native-final \
  mix test test/native_action_grants_test.exs \
    test/selecto_updato/action_grant_early_refusal_test.exs
```

The seven database-backed tests observe 135 SDK invocations, including preview
and refused calls; this is not a count of executed SQL mutations. Four focused
unit tests separately exercise early refusal in both compiler entry points,
pre-callback invalidation, normal single-use compilation, and the native
contract-only grant service. Evidence preserves actual native results and full
states outside public response comparisons; no HTTP status is invented.

The required `mix precommit` gate includes strict compilation/formatting,
portable dependency checks, Credo/atom audit, tests, nine bounded verification
suites, and the compile-cycle check. Enable this suite with
`SELECTO_ACTION_GRANT_RUNTIME_PATH`; the older required-scope and broad-write
native suites use `SELECTO_ADVERSARIAL_RUNTIME_PATH` and their respective
database URL variables.

On 2026-10-07, the combined required gate passed 340 tests and seven properties
with all three native suites enabled, no skips, and all nine bounded model
suites proved. The grant suite's 135 SDK calls comprise 24 accepted writes,
105 refusals and six real adapter previews. The focused grant tests passed
seven native and four unit tests. The final gate log is
`/tmp/selecto-action-grants-precommit-final.log`; native evidence uses the
`/tmp/selecto-action-grants-final.*.json` prefix. The separately retained bounded
model report is `/tmp/selecto-action-grants-verification-final.json`.

## Proof boundaries

This is bounded PostgreSQL SDK evidence for AC-01, AC-02, AC-03, AC-04, TW-10
and a row-eligibility race control. It is not action HTTP authentication,
generated API grant replay, SPA/LV/MCP token replay, arbitrary option mutation,
host-command effects, graph actions, all adapters, concurrent/idempotent
execution, or production deployment. Contract-only tests prove the native
service's grant consumption, not a host-command database effect. The core
Selecto process-local portable-write authorization is a separate boundary and
was not changed. The complete original AC scenarios and all seven release
gates remain unverified.
