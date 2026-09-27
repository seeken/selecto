# Canned search pages

`Selecto.CannedPage` is HTTP-neutral. A definition owns one domain, fixed dataset
filters, authored detail/aggregate query templates and promoted controls. A host
supplies a newly authorized, unprojected `%Selecto{}` for every execution.

```elixir
base = Selecto.configure(domain, connection, adapter: adapter)
page = Selecto.CannedPage.new!(base,
  id: "products",
  views: [%{id: "detail", kind: :detail,
    query: Selecto.select(base, ["id", "name", "category"])}],
  controls: [
    %{id: "category", kind: :facet, field: "category", searchable: true},
    %{id: "name", kind: :text, field: "name"}
  ])

authorized = Selecto.filter(base, {"account_id", trusted_account_id})
{:ok, result} = Selecto.CannedPage.run(page, authorized,
  %{"filters" => %{"category" => ["food"], "name" => "A"}})
```

The authorized query must use the definition's domain. Runtime, policy and
tenant context remain attached to all plans. Fixed dataset filters and required
filters cannot be removed through browser state. `normalize_state/2` validates
state without a database; `plan/3` returns query objects for inspection;
`run/3` executes through public metadata APIs in the caller's process,
preserving a host-owned transaction or sandbox checkout.

State has string keys: `version`, `view`, `filters`, `facet_search`, `drilldown`,
`page`, `limit`. Unknown keys, views and control IDs fail closed. Missing filters
use initial defaults; an empty filters map clears them. Results include rows,
columns/aliases, normalized state, facets, `total` (distinct matching entities),
`result_total` (result rows, including aggregate groups), `has_more`, timing and
execution metadata. Avoid exposing raw execution metadata or database errors to
untrusted clients.

The first profile supports a single root primary key, entity-grain detail
fields, direct related JSON collections, grouped distinct-root counts, literal
case-sensitive text prefixes, numeric ranges and OR-checkbox facets. Facet
counts omit only their own control predicate; selected values remain present
even beyond the bounded option list. It does not support arbitrary sums,
composite identities, null buckets, retargeting or cross-statement snapshot
guarantees. Related collection fields must be authorized by the host domain.

For the reusable LiveView host, URL/private-state integration, layouts and
governed links, see `selecto_views/docs/canned-pages.md` in the sibling package.
The shared protocol's relational fixture is exercised independently by
Perl/SQLite and Elixir/PostgreSQL; this is not certification of other adapters.
