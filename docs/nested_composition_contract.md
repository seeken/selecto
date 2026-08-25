# Nested Composition Contract

Selecto's general nested contract models governed business-object semantics,
not arbitrary nested JSON. Database foreign keys provide physical provenance;
they never imply ownership, delete authority, tenant inheritance, or an
executable client surface.

## Public APIs

```elixir
{:ok, composition} = Selecto.Domain.composition_contract(domain)

{:ok, release} =
  Selecto.Domain.consumer_projection_release(domain,
    projection_id: "order-editor",
    runtime: "selecto_components",
    adapter: "web"
  )

diff = Selecto.Domain.compare_consumer_projections(previous, release)
matrix = Selecto.Domain.nested_capability_matrix()
```

`composition_contract/1` normalizes atom/string input into the deterministic
`selecto.composition_contract.v1` shape. A release embeds that contract with
the exact Experiences, Operations, target certification profile, required
features, dependencies, and fingerprint in
`selecto.consumer_projection_release.v1`.

## Relationship meaning

Every relationship declares one ownership kind:

- `composition`: the child has an aggregate-owned lifecycle and may support
  nested create, update, delete, reorder, and explicit omission behavior;
- `shared_association`: the target has an independent lifecycle; a parent may
  link/unlink it but cannot mutate or delete it as an owned child;
- `join_association`: link rows and join metadata are distinct from either
  endpoint;
- `derived`: the relationship is a read projection unless a named Operation
  supplies separate write meaning;
- `deferred`: attachment/submission authority and eventual lifecycle live
  outside the local graph transaction.

The delivered aliases `owned`, `shared_reference`, and `join_only` normalize
to the corresponding canonical meanings. They remain accepted so existing
Domains do not silently change behavior.

## Required policy

A writable relationship carries stable `path_id`, cardinality, physical
parent/child bindings, authoritative identity fields, optional client identity,
bounded read and write policy, exact mutation modes, operation flags,
capabilities, tenant scope, conflict and idempotency policy, offline eligibility,
validation/Assurance policy, and normalized output/evidence rules.

The portable validation subset is explicit: numeric child-field bounds,
cross-child uniqueness, and sum aggregate limits scoped to named mutation
representations. Aggregate-wide rules are certified for `full_set`, where the
submitted collection is complete; a delta rule cannot assume that omitted
persisted children have disappeared. Unknown validation concepts become
required consumer features and block a target that has not declared support.

Nested reads require explicit depth and row bounds. Writable collections
require item/mutation bounds. Full-set must declare what omission means. Offline
mutation requires stable identity, conflict, and idempotency controls. Shared
or join relationships reject owned-target create/update/delete semantics.

Known policy is normalized deterministically. Unknown relationship concepts
survive under `extensions`; an executable consumer projection rejects them
unless the target explicitly declares support. `preserve_only: true` permits a
non-executable archival projection without flattening the authored meaning.

## Mutation representations

The five representations are deliberately non-interchangeable:

- `append_only`: add children only;
- `delta`: explicit create/update/delete groups; omissions are unchanged;
- `full_set`: complete desired collection plus explicit omission policy;
- `replace_one`: one explicit create/update/delete intent for a to-one path;
- `link_delta`: explicit link/unlink of shared or join identities.

Consumers select one declared representation for an Operation. A submitted
mode that differs from the Operation contract is rejected; it is never guessed
or converted.

## Compatibility and coexistence

`compare_consumer_projections/2` classifies changes by stable relationship
path. Ownership, cardinality, identity, tenant, capability, ordering,
validation, conflict, idempotency, Assurance, omission, or removal changes are
breaking. Removing a
mode or narrowing a bound is breaking; expanding modes or limits is compatible
unless another policy changes.

Releases are immutable values. A registry may retain multiple fingerprints and
versions while clients migrate; the current Domain is not consulted to
reinterpret an older release.

## Certification boundary

`nested_capability_matrix/0` distinguishes implemented features from finite
live evidence and names the maximum compiler depth, live-certified depth and
row count, evidence fixture, and proof boundary for each runtime/adapter pair.
Publication fails closed when the requested target lacks a required feature.

The matrix is not a claim of arbitrary database correctness. Bounded models
cover finite contract states; adapter suites separately exercise finite live
transaction, constraint, returning, identity-mapping, and rollback cases.

## Migrating custom forms and APIs

1. Inventory each existing nested payload and classify every relationship.
2. Give every role a stable path, including repeated roles to the same table.
3. Declare identity, trusted tenant/parent bindings, child field allowlists,
   capabilities, bounds, conflict fields, and omission behavior.
4. Choose one exact representation per Operation; prefer delta for large,
   concurrent, or offline collections.
5. Compile consumer releases and resolve every unsupported target diagnostic.
6. Run both the bounded verifier and the live adapter fixture for the exact
   claimed profile.
7. Migrate one consumer to its pinned release, compare outcomes and identity
   mappings, then retain the older release until its support window closes.

Do not preserve a custom endpoint's ambiguous “missing means delete” behavior.
Turn it into an explicit full-set omission policy or a delta delete operation.
