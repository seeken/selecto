# Experimental document source queries

The version-1 document query seam consumes approved `Selecto.Document.ShapeRelease`
artifacts. It coexists with the existing SQL query builders and does not install
a database driver or create a connection.

```elixir
release = Selecto.Document.Fixtures.release() # synthetic example only

{:ok, plan} = Selecto.to_plan(release, "work_orders", %{
  "select" => ["id", "title", "due_at"],
  "where" => %{"op" => "eq", "field" => "state", "value" => "open"},
  "limit" => 20
}, trusted_context: %{tenant_id: authorized_tenant_id})

{:ok, result} = Selecto.execute_plan(plan, source_adapter, host_connection,
  cursor_secret: host_cursor_signing_key)

{:ok, json} = Selecto.Output.Formats.transform(
  Selecto.Query.Result.to_raw(result), :json)
```

The host supplies tenant scope after authenticating and authorizing the caller.
Plan structs are host-authored intent, not authorization tokens. Do not accept
serialized plans from an untrusted caller; accept the bounded query map and
rebuild it with trusted context. Continuation values are executable only when
the stored signed cursor revalidates against the host key at execution time.
The query map cannot replace the collection, tenant binding, native paths, or
approved field permissions. `ShapeRelease.approve/2` is an explicit authoring
step; a digest is integrity evidence, not caller authorization.

Supported input consists of published field projection, typed predicates,
stable ordering, signed cursor pagination, an authored access pattern and hard
execution bounds. Comparisons reject `nil`; use `is_null`, `missing`, `exists`
or `is_not_null` deliberately. Ordinary comparisons exclude missing/null and
reject mismatched operand types. Ordering requires required non-null scalar
fields and a stable identity tiebreaker. The adapter must prove the required
index and reject unsupported sorting or scanning.

An array relation query must also specify `"parent_identity"`. Child identity
is unique within that parent and the trusted tenant. The approved child relation
declares a maximum expansion and rejects duplicate element identities. Native
joins, unrestricted arrays, offsets, grouped aggregation, arbitrary vendor types and
residual query execution are outside this initial profile.

Explicit `object_id` fields accept only canonical portable tagged maps. Construct
one deliberately with `Selecto.Document.ObjectId.new/1`; a 24-hex string remains
a string. The type supports existing exact comparisons, `in`, presence/null
predicates, required-non-null ordering, and stable root/child identity. Array and
owned-object parent scopes resolve the declared root identity type and require
the same tagged value when it is ObjectId. Numeric aggregation and scalar-array
ObjectId membership are not enabled by this type.

Signed cursor payloads use canonical JSON and preserve ObjectId tags. Cursor
validation checks the tag and binds it to the release, tenant, parent, and query;
there is no BSON driver object in the token. Projected ObjectId values and
inherited parent metadata retain the portable tag. A declared optional field may
still return its permitted missing sentinel or null, and `Result.validate/2`
rejects other representations.

The plan requires `document.object_id` for every release containing any ObjectId
field, including unselected root fields, child-only declarations and root counts.
This is a separate capability from `document.object_relation` and
`document.scalar_array`; supporting one does not imply the others. A native
adapter owns explicit BSON conversion and native type guards. SQL controls that
have not certified this family reject the release before execution.

The default query bounds are 100 returned rows, 1 MiB of results, 5 seconds of
backend operation time and 32 predicates. Hard maxima are 1,000 rows, 16 MiB,
30 seconds and 128 predicates, with depth capped at 8. Connected adapters may
impose lower limits. Adapters fetch one extra row to decide whether a next
page exists. Bounds apply to fetched material as well as normalized output;
the extra row may cause an otherwise near-limit request to fail explicitly.

## Root aggregates

An independently approved release can grant root `count` and integer-field
`sum`, `min`, and `max`. The original fixture release has no aggregate grants;
`Fixtures.aggregate_release/0` is a separately authored example.

```elixir
{:ok, plan} = Selecto.to_plan(
  Selecto.Document.Fixtures.aggregate_release(),
  "work_orders",
  %{
    "aggregate" => [
      %{"op" => "count", "as" => "total"},
      %{"op" => "sum", "as" => "priority_sum", "field" => "priority"},
      %{"op" => "min", "as" => "priority_min", "field" => "priority"},
      %{"op" => "max", "as" => "priority_max", "field" => "priority"}
    ],
    "where" => %{"op" => "eq", "field" => "state", "value" => "open"},
    "bounds" => %{"max_input_rows" => 1000}
  },
  trusted_context: %{tenant_id: authorized_tenant_id}
)
```

The `aggregate` list contains 1–16 strict objects with unique aliases from the
portable field-id alphabet. `count` counts matching documents and has no field
argument; it requires `aggregate_ops: ["count"]` on the root relation. Numeric
operations name published integer fields whose explicit `aggregate_ops` list
grants that operation. An absent grant means unsupported. Aggregate queries
reject `select`, `order_by`, `limit`, and `cursor`, including empty values. Array
aggregates, grouping, distinct, averages, and native expressions have no syntax.
Tenant scope, typed predicates and declared access patterns remain required.

Every successful aggregate returns exactly one row, columns in requested alias
order, and no cursor. Empty input yields `count = 0` and `sum/min/max = nil`.
Missing and null numeric inputs are excluded when their ShapeRelease policy
permits those states; an all-missing/null field produces `nil`, including for
`sum`. Invalid document shapes or input types cause failure, not coercion or
silent exclusion. These empty-value rules are portable contract decisions.

Aggregate plans add a `max_input_rows` bound, default 1,000 and maximum 10,000.
Adapters must detect one additional matching document and reject overflow;
truncated totals are never successful results. This bounds matching inputs,
not all documents a backend may examine while finding matches. Index evidence,
backend timeout and result-byte limits still apply. Row queries keep their
existing bounds and do not require an aggregate input limit.

Numeric results and `min/max` inputs must be exact integers within
±9,007,199,254,740,991. Each `sum` input has the stricter absolute limit
`div(9_007_199_254_740_991, max_input_rows)`. This guarantees every intermediate
sum fits that exact range even with mixed signs. Values exceeding the declared
input limit fail even when cancellation would make the final total fit.
`Plan.aggregate_input_limit/2` and `aggregate_input?/3` expose that arithmetic
contract to adapters; whole-document shape validation remains independent.

Normalized plans store aggregate descriptors in `aggregates`, output
`id/type/nullable` descriptors in `projection`, an empty `ordering`, and a
one-row page. Required capabilities are `query.aggregate.count/sum/min/max`
for the requested operations, plus the applicable source, nested-field and
predicate capabilities. Aggregation must run natively. Bounded input evidence
for shape validation may be returned only with explicit residual metadata and
byte checks; it does not authorize client-side aggregation.

## Bounded scalar-array membership

A published array field with an approved `scalar_array` descriptor can grant
three typed predicates through its `predicate_ops` list:

```elixir
%{"op" => "contains", "field" => "tags", "value" => "urgent"}
%{"op" => "contains_any", "field" => "tags", "value" => ["urgent", "routine"]}
%{"op" => "contains_all", "field" => "ratings", "value" => [1, 2]}
```

`contains` requires one exact element-family literal. `contains_any` and
`contains_all` require 0–100 exact typed literals. Operand duplicates have no
additional effect. Matching is case-sensitive and uses exact types without
number/string/boolean coercion. The only supported element families are string,
portable 53-bit integer, and boolean; strings must be valid UTF-8 and at most
16,384 bytes. Native operators, arbitrary paths, null operands and nested values
are rejected during planning. The grant is separate from generic filtering;
it does not enable ordering or generic comparisons on an array value.

The predicate is true only when the **entire stored array** is within its
authored element bound, every element has the exact declared type, and the
membership condition holds. Missing, null, wrong containers, mixed types, null
elements and oversized arrays are nonmatches. A valid-looking prefix of an
invalid or oversized array never matches. This is the same typed-guard rule
used by scalar comparisons; it is not a promise to report every invalid source
document encountered while filtering.

For an empty operand list, `contains_any` is false. `contains_all` is true for a
present, fully valid array, including an empty array, and false otherwise.
Stored duplicates and source order do not affect membership. Whole-document
validation remains mandatory: an unfiltered read/count or another successful
`or` branch that selects a malformed array-bearing document fails its approved
shape check. It must not return that document or count it successfully.

Root and existing identified-child fields share the contract. Child queries
still require the parent identity and trusted tenant. Boolean composition,
signed pagination and root aggregates retain their existing boundaries.
Membership executes natively over at most `max_elements + 1` inspected elements;
this does not authorize unnesting, client-side filtering, new relationships or
array writes.

Each operation requires its `predicate.contains`, `predicate.contains_any` or
`predicate.contains_all` capability. Every query consuming a release with any
scalar-array descriptor also requires `document.scalar_array`, even a count
query or projection that does not expose the refined field. This prevents an
older native adapter from silently ignoring new shape invariants.

## Cursors, results, and adapter execution

Owned object relations use the same query entry point with an explicit parent:

```elixir
Plan.new(release, "work_order_schedule", %{
  "parent_identity" => "wo-1",
  "select" => ["due_at", "timezone", "duration_minutes"],
  "where" => %{"op" => "eq", "field" => "timezone", "value" => "UTC"}
}, trusted_context: %{tenant_id: "tenant-a"})
```

The result has zero or one row. The only accepted explicit `limit` is integer 1;
ordering, cursor, and aggregate options are rejected, including empty or null
options. Child field paths are object-relative and governed predicate grants,
types, byte/time bounds, and trusted tenant scope still apply. The adapter must
detect duplicate matched parents, validate the complete matched parent before
considering the child predicate, and preserve missing/null semantics. This
profile performs no join, pagination, recursive traversal, or object mutation.

Both empty and single-row object results include the exact string-keyed metadata
`metadata["relation_identity"] = %{"kind" => "parent", "parent_relation" =>
"work_orders", "parent_identity" => "wo-1"}` and have `next_cursor: nil`.
`Result.relation_identity_metadata(plan)` supplies this metadata value;
`Result.validate/2` rejects missing or altered inherited identity. The identity
is result metadata and is not silently injected as a projected data column.

Every query consuming an owned-object release requires
`document.object_relation`, including a root projection or count that does not
select the object. Refined scalar arrays in object fields additionally require
`document.scalar_array`. A governed action against the release similarly needs
`:document_object_relation`; this gate protects complete shape validation and
does not authorize a new mutation operation.

The cursor key is a host secret of at least 32 bytes and is never stored in the
plan. Tokens bind the tenant, release digest, relation/parent, predicate,
ordering and profile, and expire after 15 minutes by default. Key ordering is
stable; cursor pagination does not promise a snapshot while records change.

`Selecto.Query.Result` contains `rows`, published `columns`, safe `metadata`, and
`next_cursor`. `to_raw/1` feeds existing map/JSON output transformers. A missing
value remains `%Selecto.Document.Missing{}` and serializes as
`{"$selecto":"missing"}`; explicit null stays `null`. UI consumers must decide
how to display the missing state rather than silently merging it with null.

`Selecto.DB.QueryAdapter` exports versioned capability, compile, preview and
execute callbacks, plus optional explain/inference callbacks. Both enabled and
certified capability evidence must satisfy the plan before execution. Compiled
artifacts are adapter-owned; previews contain structural metadata without
predicate values. Plans themselves contain bound values and are sensitive data,
even though their default `Inspect` output is redacted.

The MongoDB reference implementation lives in `selecto_db_mongodb`.
`SelectoDBSQLite.DocumentQueryAdapter` provides an embedded SQL control over a
JSON `document` column using the same root plan and the existing SQLite adapter.
Its host-owned table/index setup is documented in that package. Neither the
new source SPI nor fixture tests certify all databases or all BSON semantics.

Document actions remain governed by Updato and compile to the existing
`Selecto.Write.Command` with typed `DocumentMutation` metadata. The initial
profile supports one positive integer increment of an identified array element,
protected version advancement, bounded embedded idempotency receipts and
durable effect intent. It does not promise external exactly-once delivery,
multi-document transactions or a general document mutation language.
