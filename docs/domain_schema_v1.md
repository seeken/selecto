# Selecto Domain Specification — Schema Version 1

This document is the normative specification for Selecto domain maps and the
normalized domain contract in Selecto 0.5. Normative words such as **MUST**,
**MUST NOT**, **SHOULD**, and **MAY** have their usual requirements-language
meaning.

A Selecto domain is a declarative, versioned description of the data,
relationships, query surfaces, write permissions, actions, choices, capability
names, and event contracts that an application elects to expose. It is a governance
contract for operational applications; it is not a database schema dump, an
authorization decision engine, or a substitute for database roles, constraints,
transactions, and row-level security.

## Scope And Representations

The domain contract has three deliberately distinct representations:

1. **Authored domain** — the Elixir map supplied by an application, generator,
   or overlay. This is the representation consumed by `Selecto.configure/3`.
2. **Normalized domain** — the deterministic envelope returned by
   `Selecto.Domain.normalize/1` or `Selecto.Domain.validate/1`. It classifies
   sections, expands supported shorthand, and exposes stable consumer
   projections without mutating the authored input.
3. **Runtime configuration** — the adapter-aware query configuration compiled
   by `Selecto.configure/3`. It is an internal runtime structure, not a portable
   serialization format.

These representations are related but not interchangeable. In particular,
`Selecto.configure/3` validates and compiles the authored map; it does not replace
that map with the normalized envelope. Consumers that need a stable portable
contract MUST call `Selecto.Domain.validate/1` and use one of the documented
projections rather than depending on runtime configuration internals.

## Conformance

An authored domain conforms to schema version 1 when all of the following hold:

- it is a map containing valid `source` and `schemas` sections;
- `Selecto.Domain.validate/1` returns
  `{:ok, normalized, diagnostics}`;
- every warning relevant to the producer's deployment policy has been reviewed;
- if the domain will be passed to `Selecto.configure/3`,
  `Selecto.DomainValidator.validate_domain/1` also returns `:ok`.

The two validators have different jobs. `Selecto.Domain.validate/1` validates
the normalized schema-v1 contract, including writes, actions, capabilities,
choice sources, and field bindings. `Selecto.DomainValidator.validate_domain/1`
validates the authored shape used by the current query runtime, including join
cycles and runtime-oriented association requirements. A producer MUST NOT treat
one as proof that the other representation is valid.

`Selecto.configure/3` runs authored-domain validation by default after applying
declared extension callbacks. Passing `validate: false` disables that check in
permissive mode and is therefore outside the recommended conformance path.
Strict mode rejects `validate: false`.

Normalization and validation do not connect to a database, execute queries or
writes, invoke query-builder functions, resolve authorization, or prove behavior
for arbitrary adapters and database states. Database-backed verification remains
a separate evidence layer.

## Version And Identity

Generated domains should declare the current schema version:

```elixir
%{
  schema_version: 1,
  domain_version: "0.1.0",
  domain_fingerprint: "sha256:9f5d...",
  name: "Orders",
  source: %{
    source_table: "orders",
    primary_key: :id,
    fields: [:id],
    columns: %{id: %{type: :integer}}
  },
  schemas: %{},
  joins: %{}
}
```

When `schema_version` is missing, `Selecto.Domain.normalize/1` infers version
`1` and returns a `:schema_version_inferred` warning. Invalid versions fall back
to the current version with an `:invalid_schema_version` warning. Newer positive
integer versions are preserved and receive an `:unsupported_schema_version`
warning.

`schema_version` is the machine compatibility version for the canonical Selecto
domain schema, and should remain a positive integer.

`domain_version` is optional authored-domain metadata. It is an opaque
non-empty atom, string, or integer that a host can use for semantic versions,
date-based releases, or generated build ids:

```elixir
domain_version: "0.5.0"
domain_version: "2026-05-12"
```

`domain_fingerprint` is optional authored-domain identity metadata. It is an
opaque non-empty string, usually a content hash or stable generated-artifact
fingerprint:

```elixir
domain_fingerprint: "sha256:9f5d..."
```

Selecto core preserves a supplied fingerprint but does not compute one during
normalization.

## Key And Identifier Rules

The normalized schema accepts known structural keys in atom or string form.
Field, registry, relation, action, and capability identifiers are normally
non-empty atoms or strings. For comparison, most identifiers normalize to their
string representation, so producers MUST NOT declare both `:status` and
`"status"` in the same logical registry. Contracts that detect such collisions
fail closed instead of selecting a winner.

Dotted strings such as `"customer.name"` identify a field through a declared
schema or relationship path. They MUST be non-empty and MUST NOT start or end
with `.`, or contain `..`, where a static source path is required.

JSON with string keys is a portable interchange representation for
normalization, validation, and projection. The current query runtime expects an
Elixir-authored domain with the atom keys used by its public API. A host loading
JSON for runtime use MUST translate only the documented finite key and enum set;
it MUST NOT create atoms from arbitrary untrusted strings.

## Top-Level Sections

The normalizer classifies authored top-level keys into four categories.

### Canonical

Canonical sections are part of the current domain contract:

- `schema_version`
- `domain_version`
- `domain_fingerprint`
- `name`
- `source`
- `schemas`
- `joins`
- `default_selected`
- `required_selected`
- `required_filters`
- `required_order_by`
- `required_group_by`
- `filters`
- `functions`
- `query_members`
- `query_library`
- `domain_dependencies`
- `operations`
- `experiences`
- `published_views`
- `detail_actions`
- `components`
- `domain_data`
- `extensions`
- `co_domains`

### Projection

Projection sections are recognized implementation or consumer-facing sections.
They are part of the schema-v1 input vocabulary, but diagnostics call them out
because portable consumers SHOULD obtain them from a named projection:

- `columns`
- `custom_columns`
- `json_schemas`
- `subfilters`
- `window_functions`
- `pagination`
- `retarget`
- `redact_fields`

### Proposed (Diagnostic Category Name)

The `:proposed` name is retained by the section-classification diagnostics for
compatibility. In Selecto 0.5 these are implemented, normalized, validated
schema-v1 contracts; the label does **not** mean that they are ignored or merely
planned:

- `writes`
- `actions`
- `events`
- `capabilities`
- `source_relationships`
- `choice_sources`

### Unknown

Any other top-level key is unknown and appears in diagnostics. The authored map
is retained for inspection, so an unknown value may still be visible under
`authored_domain` or `domain`; it is not assigned portable semantics and named
projections are not required to expose it. Producers MUST migrate or remove old
experimental keys rather than interpreting their preservation as compatibility
support.

## Normalized Envelope

Successful normalization returns `{:ok, normalized, diagnostics}`. The envelope
has this stable schema-v1 organization:

| Key | Meaning |
| --- | --- |
| `schema_version` | Parsed or inferred schema compatibility version. |
| `domain_version` | Optional authored release label. |
| `domain_fingerprint` | Optional authored identity value; never computed by core. |
| `authored_domain` | Original input map, unchanged. |
| `domain` | Canonical authored map after version insertion and shorthand expansion. |
| `sections` | Keys grouped as `canonical`, `projection`, `proposed`, and `unknown`. |
| `source`, `schemas`, `joins` | Core relation and join sections. |
| `query` | Query defaults, filters, functions, members, portable query-library definitions, and published views. |
| `projection` | Display and implementation-facing projection metadata. |
| `writes`, `actions`, `events`, `capabilities` | Mutation, immutable-fact, and governance registries. |
| `source_relationships`, `choice_sources`, `co_domains` | Cross-domain reference and governed lookup registries. |
| `domain_dependencies` | Consumer requirements against named provider contracts. |
| `operations`, `experiences` | Application-operation and consumer-experience registries carried by dedicated consumer releases. |
| `detail_actions`, `components` | Detail-row actions and canonical component-facing UI policy. |
| `domain_data`, `extensions` | Host data and declared extension specifications. |

Missing map registries normalize to `%{}` and missing list-style sections to
their projection-specific defaults. A normalized envelope is identified by its
`schema_version`, `domain`, `query`, `projection`, and `sections` structure; an
arbitrary authored map MUST NOT be passed directly to `Selecto.Domain.project/2`.

Diagnostics are data, not log messages. Errors make `Selecto.Domain.validate/1`
return `{:error, diagnostics}`. Warnings do not, but producers SHOULD review
invalid shapes, inferred or unsupported versions, classified projection or
proposed sections, composition collisions, and unknown keys according to their
deployment policy.

## Core Relation Shape

The schema-v1 contract validates `source` and every entry in `schemas` as
relation maps. A relation map uses this shape:

```elixir
%{
  source_table: "orders",
  primary_key: :id,
  fields: [:id, :status, :total],
  columns: %{
    id: %{type: :integer},
    status: %{type: :string},
    total: %{type: :decimal}
  },
  associations: %{
    customer: %{
      queryable: :customers,
      owner_key: :customer_id,
      related_key: :id
    }
  }
}
```

Validation checks:

- `source` and `schemas` must be present in the authored domain.
- `source_table` must be an atom or string.
- `primary_key` must be an atom or string and must appear in `fields`.
- `fields` must be a list.
- `columns` must be a map.
- Every listed field must have a matching column definition.

Optional `source_kind` is `:table`, `:view`, or `:materialized_view`; optional
`readonly` is boolean. These properties describe the relation source but do not
grant or revoke write authority: only the explicit `writes` contract does that.

Column definitions are open metadata maps. Query consumers commonly use
`type`, labels, formatting, aggregate, filter, sort, capability, choice,
reference, and colocated write metadata. Schema-v1 validators enforce the
properties described in this document; consumers MUST ignore unknown display
metadata unless they explicitly define it and MUST NOT derive SQL identifiers
or write permission from arbitrary values.

`joins` must be a map when present. Each join key must be declared as an
association on its parent relation, and each association must point at a schema
available in `schemas` unless it explicitly targets `:source`.

An association MUST be a map with `queryable` naming its target schema. Runtime
associations normally also declare `field`, `owner_key`, and `related_key` so the
join compiler can bind the relationship. A join entry is a map keyed by the
association id and MAY contain nested `joins`; nested joins are resolved against
the target relation. Authored runtime validation rejects missing associations,
missing target schemas, dependency cycles, and incomplete metadata required by
advanced join types. Join `type`, display fields, cardinality, and advanced
dimension or hierarchy options are runtime query configuration; they do not
confer write or authorization rights.

## Projection And Host Metadata

The projection-category sections separate consumer presentation and advanced
query metadata from the structural relation contract:

| Key | Shape | Meaning |
| --- | --- | --- |
| `columns` | map | Overlay-style root column customizations; `Selecto.Config.Overlay.merge/2` deep-merges them into `source.columns`. |
| `custom_columns` | map | Domain-declared computed or expression-backed query fields. Their ids join the known-field index. |
| `json_schemas` | map | Typed schemas for structured JSON columns; the overlay DSL can attach each entry to its source column. |
| `subfilters` | map | Named advanced subfilter metadata consumed by supporting query paths. |
| `window_functions` | map | Named window-function metadata for supporting consumers. |
| `pagination` | map | Domain pagination metadata. |
| `retarget` | map | Domain retargeting metadata for query consumers. |
| `redact_fields` | list | Projection redaction declarations; composition unions them and runtime overlay merging also unions them into `source.redact_fields`. |

Except for the references and shapes explicitly validated elsewhere in this
specification, these are open consumer contracts. Core normalization checks the
map/list category and preserves the values; it does not claim that every
adapter or companion package implements every option. A consumer MUST document
and validate any narrower subschema it relies on.

`domain_data` is opaque host metadata preserved in the normalized envelope and
runtime configuration. Portable consumers MUST NOT infer query, write, or
authorization rights from it. `extensions` is an ordered list of extension
specifications resolved through `Selecto.Extensions`; extension callbacks are
trusted host code and MAY contribute domain metadata, overlay DSL modules,
adapter type mapping, and companion-package integrations.

## Query Field Lists

The normalized contract validates query field-list metadata before runtime query
execution:

- `default_selected`
- `required_selected`
- `required_order_by`
- `required_group_by`

Each section must be a list when present. Direct atom/string field references
must refer to known fields from the root `source`, joined `schemas` using
`"schema.field"` paths, or `custom_columns`.

Explicit UDF references using `{:udf, function_id, args}` are checked against
the function registry when they appear in selected, ordered, or grouped query
field lists. Aliased selectors such as `{:field, {:udf, function_id, args},
alias}` are checked the same way. The validator checks that the function id is
a non-empty atom or string, exists in `functions`, and is allowed for the query
call site when `allowed_in` is declared. It does not inspect UDF argument
values or compile SQL.

For registered UDFs with `args` metadata, query-list validation also checks
argument count. Arguments declared with `source: :selector` get static field
reference validation for direct atom/string selectors and nested UDF references.
Arguments declared as `:value` or `:literal` are left to runtime execution
validation.

Order entries may use a direct field, `{field, direction}`, or
`{direction, field}`. Supported directions are `:asc`, `:desc`,
`:asc_nulls_first`, `:asc_nulls_last`, `:desc_nulls_first`, and
`:desc_nulls_last`.

Group entries may use direct fields or wrapper tuples such as
`{:rollup, fields}` and `{:grouping_set, fields}`. Tuple/map expressions that
are not direct field references are left permissive in this slice.

Invalid query list metadata produces `:invalid_section_shape`,
`:invalid_query_field_reference`, `:query_field_not_found`,
`:invalid_query_order_direction`, `:invalid_query_group_wrapper`,
`:invalid_query_function_id`, `:query_function_not_found`, or
`:query_function_call_site_not_allowed`, or
`:query_function_arg_count_mismatch` diagnostics.

## Filter References

The schema-v1 contract also validates filter registry metadata and filter
references. `filters` must be a map. Each filter id must be a non-empty atom or
string, and each filter config must be a map. Virtual filters may omit `field`.
When present, `field` must be a non-empty atom or dotted string path and `type`
must be a non-empty atom or string.

Registered filters with a `field` and expressions in `required_filters` must
refer to known fields from:

- the root `source`
- entries in `schemas`, addressed as `"schema.field"`
- `custom_columns`

Unknown filter fields produce `:filter_field_not_found` diagnostics.
Invalid filter registry metadata produces `:invalid_filter_id`,
`:invalid_filter_config`, `:invalid_filter_field`, or `:invalid_filter_type`
diagnostics.

## Function Registry

`functions` must be a map when present. Each function id must be a non-empty
atom or string, and each function spec must be a map. Function specs validate
the current UDF metadata contract:

- `kind` must be `:scalar`, `:predicate`, or `:table`.
- `sql_name` must be a safe SQL function identifier such as `"lower"` or
  `"public.similarity"`.
- optional `allowed_in` must be a list of supported call sites.
- optional `args` must be a list of arg maps with non-empty `name`, declared
  `type`, and `source` set to `:selector`, `:value`, or `:literal`.
- optional `overloads` must be a non-empty list of signature maps. Each
  signature declares its own `args` and `returns` and inherits common metadata
  such as `kind`, `sql_name`, and `allowed_in`. An overload may override
  `sql_name` when the database uses distinct implementation names. Duplicate
  argument signatures are rejected.
- predicate functions must return `:boolean`.
- table functions must return `%{columns: %{...}}`.
- scalar function returns may be omitted or declared as an atom or
  `{:array, type}` tuple.

Invalid function metadata produces diagnostics such as `:invalid_function_id`,
`:invalid_function_spec`, `:invalid_function_kind`,
`:invalid_function_sql_name`, `:invalid_function_call_site`,
`:invalid_function_arg_source`, or `:invalid_function_returns`.

At query construction time, registered calls resolve exactly one signature.
Selecto infers selector and literal/value types, accepts compatible types within
the existing type categories, and rejects known mismatches, non-null violations,
and ambiguous overloads before SQL generation. An unknown inferred type remains
permissive because database-connected signature resolution is a separate
verification layer; it must not be reported as proof that the database accepts
the call.

Function specs may include optional `database` verification metadata. The
adapter-neutral request currently forwards only `adapters`, `requires`,
`volatility`, and `minimum_version`; other domain metadata is not exposed to
verification callbacks. The request contains no runtime argument values.

`Selecto.verify_function/4` recognizes three explicit modes:

- `:off` produces `:unverified` evidence and does not call the adapter.
- `:warn` returns normalized unsupported, failure, or resolution evidence.
- `:strict` succeeds only for `:database_resolved` and otherwise returns a
  structured validation error.

An adapter must advertise `:function_verification` and implement the optional
`verify_function/3` callback. Callback exceptions and invalid reports are
sanitized and cannot be promoted to connected-resolution evidence. This layer
proves only current connected signature resolution when an adapter implements
it; it does not prove function semantics or execute the function.

### Registry verification artifact

`mix selecto.functions.verify --domain MODULE` verifies every normalized
signature in deterministic function-ID and overload order. The provider module
must return a configured `%Selecto{}` from `selecto/0` (an `{:ok, selecto}`
tuple is also accepted). As an alternative, it may expose `domain/0` and
`connection/0`, plus optional `configure_options/0` keyword options.

Use `--output path.json` to write a timestamp-free deterministic artifact and
`--strict` to fail after writing unless every signature has
`:database_resolved` status. Without `--strict`, missing, mismatched,
unsupported, or indeterminate results remain visible evidence but do not change
the task exit status. The artifact includes a proof boundary: current connected
resolution and adapter-reported requirements do not prove function semantics,
arbitrary inputs, performance, determinism, concurrency, callbacks, external
effects, or future database state.

## Query Members

`query_members` must be a map when present. The normalized contract recognizes
the current named member groups:

- `ctes`
- `values`
- `subqueries`
- `laterals`
- `unnests`

Each group must be a map of non-empty atom or string ids to member specs. Specs
must be maps. The schema-v1 query-member contract validates metadata shape only; it
does not execute member functions or compile SQL.

Current member checks:

- CTE members require `query` or `query_builder` as a function with arity `0` or
  `1`; recursive CTE members require `base_query` arity `0` or `1` and
  `recursive_query` arity `1` or `2`.
- VALUES members require `rows` or `data` as a list; optional `columns` must be
  a list.
- Subquery members require `query` or `query_builder` as a function with arity
  `0` or `1`; optional `kind` must be `:join`, optional `on` must be a list,
  optional `type` must be `:left`, `:inner`, `:right`, or `:full`, and optional
  `join_id` must be a non-empty atom or string.
- LATERAL members require `query`, `source`, or `lateral_source` as a tuple or
  function with arity `0`, `1`, or `2`; optional `join_type` or `type` must be
  `:left`, `:inner`, `:right`, or `:full`.
- UNNEST members require `array_field` or `field` as a non-empty atom, string,
  or tuple expression; optional `ordinality` must be a non-empty atom or string.
- CTE and VALUES optional `join` metadata must be `true`, `false`, `nil`, a
  list, or a map.
- VALUES, LATERAL, and UNNEST aliases via `as`, `alias`, or `alias_name` must be
  non-empty atoms or strings when provided.
- LATERAL and UNNEST optional `options` must be a list or map.

Invalid query-member metadata produces diagnostics such as
`:invalid_query_member_group`, `:invalid_query_member_id`,
`:invalid_query_member_spec`, `:invalid_query_member_query`,
`:invalid_query_member_rows`, `:invalid_query_member_join_type`,
`:invalid_query_member_source`, or `:invalid_query_member_field`.

## Query Library

`query_library` is the portable registry of reusable application-query intent.
It is a canonical schema-v1 section and MUST be a map when present. Its four
registries are:

| Registry | Purpose | Canonical entry fields |
| --- | --- | --- |
| `segments` | Named row-membership predicates | `filters`, `parameters`, `segments`, `segment_groups` |
| `projections` | Named result shapes | `fields`, `associations`, `projections` |
| `orderings` | Named deterministic ordering | `order_by` |
| `views` | Composed query entrypoints | `segments`, `projection`, `ordering` |

Registry identifiers MAY be atoms or strings. Every referenced field and
association path MUST resolve through the domain, and every referenced segment,
projection, or ordering MUST exist. Segment and projection reference graphs
MUST be acyclic.

Segment `parameters` are maps keyed by parameter identifier. Each parameter
specification MUST declare a `type`; it MAY declare a `default`, and
`required: false` makes a missing value resolve to `nil`. Without either a
default or `required: false`, the parameter is required. Segment filters MAY
refer to a declared parameter as `{:param, parameter_id}`. `segment_groups`
declare composition using `and`, `or`, `not`, `nor`, or binary `xor`; `not`
MUST reference exactly one segment and `xor` MUST reference exactly two
distinct segments. Other groups MUST contain a non-empty segment list.
Required domain filters remain outside these optional boolean groups and cannot
be weakened by them.

Projection `projections` recursively include other named projections. Fields
are merged in stable order and duplicate fields are removed. Association
branches with the same path merge recursively, allowing multiple projections
to contribute fields and nested associations to one result shape.

The normalizer MUST preserve `query_library` in the normalized query envelope
and query-contract projection. Validation MUST reject malformed registries,
missing definitions, invalid fields or paths, cycles, and invalid boolean-group
arities before SQL generation. Runtime application, parameter casting, and the
Elixir authoring DSL are documented in [Portable Query Libraries](query_library.md).

## Co-Domain Lookups

`co_domains` is a canonical, implemented schema-v1 section. See
[Governed lookups](governed-lookups.md) for the host API, adapter boundary, and
executable fixture.

`co_domains` declares bounded lookups owned by another domain. The host resolves
the named target domain and supplies its tenant/authorization scope; the
portable declaration never contains a connection or caller-selected engine.

```elixir
co_domains: %{
  carriers: %{
    domain: :client,
    view: :carrier_lookup,
    search: %{fields: [:id, :co_name, :city], mode: :prefix, rank: true},
    result: %{
      value_field: :id,
      label_field: :co_name,
      description_fields: [:city, :state]
    }
  }
}
```

Each entry requires exactly one of `view` or `projection`. A view cannot be
combined with `segments` or `ordering`; projection form may declare both.
The `search` and `result` maps are required. Search fields are non-empty governed
field paths. Modes are `plain`, `phrase`, `websearch`, or `prefix`; `rank` is
boolean. `configuration` is an optional non-empty text-search configuration
name and defaults to `"simple"`. Result mappings require value and label fields
and may declare description fields. Parameters are data. Unknown keys, raw SQL,
invalid identifiers, and ambiguous shapes fail closed.

`Selecto.CoDomain.definition/2` returns a validated declaration without
resolving the target. `plan/5` accepts non-empty lookup text of at most 200
characters and a limit from 1 through 100, conjoins host scope, checks the target
adapter's governed text-search capability, and returns a bounded query.
`lookup/5` executes that query and returns only scalar value, label, and optional
description data.

## Predicate-Computed Boolean Fields

A source column may expose a query-computed boolean using the portable filter
AST. This provides SQL-backed row eligibility without per-row host calls:

```elixir
ready_for_dispatch: %{
  type: :boolean,
  internal: true,
  computed: %{
    kind: :predicate,
    expression: [:and, [
      [:in, :status, ["A", "O"]],
      [:eq, :has_payload, true]
    ]]
  }
}
```

Predicate expressions support `and`, `or`, `not`, `eq`, `ne`, `gt`, `gte`,
`lt`, `lte`, `in`, `between`, `is_null`, and `not_null`. Values are bound
literals; `["field", field_id]` is the explicit field-reference form. Fields
must be governed root columns, the declared column type must be boolean, and
dependencies between computed predicates must be acyclic. `internal: true`
marks presentation-only data for consumers that honor the hint; it is not a
permission or secrecy boundary. Integrated pickers omit the field, while the
frontend can still select it as hidden row data for eligibility presentation.

## Published Views

`published_views` must be a map when present. The normalized contract validates
published-view metadata shape only; it does not compile the query or generate
DDL.

Each published view id must be a non-empty atom or string, and each spec must be
a map with:

- `database_name` as a non-empty string
- `kind` as `:view` or `:materialized_view`
- `query` as a function with arity `1`
- `columns` as a non-empty map of non-empty atom/string ids to column spec maps

Optional metadata:

- `indexes` must be a list when present. Each index spec must be a map with
  `columns` as a non-empty list of atom/string names. Optional `unique` and
  `concurrently` flags must be booleans.
- `refresh` must be a map when present.

Invalid published-view metadata produces diagnostics such as
`:invalid_published_view_id`, `:invalid_published_view_spec`,
`:invalid_published_view_database_name`, `:invalid_published_view_kind`,
`:invalid_published_view_query`, `:invalid_published_view_columns`,
`:invalid_published_view_index_columns`, or `:invalid_published_view_refresh`.

## Domain Dependencies

`domain_dependencies` is the canonical consumer-side registry for requirements
against named provider contracts. It MUST be a list of maps. Every dependency
requires non-empty `provider` and `contract` identifiers and may declare:

- `accepts`, a non-empty version requirement string;
- `expected_fingerprint`, a non-empty provider or surface fingerprint;
- `uses`, a map containing lists of `fields`, `filters`, and `query_members`;
- `satisfies`, a list of provider-required filters supplied by trusted consumer
  context.

All referenced ids MUST be non-empty atoms or strings. Unknown dependency or
`uses` keys fail validation. Alternate spellings for `contract` and top-level
shortcuts for `uses` are not part of schema v1.

`Selecto.Domain.ContractVerification.verify/3` checks these dependencies against
the provider's `published_views`. `published_surfaces/2` builds the provider
projection, `snapshot/2` emits its deterministic snapshot, and
`diff_snapshots/2` classifies additive and breaking changes. These functions do
not fetch domains, publish artifacts, or replace host-controlled rollout policy.

## Detail Actions

`detail_actions` must be a map when present. The normalized contract validates
detail-row action metadata only; it does not render modals, resolve LiveView
components, or execute links.

Each detail action id must be a non-empty atom or string, and each action spec
must be a map with:

- `name` as a non-empty string
- `type` as `:modal`, `:iframe_modal`, `:external_link`, or `:live_component`

Optional metadata:

- `payload` must be a map when provided.
- `required_fields` must be a list when provided. Each entry must be a
  non-empty atom or string and must refer to a known source, schema, or custom
  column field.

Type-specific payload checks:

- `:external_link` and `:iframe_modal` require `payload.url_template` as a
  non-empty string.
- `:live_component` requires `payload.module` as an atom.

Invalid detail-action metadata produces diagnostics such as
`:invalid_detail_action_id`, `:invalid_detail_action_spec`,
`:invalid_detail_action_name`, `:invalid_detail_action_type`,
`:invalid_detail_action_payload`, `:missing_detail_action_url_template`,
`:missing_detail_action_module`, or `:detail_action_field_not_found`.

## Component Metadata

`components` is canonical component-facing UI metadata. Core preserves it in
the normalized envelope and includes it in the `:ui` projection. It is omitted
from the `:query`, `:write`, `:api`, and `:query_contract` projections because
it does not grant query, write, API, or authorization semantics.

The current portable entry is `query_params`. Producers SHOULD author
`components` as a map and `query_params` as a boolean:

```elixir
components: %{
  query_params: false
}
```

An absent value or `true` permits compatible UI consumers to expose editable
explorer state in browser query parameters. `false` tells those consumers to
keep that state out of generated URLs and ignore inbound URL state. A consumer
handling sensitive state MUST fail closed for an authored but malformed
`components` or `query_params` value; current core normalization preserves this
metadata but does not validate a narrower component-package subschema.

This policy reduces URL exposure. It is not an authorization decision,
encryption mechanism, or guarantee that state will be absent from application
logs, telemetry, browser memory, or other host-owned surfaces.

## Application Operations And Experiences

`operations` and `experiences` are canonical top-level registries for named
application operations and consumer experiences. They are distinct from the
database mutation policies in `writes.operations` and from the executable
action registry in `actions`.

Each registry MUST be a map. Registry ids MUST be non-empty atoms or strings,
and every registry entry MUST be a map. Core validates this portable envelope
and preserves the entry data. The consumer that defines an Operation or
Experience vocabulary owns its deeper schema and execution rules; core does not
infer authority or execute either registry.

`Selecto.Domain.consumer_projection_release/2` includes the exact normalized
registries in its immutable release and fingerprints them with the nested
composition contract. Generic `:query`, `:write`, `:ui`, `:api`, and
`:query_contract` projections do not expose these registries. Consumers that
need them MUST use a projection-specific consumer release.

## Write Contract

The optional `writes` map declares the only portable write authority granted by
a domain. Read fields, associations, database introspection, and queryability
MUST NOT imply write permission. An executable contract requires a non-empty
`writes.operations` registry containing at least one operation with
`enabled: true`; otherwise `Selecto.Domain.WriteContract.compile/1` returns
`:write_not_declared`.

The canonical sections are:

| Key | Shape | Contract |
| --- | --- | --- |
| `operations` | map | Named `insert`, `update`, `delete`, or `upsert` operation policies. |
| `fields` | map | Explicit field-level insert/update grants and restrictions. |
| `scope` | map | Server-owned scope requirements, currently including `tenant`. |
| `relationships` | map | Nested-write relationship ownership and mutation policy. |
| `validations` | list | Portable or host-interpreted validation rules. |
| `constraints` | list or map | Write constraints, including optimistic locking and foreign keys. |
| `transitions` | map | Allowed state-transition graphs keyed by a known field. |
| `hooks` | map | Declared references to host-owned hook code. |

### Operations

Operation ids MUST be `insert`, `update`, `delete`, or `upsert`, in atom or
string form. Each specification MUST be a map. The schema validator recognizes
boolean `enabled`, `bulk`, and `require_filter` flags, an optional list of known
`fields`, and these cardinality forms:

- `:many`
- `{:exactly, positive_integer}`
- `{:at_most, non_negative_integer}`
- `{:at_least, non_negative_integer}`
- `{:between, minimum, maximum}` where `0 <= minimum <= maximum`

Additional operation metadata such as `returning` and `conflict_targets` is
preserved for write consumers. A consumer MUST reject an unsupported option or
adapter requirement rather than silently weakening it.

### Fields

Every key in `writes.fields` MUST resolve to a known source, schema, or custom
field. A field spec MAY contain boolean `insertable`, `updatable`, `immutable`,
`write_once`, and `server_managed` flags. `insertable: true` grants the field to
insert/upsert; `updatable: true` grants it to update. Missing or false flags do
not grant permission. Portable write metadata MUST NOT contain
`{:unsafe_sql, ...}` or `{:unsafe_fragment, ...}` terms.

Authoring and downstream write consumers also use metadata such as
`required_on`, `forbidden_on`, validators, and default providers. These values
are preserved in the field spec, but their execution belongs to the write
consumer; core schema validation is not proof that a particular adapter or host
implements them.

### Scope

The canonical tenant policy is `writes.scope.tenant` (the validator also reads
the compatibility spelling `writes.scopes`). It is a map with an optional
boolean `required` flag and a `field` that MUST resolve to a known domain field.
Consumer-facing metadata may declare `satisfied_by` sources such as trusted
context or a database prefix. A required tenant scope is server-owned policy:
clients MUST NOT be permitted to replace the trusted tenant value.

### Relationships

Each `writes.relationships` entry MUST be a map. A writable/enabled relationship
MUST explicitly declare:

- `cardinality`: `:one` or `:many`;
- `ownership`: `:composition`, `:shared_association`, `:join_association`,
  `:derived`, or `:deferred`.

The input aliases `:owned`, `:shared_reference`, and `:join_only` normalize to
`:composition`, `:shared_association`, and `:join_association`. Consumer release
artifacts always use the canonical names.

A relationship may declare a stable non-empty `path_id`, `target`,
`parent_key`, `child_key`, `foreign_key`, `physical_provenance`, non-empty
`identity_fields`, `child_identity`, `client_identity`, a nested `domain`, and
child `relationships`. A nested `domain` MUST itself be a map. Physical keys and
database foreign keys provide provenance only; they never grant ownership,
write authority, tenant inheritance, or delete authority.

The optional `read` map accepts:

- boolean `allowed`;
- non-negative `default_depth`;
- positive `max_depth`, `max_rows`, `max_bytes`, and `max_complexity`.

A relationship with `read.allowed: true` MUST declare both `max_depth` and
`max_rows`.

The optional `write` map accepts a non-empty `modes` list containing
`append_only`, `delta`, `full_set`, `replace_one`, or `link_delta`; boolean
`create`, `update`, `delete`, `reorder`, `link`, and `unlink` operation flags;
an `omission` policy of `unchanged`, `delete_missing`, `reject_missing`, or
`retain_missing`; non-negative `min_items`; and positive `max_items` and
`max_mutations`. When both item bounds are present, `max_items` MUST be greater
than or equal to `min_items`.

The mutation representations have distinct meanings:

- `append_only` adds children and never updates or removes existing children;
- `delta` carries explicit create, update, and delete groups while omission is
  unchanged;
- `full_set` carries the complete desired collection and MUST declare its
  omission policy;
- `replace_one` carries one explicit create, update, or delete intent for a
  to-one relationship;
- `link_delta` links and unlinks identities for shared or join associations.

`append_only` and `full_set` are invalid for `cardinality: :one`;
`replace_one` is invalid for `cardinality: :many`. Shared and join associations
may use only `link_delta` and may not create, update, or delete the independently
owned target. Derived relationships are read-only unless a separate named
Operation supplies write meaning. Delta, full-set, replacement, update, delete,
link, and unlink semantics require stable `identity_fields`.

`tenant_scope` is either `recursive`, `membership`, `explicit`, or `none`, or a
map whose `mode` uses one of those values. `capabilities` maps operation ids to
non-empty capability ids. `ordering`, `conflict`, `idempotency`, `offline`,
`validation`, `assurance`, and `output` MUST be maps when present. An offline
writable relationship MUST declare both conflict and idempotency policy.

The earlier flat fields `allowed_ops`, `strategy: :sync`, `delete_missing`,
`min_items`, and `max_items` remain valid input shorthand and compile into the
same canonical composition contract. `allowed_ops` uses the four
`writes.operations` ids. New contracts SHOULD author the explicit `read` and
`write` maps because their omission and bounds are unambiguous.

`Selecto.Domain.composition_contract/1` compiles these declarations into the
deterministic `selecto.composition_contract.v1` shape. Unknown relationship
concepts are retained under its `extensions` map. Executable consumer releases
fail closed unless their target explicitly advertises every required feature;
`preserve_only: true` is limited to non-executable archival projections. See
[Nested Composition Contract](nested_composition_contract.md) for the complete
release and certification workflow.

### Constraints

`constraints.optimistic_lock` identifies a known `field`. Each entry in
`constraints.foreign_keys` is keyed by a known local field and MUST declare:

- `source: :input` or `source: {:context, key}` (the equivalent map form is
  accepted);
- `references: %{relation: relation_id, field: field_id}`;
- optional boolean `required`.

These declarations let adapters preflight portable behavior. Database-native
constraints remain authoritative and MUST still be enabled and tested.

### Hooks And Validations

`writes.validations` is an ordered list. `writes.hooks` is a registry of named
hook references such as `{Module, :function}` or `{Module, :function, args}`.
They are host-owned executable code, not portable data-plane behavior. Safe
inspection exposes only sanitized reference metadata and never executes hooks.
Applications MUST treat domains containing functions, callbacks, or modules as
trusted code even when the surrounding map is declarative.

## Write Transitions

`writes.transitions` is a schema-v1 write contract section with strict
validation. It is a direct state graph keyed by a known domain field:

```elixir
%{
  writes: %{
    transitions: %{
      status: %{
        "pending" => ["ready", "cancelled"],
        "ready" => [:complete, "cancelled"],
        complete: []
      }
    }
  }
}
```

Validation checks:

- `writes` must be a map when present.
- `writes.transitions` must be a map when present.
- each transition field key must be an atom or string
- each transition field must exist in the source, schemas, or custom columns
- each transition graph must be a map
- each source state must be an atom or string
- each target list must be a list of atoms or strings

This validation does not execute writes. Query configuration preserves the
metadata, while execution is owned by the write consumer and configured adapter.

## Colocated Write Authoring

Fields and relationships may colocate write policy with their structural domain
definitions. This is authoring shorthand; normalization still produces the
canonical `writes.fields` and `writes.relationships` registries consumed by
Updato and database adapters.

```elixir
%{
  source: %{
    columns: %{
      id: %{type: :integer, write: %{server_managed: true}},
      tenant_id: %{
        type: :integer,
        write: %{insertable: true, immutable: true}
      },
      status: %{
        type: :string,
        write: %{insertable: true, updatable: true, required_on: [:insert]}
      }
    },
    associations: %{
      items: %{
        queryable: :items,
        field: :items,
        cardinality: :many,
        owner_key: :id,
        related_key: :order_id,
        write: %{
          enabled: true,
          ownership: :owned,
          allowed_ops: [:insert, :update],
          domain: item_domain,
          identity_fields: [:id],
          strategy: :sync,
          delete_missing: true
        }
      }
    }
  },
  writes: %{
    operations: %{
      insert: %{enabled: true},
      update: %{enabled: true, require_filter: true}
    },
    scope: %{
      tenant: %{required: true, field: :tenant_id}
    }
  }
}
```

For association shorthand, `cardinality`, `owner_key`, and `related_key` become
the canonical relationship `cardinality`, `parent_key`, and `child_key` unless
the `write` map declares them explicitly.

Safety rules:

- missing `write` means read-only; queryability never grants writability;
- only source columns and source associations grant shorthand write policy;
  projection columns do not;
- database introspection may verify structural metadata but cannot add write
  permissions;
- declaring the same field or relationship both beside its definition and in
  `writes.fields` or `writes.relationships` produces
  `:duplicate_write_authoring` and removes that grant from the normalized
  contract;
- operation, tenant scope, transitions, and cross-field constraints remain in
  the top-level `writes` section because they are not properties of one field or
  relationship.

## Capability Catalog

`capabilities` declares the stable capability names a domain can reference. It
does not decide which actors have those capabilities; host applications and
future resolver adapters own that policy decision.

```elixir
%{
  capabilities: %{
    "order.view" => %{
      label: "View orders",
      operations: [:select, :detail],
      target: :order
    },
    "order.approve" => %{
      label: "Approve order",
      operations: [:action],
      action: :approve_order
    },
    "order.export" => %{
      label: "Export orders",
      operations: [:export],
      sensitivity: :high
    }
  }
}
```

Validation checks:

- `capabilities` must be a map when present.
- capability ids must be atoms or strings.
- each capability entry must be a map.
- each capability must declare a non-empty `operations` list.
- each operation must be an atom or string.

The domain contract also validates optional `capability` references on
query-facing metadata:

- filters
- functions
- query members
- published views
- detail actions

When present, the value must be an atom or string and must exist in the domain
capability catalog. These checks only validate metadata references; they do not
perform authorization or alter `Selecto.configure/3` behavior.

Runtime capability checks use a shared request/decision value shape:

```elixir
request =
  Selecto.Capabilities.request(
    actor: current_user,
    tenant: tenant_context,
    domain: :orders,
    capability: "order.approve",
    operation: :execute_action,
    target: %{type: :row, id: order_id},
    context: %{surface: :components}
  )

decision =
  Selecto.Capabilities.allow(:role_allowed,
    effects: [{:required_filter, "tenant_id", {:eq, tenant_id}}],
    obligations: [:audit_action]
  )
```

Decision statuses are `:allow`, `:deny`, `:conditional`, and
`:not_applicable`. Visibility recommendations are `:enabled`, `:disabled`,
`:hidden`, and `:preview_only`.

## Events And Event-Stream Actions

`events` declares the immutable business facts that a host aggregate may emit.
Each event has an explicit positive schema version and a payload field contract:

```elixir
%{
  events: %{
    substitution_proposed: %{
      schema_version: 1,
      additional_fields: false,
      data: %{
        unavailable_sku: %{type: :string, required: true},
        substitute_sku: %{type: :string, required: true}
      }
    }
  },
  actions: %{
    propose_substitution: %{
      inputs: %{
        expected_version: %{type: :integer, required: true},
        unavailable_sku: %{type: :string, required: true},
        substitute_sku: %{type: :string, required: true}
      },
      execution: %{
        kind: :event_stream,
        aggregate: :fulfillment_order,
        bounded_context: :fulfillment,
        stream_id: {:target, :id},
        consistency: :expected_version,
        possible_events: [:substitution_proposed]
      }
    }
  }
}
```

Supported event field types are `any`, `boolean`, `enum`, `integer`, `list`,
`map`, `number`, `string`, and `uuid`. Enum fields declare `values`; fields may
declare `required` and `nullable`; `additional_fields` is boolean.

An `event_stream` execution MUST name a non-empty aggregate, a stream id or an
explicit `target`/`input`/`context` field reference, expected-version
consistency, and a non-empty list of events present in the domain event
registry. It MUST NOT also declare direct Updato `operation` or `set` keys.

This metadata distinguishes a command from its possible outcomes. Selecto core
normalizes and validates the contract; it does not decide the command, append
events, or treat an action invocation as an event. Those runtime guarantees
belong to an authorized event-store adapter such as Selecto Ledger.

## Direct Transition Actions

`actions` declares named business commands. The canonical transition action is a
row action that directly references a `writes.transitions` edge:

```elixir
%{
  actions: %{
    complete_order: %{
      target: :order,
      scope: :row,
      capability: "order.complete",
      preconditions: [
        {:eq, :balance_cents, 0},
        %{field: :waiver_received, comparator: :eq, value: true}
      ],
      transition: %{
        field: :status,
        from: "ready",
        to: "complete"
      },
      execution: %{
        kind: :updato,
        operation: :update,
        set: %{status: "complete"}
      }
    }
  }
}
```

Validation checks:

- `actions` must be a map when present.
- action ids must be atoms or strings.
- each action entry must be a map.
- `capability`, when present, must be an atom or string and must exist in the
  domain capability catalog.
- `preconditions`, when present, must be a list of portable filter predicates.
  Supported forms are `{field, value}`, `{comparator, field, value}`, their
  JSON-safe array equivalents, and maps with `field`, `comparator`, and `value`.
  Predicates are combined with `AND`; supported comparators are `eq`, `neq`,
  `gt`, `gte`, `lt`, `lte`, and non-empty `in`.
- Every precondition field must be declared by the domain. Preconditions are
  server-owned constraints: action callers may add target or scope filters but
  cannot remove the declared predicates.
- actions with `type: :transition` must declare a direct transition map.
- `transition` must be a map with `field`, `from`, and `to`.
- the transition field must exist in the source, schemas, or custom columns.
- the transition edge must exist in `writes.transitions`.
- direct transition execution uses `%{kind: :updato, operation: :update}`;
  separately, non-transition actions may use the governed `event_stream`
  execution contract described above.
- optional execution `set` must set the transition field to the target state.
- `selection.eligibility_field`, when present, must name a direct boolean source
  field. Component hosts select it with the primary result query and omit row
  selection controls when it is false or null.

This validates that preview and execution can ask the same domain question; it
does not execute actions.

Eligibility is presentation metadata, not mutation authorization. Final
execution must independently enforce action preconditions, tenant scope,
capabilities, and cardinality.

Updato enforces filter preconditions on direct update/delete actions using
source-row fields, including read-only source fields. Insert, upsert, and
event-stream action planning rejects relational filter preconditions. Joined
or computed fields and filters outside the portable comparator set are not
supported by the current portable mutation path.

## Source Relationships And Choice Sources

`source_relationships` declares the compact working-domain to source-domain
binding shape. It is used by `choice_sources` to describe context-safe option
providers.

```elixir
%{
  source: %{
    columns: %{
      customer_id: %{
        type: :integer,
        reference: %{
          choice_source: :customer_choices,
          value_source: "customers.id",
          caption_source: "customers.name"
        }
      }
    }
  },
  source_relationships: %{
    customer: %{
      target_domain: :customers,
      source_field: :customer_id,
      target_field: :id,
      source_path: "customers",
      virtual_join: [
        %{working_field: :customer_id, source_field: "customers.id", required: true}
      ],
      filters: [
        {:eq, "customers.active", true}
      ]
    }
  },
  choice_sources: %{
    customer_choices: %{
      domain: :customers,
      value_field: :id,
      label_field: :name,
      source_path: "customers",
      value_source: "customers.id",
      caption_source: "customers.name",
      description_source: "customers.description",
      filters: [{:eq, "customers.active", true}],
      order_by: ["customers.name", {"customers.id", :desc}],
      presentation: %{
        control: :autocomplete,
        mode: :searchable,
        cardinality: :one
      },
      source_relationship: :customer,
      capability: "customer.choose"
    }
  }
}
```

Source relationship validation checks:

- `source_relationships` must be a map when present.
- source relationship ids must be atoms or strings.
- each source relationship entry must be a map.
- each source relationship must declare `target_domain`, `source_field`, and
  `target_field`.
- `target_domain`, `source_field`, and `target_field` must be atoms or strings.
- `source_field` must exist in the working domain source, schemas, or custom
  columns.
- optional `source_path` must be a non-empty atom or dotted string path.
- optional `virtual_join` must be a list of maps with `working_field` and
  `source_field`; `working_field` must exist in the working domain,
  `source_field` must be a non-empty atom or dotted string path, and optional
  `required` must be a boolean.
- optional `filters` must be a list of static filter expressions using the same
  operator and path syntax as choice-source filters.

Choice source validation checks:

- `choice_sources` must be a map when present.
- choice source ids must be atoms or strings.
- each choice source entry must be a map.
- each choice source must declare `domain`, `value_field`, and `label_field`.
- `domain`, `value_field`, and `label_field` must be atoms or strings.
- optional `source_relationship` must reference a declared source relationship.
- optional `capability` must reference a declared capability.
- optional `source_path`, `value_source`, `caption_source`, and
  `description_source` must be non-empty atom or dotted string paths.
- optional `filters` must be a list of static filter expressions. Field
  operators such as `:eq`, `:gt`, `:between`, and `:in`, plus logical
  `:and`, `:or`, and `:not`, may be atoms or strings.
- choice-source filter field operands must be non-empty atom or dotted string
  paths. Literal, context, and runtime values are preserved without evaluation.
- optional `order_by` must be a list of paths or `{path, direction}` entries;
  direction must be `:asc` or `:desc`.
- optional `presentation` must be a map. Known presentation hints are:
  `control: :select | :autocomplete | :table_picker`,
  `mode: :static | :searchable | :async | :inline`, and
  `cardinality: :one | :many`.

Field binding validation checks:

- source, schema, and projection column metadata may use
  `choice_source: choice_source_id` as compact field binding.
- source, schema, and projection column metadata may use
  `reference: %{choice_source: choice_source_id}` for richer bindings.
- field-level `choice_source` references must be atoms or strings and must
  reference a declared choice source.
- `reference`, when present, must be a map.
- `reference.choice_source`, when present, must be an atom or string and must
  reference a declared choice source.
- optional `reference.value_source` and `reference.caption_source` must be atoms
  or strings.
- optional `reference.caption_field` must be an atom or string and must refer to
  a known working-domain field.

### Authoring Shorthand

For authoring ergonomics, a field may declare `choice_source: %{...}` directly.
`Selecto.Domain.normalize/1` expands that supported shorthand into the canonical
registries without changing `Selecto.configure/3` behavior:

```elixir
customer_id: %{
  type: :integer,
  choice_source: %{
    id: :customer_choices,
    domain: :customers,
    source_relationship: %{
      id: :customer,
      virtual_join: [
        %{working_field: :customer_id, source_field: "customers.id", required: true}
      ]
    },
    value_source: "customers.id",
    caption_source: "customers.name",
    filters: [{:eq, "customers.active", true}],
    presentation: :select
  }
}
```

The normalized form contains:

- `source_relationships.customer`
- `choice_sources.customer_choices`
- `reference: %{choice_source: :customer_choices, ...}` on the field
- compact `choice_source: :customer_choices` on the field

If `id` values are omitted, the normalizer generates deterministic string ids
from the field path. This is canonical shorthand only; undocumented legacy
sections are not expanded or assigned compatibility semantics.

Schema v1 validates static choice-source metadata and filter expression
syntax plus static source-relationship metadata. It does not resolve external
source-domain schemas, apply filters, fetch options, or execute membership
checks.

## Domain Composition

`Selecto.Domain.compose/2` is the explicit boundary for combining an authored
domain with one or more data overlays before projecting or validating it. The
function returns a normalized envelope; it does not mutate the map later passed
to `Selecto.configure/3`.

```elixir
{:ok, normalized, diagnostics} =
  Selecto.Domain.compose(base_domain, [
    %{
      source: %{
        columns: %{total: %{label: "Total", format: :currency}},
        redact_fields: [:tenant_secret]
      },
      filters: %{"status" => %{field: :status}}
    }
  ])
```

Composition semantics are deterministic:

- maps deep-merge by section.
- `redact_fields`, including `source.redact_fields`, are unioned.
- `extensions` are appended uniquely.
- other lists and scalar values are replaced by later overlays.
- governance/reference registry collisions, such as `choice_sources` or
  `source_relationships`, produce `:domain_composition_collision` warnings.

After overlays merge, declared extension `merge_domain/2` callbacks run in
declaration order and the result is normalized again.

## Overlay Authoring DSL

`use Selecto.Config.OverlayDSL` defines an `overlay/0` function for compile-time
authoring. The returned value is an ordinary domain overlay and MUST be merged
into a complete base domain before runtime configuration. Declaring a DSL block
does not by itself validate the complete result.

The schema-v1 DSL families are:

- query and UI: `defcolumn`, `deffilter`, `deffunction`, `defdetail_action`,
  `defpopup`, and `defjson_schema`;
- query members: `defcte`, `defvalues`, `defsubquery`, `deflateral`, and
  `defunnest`;
- structure: `defschema`, `defjoin`, `defschema_assoc`, and `defsource_assoc`;
- references: `defsource_relationship` and `defchoice_source`;
- writes: `defwrite_operation`, `defwrite_field`, `defwrite_relationship`,
  `defwrite_transition`, `defwrite_validation`, `defwrite_constraint`,
  `defwrite_tenant_scope`, and `defwrite_hook`;
- governance: `defaction` and `defcapability`.

Block forms use property macros such as `label`, `type`, `capability`,
`enabled`, `insertable`, `updatable`, `required_on`, `operations`, `transition`,
and `execution`. Map forms remain useful when a complete nested shape is clearer.

`Selecto.Config.Overlay.merge/2` implements the runtime-oriented overlay merge:
registries and column metadata deep-merge, redactions union, and overlay values
win where no section-specific rule applies. `Selecto.Domain.compose/2` is the
portable normalization/composition API described above. Producers SHOULD choose
one boundary deliberately and validate the fully merged domain, rather than
assuming every overlay mechanism has identical collision semantics.

## Domain Projections

`Selecto.Domain.project/2` turns a normalized domain into read-only consumer
views. These projections do not change `Selecto.configure/3` behavior.

Supported projections are:

- `:query` for query/runtime-facing sections
- `:write` for write/action/reference metadata
- `:ui` for display defaults, choices, actions, and detail actions
- `:api` for combined read/write/action API-style consumers
- `:query_contract` for constrained query metadata used by tools, Components,
  and AI query contracts

The `:query_contract` projection is intentionally summary-only. It exposes:

- source table and primary key
- selectable fields from `source`, `schemas`, and `custom_columns`
- join summaries with target schemas and target field ids
- query defaults and required query lists
- filter, function, query-member, query-library, and published-view summaries
- source relationship and choice-source summaries
- field-to-choice-source bindings
- declared capability ids

Each field entry identifies `id`, `source`, `relation`, `field`, `type`, `label`,
`capability`, `capability_target`, and `choice_source`, together with this stable
query surface:

| Key | Meaning |
| --- | --- |
| `detail_selectable` | Whether detail selection may expose the field. Defaults to `true`. |
| `filterable` | Whether predicates may use the field. Source/schema fields and fields named by a declared filter default to `true`; other computed fields default to `false`. |
| `sortable` | Whether ordering may use the field. Defaults by portable type. |
| `groupable` | Whether grouping may use the field. Defaults by portable type. |
| `aggregatable` | Whether numeric aggregation may use the field. Defaults to `true` for selectable integer, float, and decimal fields. |
| `comparators` | Exact comparator ids permitted for this field. |
| `aggregate_functions` | Exact aggregate ids permitted for this field. |
| `default_grouping` | Optional authored analytic grouping default. |
| `default_aggregate` | Optional authored analytic aggregate default. |

Sortable types are integer, float, decimal, date/time variants, string/text,
boolean, UUID, and enum. Groupable types use the same set except free-form
`text`. Default comparator sets are type-specific: numeric and temporal fields
support equality, ordering, range, membership, and null predicates; string/text
fields support equality, contains, prefix, suffix, membership, and null
predicates; boolean, UUID, and enum fields use equality, membership, and null
predicates. The default aggregate set for an aggregatable field is `count`,
`count_distinct`, `sum`, `avg`, `min`, and `max`.

Column metadata may override these values with canonical boolean keys and exact
lists. `operators` is accepted as an input spelling for `comparators`, and
`aggregates` for `aggregate_functions`; projected output always uses the
canonical names above. Filter summaries likewise include their resolved field,
type, capability, virtual status, and exact comparator list.

It does not include write/action/detail-action/component sections, raw authored
unknown keys, top-level application Operations or Experiences, or function
captures from query members and published views.

For consumers that do not need the lower-level projection API,
`Selecto.Domain.query_contract/1` accepts either an authored domain or an
already-normalized domain and returns `{:ok, query_contract, diagnostics}`.

Consumers SHOULD request the narrowest projection that satisfies their needs:

| Consumer concern | Projection |
| --- | --- |
| Query compilation or query tooling | `:query` |
| Portable mutation/action tooling | `:write` |
| UI labels, choices, and actions | `:ui` |
| Combined API contract | `:api` |
| Constrained discovery for tools or AI | `:query_contract` |

A projection is a read-only metadata boundary, not an authorization decision.
Capability ids in a projection remain names that a host resolver must evaluate.

## Runtime Configuration And Governance

The runtime entry point is:

```elixir
selecto =
  Selecto.configure(domain, connection_input,
    adapter: MyApp.SelectoAdapter,
    validate: true,
    mode: :strict,
    domain_sql: :declared
  )
```

An adapter MUST be supplied explicitly unless the host application configures a
default. Before compilation, Selecto discovers domain extension specs and calls
their domain-merge callbacks in declaration order. With validation enabled, it
runs `Selecto.DomainValidator.validate_domain!/1`; it then compiles query fields
and joins and seals the applicable policy state.

The policy modes are:

- `:permissive` — preserves the traditional dynamic query surface;
- `:strict` — seals the composed domain and compiled authority, rejects
  query-authored raw SQL escape hatches, prohibits ad hoc or structurally
  overridden joins, and requires advanced row sources to originate in declared
  query members.

`domain_sql: :declared` permits trusted SQL already authored inside the domain.
`domain_sql: :forbid` rejects that declared SQL as well when used with strict
mode. Strict mode is a query-construction governance boundary. It MUST be paired
with database privileges, tenant controls, parameterized execution, and any
required row-level security.

### Named Domain Resolution

Systems that select a domain at an HTTP, LiveView, API, job, or tool boundary
SHOULD exchange an opaque atom or string id rather than accept an authored
domain map from that caller. A server-owned registry implements:

```elixir
@behaviour Selecto.Domain.Registry

@impl true
def fetch("orders", %{actor: actor, tenant: tenant}) do
  if authorized?(actor, tenant) do
    {:ok, OrdersDomain.domain(), %{version: "2026-08-14"}}
  else
    {:error, :forbidden}
  end
end

def fetch(_id, _context), do: {:error, :not_found}
```

The only accepted callback forms are `{:ok, domain}`,
`{:ok, domain, metadata}`, and `{:error, reason}`. A bare map is invalid.
Resolution does not convert caller-supplied strings to atoms. The registry
result MUST pass both schema-v1 validation and runtime domain validation before
it can become query authority.

```elixir
selecto =
  Selecto.configure_registered("orders", connection_input,
    registry: MyApp.SelectoDomains.Registry,
    domain_context: %{actor: current_actor, tenant: current_tenant},
    adapter: MyApp.SelectoAdapter,
    mode: :strict
  )
```

`config :selecto, :domain_registry` may supply the default registry.
`validate: false` is invalid for registered configuration. Extension callbacks
run as usual, and the fully composed domain is validated again afterward.
`Selecto.domain_ref/1` returns a `%Selecto.Domain.Ref{}` containing the id,
registry, version/fingerprint, and registry metadata, but never the authored
domain map. A ref may be passed to another server-owned Selecto consumer and
resolved again.

Generated single-domain modules may use
`use Selecto.Domain.Registry, id: "orders"`. Larger applications can implement
one aggregate registry with route-, actor-, tenant-, or capability-aware
`fetch/2` clauses. The registry and its context MUST be supplied by trusted
server code. A caller being allowed to request `"orders"` does not imply that
the registry should return it, and missing and forbidden ids SHOULD have the
same public response when revealing existence would leak information.

Capabilities follow the same separation of concerns: the domain declares stable
names and where they apply; the host supplies an actor/tenant-aware resolver and
acts on an `allow`, `deny`, `conditional`, or `not_applicable` decision. A
missing capability declaration or unresolved decision MUST NOT be interpreted
as authorization.

## Domain Inspection

`Selecto.Domain.describe/1` returns a compact structured inspection map for an
authored or normalized domain. The output is intended for generators, docs,
Studio, tests, and other tools that need stable metadata without walking the
full normalized domain shape.

```elixir
{:ok, inspection, diagnostics} = Selecto.Domain.describe(domain)

inspection.counts.choice_sources
inspection.registries.source_fields
inspection.source_relationships
inspection.field_choice_bindings
```

The inspection output includes:

- section categories and normalization diagnostics summary
- counts for source fields, registries, writes, actions, capabilities,
  source relationships, choice sources, co-domains, domain dependencies,
  operations, experiences, and field choice bindings
- sorted registry ids for filters, functions, query members, joins, schemas,
  actions, capabilities, source relationships, choice sources, co-domains,
  operations, and experiences
- compact summaries of `writes`, actions, capabilities, source relationships,
  choice sources, and field-to-choice-source bindings

## Choice Membership API

`Selecto.Domain.Choices` is the first shared API for asking whether a submitted
value belongs to a field's declared choice source. In this slice it resolves
domain metadata and builds a membership request, but it does not query source
domains or databases unless a caller supplies an explicit resolver.

```elixir
{:ok, request} =
  Selecto.Domain.Choices.request(domain, :customer_id, 42,
    actor: current_user,
    tenant: tenant_context,
    record: %{customer_id: 42},
    context: %{surface: :components}
  )

request.choice_source
#=> :customer_choices

{:error, result} =
  Selecto.Domain.Choices.validate_choice(domain, :customer_id, 42)

result.status
#=> :unknown

result.reason_code
#=> :resolver_required
```

Callers that have a membership implementation can pass a resolver function:

```elixir
resolver = fn request ->
  if source_member?(request) do
    Selecto.Domain.Choices.valid(:source_member)
  else
    Selecto.Domain.Choices.invalid(:not_in_choice_source)
  end
end

{:ok, result} =
  Selecto.Domain.Choices.validate_choice(domain, :customer_id, 42,
    resolver: resolver
  )
```

The request/result shape lets Components, API, GraphQL, AI, actions, and Updato
share one membership question later. Core Selecto remains conservative: without
a resolver, membership is `:unknown`, not assumed valid.

Choice sources may declare resolver-facing constraint policy metadata:

```elixir
choice_sources: %{
  customer_choices: %{
    domain: :customers,
    value_field: :id,
    label_field: :name,
    constraint_policy: %{
      domain_of_interest: :fail_closed
    }
  }
}
```

The supported constraint keys are `source_relationship`, `choice_source`, and
`domain_of_interest`. Each value MUST be `best_effort` or `fail_closed`. The
policy is carried on membership and option-list requests. A resolver uses
`fail_closed` to reject a request when the corresponding server-owned constraint
cannot be enforced. The default is `best_effort` when no policy is declared.

## Choice Option Lists

`Selecto.Domain.Choices` also exposes the sibling option-list request shape for
surfaces that need to ask "what options should this field show?" The request can
be built from a field binding or directly from a declared choice source.

```elixir
{:ok, request} =
  Selecto.Domain.Choices.options_request(domain, :customer_id,
    search: "acme",
    limit: 20,
    offset: 0,
    actor: current_user,
    tenant: tenant_context,
    record: %{customer_id: 42},
    context: %{surface: :components}
  )

request.choice_source
#=> :customer_choices

{:ok, direct_request} =
  Selecto.Domain.Choices.options_request(domain, :customer_choices,
    by: :choice_source,
    search: "acme"
  )
```

As with membership checks, core Selecto does not fetch option rows without an
explicit resolver:

```elixir
{:error, result} =
  Selecto.Domain.Choices.list_options(domain, :customer_id, search: "acme")

result.status
#=> :unknown

resolver = fn request ->
  options =
    fetch_options(request)
    |> Enum.map(&%{value: &1.id, label: &1.name})

  Selecto.Domain.Choices.options_resolved(options)
end

{:ok, result} =
  Selecto.Domain.Choices.list_options(domain, :customer_id,
    search: "acme",
    resolver: resolver
  )
```

The option-list API is a projection contract for future Components, API,
GraphQL, AI, operations, and Updato integrations. It does not change
`Selecto.configure/3` behavior.

## Validation And Inspection Workflow

Domain tooling SHOULD use the following sequence:

```elixir
with {:ok, normalized, diagnostics} <- Selecto.Domain.validate(domain),
     :ok <- Selecto.DomainValidator.validate_domain(domain) do
  query_contract = Selecto.Domain.project(normalized, :query_contract)
  {:ok, inspection, _diagnostics} = Selecto.Domain.describe(normalized)
  {:ok, normalized, query_contract, inspection, diagnostics}
end
```

The public boundaries are:

| API | Input | Result and purpose |
| --- | --- | --- |
| `Selecto.Domain.normalize/1` | authored map | Envelope plus warnings; expands shorthand but does not run contract errors. |
| `Selecto.Domain.validate/1` | authored map | Normalizes and runs the schema-v1 contract. |
| `Selecto.DomainValidator.validate_domain/1` | authored runtime map | Runtime-oriented structural and join validation. |
| `Selecto.DomainValidator.validate_domain(domain, normalize: true, projection: p)` | authored map | Validates the normalized contract and then the selected `:query`, `:write`, `:ui`, or `:api` projection through the authored validator. |
| `Selecto.Domain.project/2` | normalized envelope | Produces a named read-only consumer view. |
| `Selecto.Domain.query_contract/1` | authored or normalized | Produces the constrained query-discovery projection. |
| `Selecto.Domain.describe/1` | authored or normalized | Produces deterministic counts, registries, security-review entries, and sanitized hook metadata. |
| `Selecto.Domain.Sections.sections/0` | none | Returns the finite recognized top-level vocabulary, grouped by diagnostic category, for documentation and certification coverage checks. |
| `Selecto.Domain.WriteContract.compile/1` | authored, normalized, or configured Selecto | Produces the explicit fail-closed write contract or an error. |
| `Selecto.Domain.composition_contract/1` | authored or normalized | Compiles deterministic `selecto.composition_contract.v1` nested relationship metadata. |
| `Selecto.Domain.consumer_projection_release/2` | authored or normalized plus target options | Produces an immutable, fingerprinted nested consumer release and rejects unsupported target features. |
| `Selecto.Domain.diff_consumer_projection_releases/2` | two consumer releases | Classifies relationship additions, removals, narrowed bounds, and policy changes as compatible or breaking. |
| `Selecto.Domain.nested_capability_matrix/0` | none | Returns current runtime/adapter features and their finite evidence boundaries. |
| `Selecto.Domain.ContractVerification.verify/3` | provider and consumer domains | Verifies canonical `domain_dependencies` against provider published surfaces. |
| `Selecto.Domain.ContractVerification.published_surfaces/2` | provider domain | Projects named published query surfaces and validates their references. |
| `Selecto.Domain.ContractVerification.snapshot/2` | provider domain | Produces a deterministic published-surface snapshot. |
| `Selecto.Domain.ContractVerification.diff_snapshots/2` | two snapshots | Classifies additive, review-required, and breaking published-surface changes. |
| `Selecto.CoDomain.definition/2` | source domain and co-domain id | Returns a validated governed-lookup declaration. |
| `Selecto.CoDomain.plan/5` | source domain, configured target, id, text, options | Builds a bounded, host-scoped governed lookup query. |
| `Selecto.CoDomain.lookup/5` | source domain, configured target, id, text, options | Executes the planned query and returns normalized presentation results. |

Compile-time modules may `use Selecto.DomainValidator, domain: domain` for a
static authored domain. Generated artifacts SHOULD also record `schema_version`,
`domain_version`, and a producer-computed `domain_fingerprint` so deployments
can detect drift. Core preserves but does not calculate the fingerprint.

## Elixir Example

```elixir
domain = %{
  schema_version: 1,
  domain_version: "0.5.0",
  domain_fingerprint: "sha256:9f5d...",
  name: "Orders",
  source: %{
    source_table: "orders",
    primary_key: :id,
    fields: [:id, :status, :customer_id],
    columns: %{
      id: %{type: :integer},
      status: %{type: :string},
      customer_id: %{
        type: :integer,
        reference: %{
          choice_source: :customer_choices,
          value_source: "customers.id",
          caption_source: "customers.name"
        }
      }
    },
    associations: %{
      customer: %{
        queryable: :customers,
        field: :customer,
        owner_key: :customer_id,
        related_key: :id
      }
    }
  },
  schemas: %{
    customers: %{
      source_table: "customers",
      primary_key: :id,
      fields: [:id, :name],
      columns: %{
        id: %{type: :integer},
        name: %{type: :string}
      },
      associations: %{}
    }
  },
  joins: %{
    customer: %{}
  },
  filters: %{
    "customer_name" => %{field: "customers.name"}
  },
  query_library: %{
    segments: %{
      active_orders: %{filters: [{:status, "active"}]}
    },
    projections: %{
      order_summary: %{fields: [:id, :status, :customer_id]}
    },
    orderings: %{
      orders_by_id: %{order_by: [{:id, :asc}]}
    },
    views: %{
      active_order_summaries: %{
        segments: [:active_orders],
        projection: :order_summary,
        ordering: :orders_by_id
      }
    }
  },
  components: %{query_params: false},
  source_relationships: %{
    customer: %{
      target_domain: :customers,
      source_field: :customer_id,
      target_field: :id,
      source_path: "customers",
      virtual_join: [
        %{working_field: :customer_id, source_field: "customers.id", required: true}
      ],
      filters: [{:eq, "customers.active", true}]
    }
  },
  choice_sources: %{
    customer_choices: %{
      domain: :customers,
      value_field: :id,
      label_field: :name,
      source_path: "customers",
      value_source: "customers.id",
      caption_source: "customers.name",
      filters: [{:eq, "customers.active", true}],
      order_by: ["customers.name"],
      presentation: %{
        control: :autocomplete,
        mode: :searchable,
        cardinality: :one
      },
      source_relationship: :customer,
      capability: "customer.choose"
    }
  },
  capabilities: %{
    "order.view" => %{operations: [:select, :detail]},
    "order.approve" => %{operations: [:action], action: :approve_order},
    "customer.choose" => %{operations: [:choice_source]}
  },
  writes: %{
    operations: %{
      update: %{enabled: true, require_filter: true, fields: [:status]}
    },
    fields: %{
      status: %{updatable: true}
    },
    transitions: %{
      status: %{
        "pending" => ["ready", "cancelled"],
        "ready" => ["complete", "cancelled"],
        "complete" => []
      }
    }
  },
  actions: %{
    complete_order: %{
      target: :order,
      scope: :row,
      capability: "order.approve",
      transition: %{field: :status, from: "ready", to: "complete"},
      execution: %{kind: :updato, operation: :update, set: %{status: "complete"}}
    }
  }
}

{:ok, normalized, diagnostics} = Selecto.Domain.validate(domain)
:ok = Selecto.DomainValidator.validate_domain(domain)
{:ok, write_contract} = Selecto.Domain.WriteContract.compile(normalized)
```

## JSON Equivalent

This JSON example is the string-keyed interchange equivalent. As described in
the key rules, hosts MUST translate only the finite documented vocabulary before
passing JSON-derived maps to the current query runtime:

```json
{
  "schema_version": 1,
  "domain_version": "0.5.0",
  "domain_fingerprint": "sha256:9f5d...",
  "name": "Orders",
  "source": {
    "source_table": "orders",
    "primary_key": "id",
    "fields": ["id", "status", "customer_id"],
    "columns": {
      "id": {"type": "integer"},
      "status": {"type": "string"},
      "customer_id": {
        "type": "integer",
        "reference": {
          "choice_source": "customer_choices",
          "value_source": "customers.id",
          "caption_source": "customers.name"
        }
      }
    },
    "associations": {
      "customer": {
        "queryable": "customers",
        "field": "customer",
        "owner_key": "customer_id",
        "related_key": "id"
      }
    }
  },
  "schemas": {
    "customers": {
      "source_table": "customers",
      "primary_key": "id",
      "fields": ["id", "name"],
      "columns": {
        "id": {"type": "integer"},
        "name": {"type": "string"}
      },
      "associations": {}
    }
  },
  "joins": {
    "customer": {}
  },
  "filters": {
    "customer_name": {"field": "customers.name"}
  },
  "query_library": {
    "segments": {
      "active_orders": {"filters": [["status", "active"]]}
    },
    "projections": {
      "order_summary": {"fields": ["id", "status", "customer_id"]}
    },
    "orderings": {
      "orders_by_id": {"order_by": [["id", "asc"]]}
    },
    "views": {
      "active_order_summaries": {
        "segments": ["active_orders"],
        "projection": "order_summary",
        "ordering": "orders_by_id"
      }
    }
  },
  "components": {"query_params": false},
  "source_relationships": {
    "customer": {
      "target_domain": "customers",
      "source_field": "customer_id",
      "target_field": "id",
      "source_path": "customers",
      "virtual_join": [
        {"working_field": "customer_id", "source_field": "customers.id", "required": true}
      ],
      "filters": [["eq", "customers.active", true]]
    }
  },
  "choice_sources": {
    "customer_choices": {
      "domain": "customers",
      "value_field": "id",
      "label_field": "name",
      "source_path": "customers",
      "value_source": "customers.id",
      "caption_source": "customers.name",
      "filters": [["eq", "customers.active", true]],
      "order_by": ["customers.name"],
      "presentation": {
        "control": "autocomplete",
        "mode": "searchable",
        "cardinality": "one"
      },
      "source_relationship": "customer",
      "capability": "customer.choose"
    }
  },
  "capabilities": {
    "order.view": {"operations": ["select", "detail"]},
    "order.approve": {"operations": ["action"], "action": "approve_order"},
    "customer.choose": {"operations": ["choice_source"]}
  },
  "writes": {
    "operations": {
      "update": {"enabled": true, "require_filter": true, "fields": ["status"]}
    },
    "fields": {
      "status": {"updatable": true}
    },
    "transitions": {
      "status": {
        "pending": ["ready", "cancelled"],
        "ready": ["complete", "cancelled"],
        "complete": []
      }
    }
  },
  "actions": {
    "complete_order": {
      "target": "order",
      "scope": "row",
      "capability": "order.approve",
      "transition": {"field": "status", "from": "ready", "to": "complete"},
      "execution": {
        "kind": "updato",
        "operation": "update",
        "set": {"status": "complete"}
      }
    }
  }
}
```

## Diagnostics Example

```elixir
{:ok, _normalized, diagnostics} = Selecto.Domain.normalize(%{
  source: %{
    source_table: "orders",
    primary_key: :id,
    fields: [:id],
    columns: %{id: %{type: :integer}}
  },
  schemas: %{},
  joins: %{},
  custom_columns: %{},
  writes: %{},
  old_write_flag: true
})

diagnostics.schema_version_inferred
#=> true

Enum.map(diagnostics.warnings, & &1.code)
#=> [:schema_version_inferred, :projection_sections, :proposed_sections, :unknown_sections]

diagnostics.unknown_sections
#=> [:old_write_flag]
```

Use `Selecto.Domain.validate/1` when callers want contract errors in addition to
normalization diagnostics.
