# Governed lookups and SQL-backed eligibility

`co_domains` is an implemented canonical schema-v1 section. The declarations
are defined in [Domain schema v1](domain_schema_v1.md#co-domain-lookups).
Runtime, adapter, and frontend claims remain profile-specific.

## Host-owned target and scope

The source domain declares a `co_domains` entry naming a target domain and its
query-library view (or projection with optional segments and ordering). The
target owns those definitions. The host resolves a configured target engine
and trusted scope; neither connections nor engines come from browser input.

Given a source declaration `:carriers` whose target view selects the declared
value, label, and description fields, this host-side fragment executes a lookup:

```elixir
# source_domain and target are loaded/configured by the host.
# trusted_tenant_id comes from verified identity, not a request parameter.
{:ok, %{results: results}} =
  Selecto.CoDomain.lookup(source_domain, target, :carriers, "Den",
    scope: {"tenant_id", trusted_tenant_id},
    limit: 20
  )
```

When the target domain declares `source.tenant_field`, the lookup requires a
tenant boundary (certification specification 2.19.0): a positive tenant
conjunct (equality to a defined scalar, or a nonempty IN list, at the top level
or beneath AND) in the target's required or host filters or in `scope`, or a
trusted tenant attached with `Selecto.with_tenant/2`, which is then ANDed into
the lookup. Any other scope, including a tenant condition beneath OR or NOT,
fails: `lookup/5` returns `{:error, %Selecto.Error{details: %{code:
:missing_tenant_scope}}}` and `plan/5` raises a `RuntimeError` whose message
starts with `missing_tenant_scope`. Domains without `tenant_field`
are unchanged. See `Selecto.Tenant.tenant_boundary/2`.

Return only `results` to the browser; the returned `query` is host-side metadata.
`Selecto.CoDomain.plan/5` builds the same query without executing it. Target
required filters are retained and host scope is conjoined. Lookup text is
1–200 characters without NUL; limits are 1–100. Prefix terms are bound values,
tokenless prefix input returns no results, and optional ranking precedes named
ordering. The target adapter must advertise governed lookup text search in the
requested mode. The local PostgreSQL adapter implements it; other adapters
must not silently substitute an ungoverned search.

SQLite governed lookup uses an ordinary root table and an explicitly supplied,
host-maintained external-content FTS5 index. Declare
`source.fts5_index: %{table: "people_fts", key: :id}` on the configured target;
the declaration is preserved as authored metadata and does not create an index
or grant access. `key` must be the public stored integer primary key. The SQLite
adapter checks the connected main catalog, index content identity, indexed text
fields, default `unicode61` tokenizer and `full` detail. TEMP shadows, joined,
computed or internal search fields refuse. Plain, phrase and normalized prefix
searches bind their text; descending relevance precedes named ordering while
required, tenant, named and request filters continue to intersect.

The complete synthetic source/target domains and live example are in sibling
`selecto_db_postgresql/test/selecto_db_postgresql/co_domain_test.exs`. Run from
that repository with its documented PostgreSQL test connection configured:

```sh
SELECTO_ECOSYSTEM_USE_LOCAL=1 mise exec -- mix test test/selecto_db_postgresql/co_domain_test.exs --include postgres
```

The fixture checks tenant and segment isolation, bound prefix search, ranking,
bounded results, and invalid requests. It is not central cross-runtime lookup
certification. Endpoint authorization, rate limits, target resolution, and
revalidation of selected values at mutation time remain host responsibilities.

## Selection eligibility is presentation, not authorization

An action can declare `selection: %{eligibility_field: :ready_for_dispatch}`
for a boolean root column, optionally using a computed predicate. Declare the
column in both `source.fields` and `source.columns`, together with all referenced
root columns. The computed-predicate AST is distinct from the authored action
precondition grammar; do not copy one grammar into the other.

`internal: true` is a UI hint, not an access-control boundary. The local
`selecto_components` detail table preselects eligibility data and filters IDs
per action. Missing/false eligibility cannot enable selection. The host must
still enforce action `preconditions`, tenant scope, capability decisions, and
affected-row cardinality atomically. Eligibility can change after rendering.

Grouped/co-domain action inputs in the upstream Perl UI are not yet ported to
the LiveView frontend. Metadata preservation alone does not implement a lookup
control. Existing action-filter certification does not cover these local ports.
