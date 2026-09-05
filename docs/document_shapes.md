# Document shapes and reviewed releases

The initial document contract adds bounded structural inference and an explicit
authoring workflow. It does not make an inferred field queryable or writable.
The native reference slice uses a reviewed MongoDB work-order collection;
the core inference engine itself only consumes caller-supplied JSON-shaped
documents and has no database connection or driver dependency.

## Inspect, review, approve, compare

```elixir
alias Selecto.Document.{Canonical, Draft, Drift, Fixtures, Inference, ShapeRelease}

{:ok, report} = Inference.run(Fixtures.work_orders(),
  max_documents: 100,
  max_document_bytes: 64_000,
  max_bytes: 1_000_000,
  max_depth: 8,
  max_fields: 100,
  max_array_elements: 200,
  max_flavors: 16,
  timeout_ms: 1_000,
  max_report_bytes: 64_000,
  excluded_paths: [["source_payload"]]
)

# Advisory suggestions: these are not a runnable ShapeRelease.
{:ok, suggestions} = Draft.from_report(report)

# In a real workflow the author supplies this policy. The fixture is an
# independently authored, synthetic example of those explicit decisions.
authored = Fixtures.shape()
{:ok, draft} = Draft.build(report, authored)
{:ok, release} = ShapeRelease.approve(draft, approved_by: "domain-author")
:ok = ShapeRelease.validate(release, require_approved: true)
json_artifact = Canonical.encode(release)

{:ok, later_report} = Inference.run(Fixtures.legacy_work_orders())
{:ok, drift} = Drift.compare(release, later_report)
```

`Draft.build/2` preserves authored field and access policy exactly, records the
inference digest, and returns a draft. `approve/2` requires a bounded reviewer
identifier and computes the release digest. Approval is an explicit authoring
operation; its metadata is not a cryptographic signature or proof that the
caller is authorized. The host must restrict who may approve and distribute
release artifacts. Approved releases cannot be passed back through `new/1` or
`Draft.build/2`; an author must create a new release version. The host's artifact
store owns uniqueness and immutability of published release ids.

All serialized artifact keys are strings. `Canonical.encode/1` sorts object
keys, preserves array order, and emits JSON without formatting whitespace.
`Canonical.digest/1` hashes those bytes using SHA-256. Reports and releases hash
their content with the top-level `digest` omitted. Reports are validated by
`InferenceReport.validate/1` before draft or drift processing. These are separate
schema-version-1 artifacts; they are not automatically registered as a new
section in the existing relational Domain schema.

## What inference measures

Inference retains safe field paths, structural type counts, document presence
and explicit-null counts, bounded array-length observations, and structural
flavors. A flavor's id hashes its sorted `structure` entries (paths and observed
type families); the report includes its document count. A structural flavor is
an authoring suggestion, not a business variant or authorization decision.

The supported input values are string-keyed maps, lists, valid UTF-8 strings,
integers, floats, booleans, and null. Unknown structs, atom keys, process terms,
and invalid UTF-8 values produce explicit warnings and rejected documents.
Integer and floating-point evidence stays distinct. BSON-specific types require
an adapter-owned lossless normalization contract before they can be inferred;
silently stringifying arbitrary BSON values is outside this version.

No sample values, enum candidates, value hashes, minimum/maximum values, or
inferred relationships are retained. `collect_values: true` returns
`:value_collection_not_supported`. The value-free engine cannot discover
discriminator values, prove identity uniqueness, or infer foreign-key integrity.
Field names themselves may be sensitive: callers must apply appropriate source
access controls to reports. `excluded_paths` suppresses whole subtrees, including
their names and flavor contributions. Only the number of exclusions is recorded.

`present_documents` and `null_documents` count documents, including for paths
inside arrays. `observations` and type counts count individual observations; a
child field seen twice in one array contributes one present document and two
observations. A `required_candidate` is only sample coverage. It does not prove
that every element of an array contains the field. Array lengths describe the
bounded sampled prefix, explicitly flagged when truncated.

## Resource boundaries and determinism

| Option | Default | Maximum |
|---|---:|---:|
| `max_documents` | 1,000 | 10,000 |
| `max_document_bytes` | 512,000 | 5,000,000 |
| `max_bytes` | 5,000,000 | 50,000,000 |
| `max_depth` | 8 | 32 |
| `max_fields` | 256 | 4,096 |
| `max_array_elements` | 100 | 10,000 |
| `max_flavors` | 64 | 512 |
| `timeout_ms` | 1,000 | 30,000 |
| `max_report_bytes` | 256,000 | 5,000,000 |

Bounds must be positive integers; report budgets below 1,024 bytes are rejected.
Byte preflight counts a conservative JSON-size upper bound without serializing
or retaining the input values. It has its own hard 64-step input-depth ceiling.
The cumulative inspection budget includes rejected documents, conservatively
charging the remaining per-document budget for unsupported or over-depth input.
Accepted-document bytes and inspection-budget charges are reported separately.

Evidence traversal respects the smaller requested depth, field count, and
array-prefix limits. A worker deadline interrupts even an input enumerable that
does not yield. An externally timed-out worker returns `:inference_timeout`, not
a partial success. A completed report with a traversal warning sets `truncated`.
Output paths/flavors are reduced, with `max_report_bytes` reported, until the
canonical JSON including its digest fits the output budget; an impossibly small
budget returns an error.

These limits bound processing and retained evidence. They do not prevent the
caller from first materializing an enormous input collection, nor impose a hard
process-memory ceiling on supplied Elixir terms. Supply a bounded stream and
apply database-side sampling limits before calling the engine. Source sampling
authorization, connection/server version, live locators, timestamps, and
connection cleanup belong to the adapter or host wrapper. The core report uses
`caller_supplied` provenance and contains no credential-bearing locator.

Complete fixture reports are byte-stable across input-map and document order.
Field and flavor caps retain deterministic sorted subsets. Document, byte,
array-prefix, and time truncation can select different evidence for different
input orders; warnings make those limits explicit. Hitting `max_documents`
conservatively records truncation without fetching an extra document merely to
check whether the input has ended. Live random samples are not deterministic
source truth. Wall-clock timestamps are deliberately outside the canonical
structural report.

## Release schema and virtual relations

`Fixtures.shape/0` is the complete, executable reference artifact. Its main keys
are `schema_version`, `id`, `status`, `source`, `shape`, and `relations`. The source
declares its collection, explicit identity/tenant/version paths, and an optional
SQL control table. Credentials and arbitrary metadata are rejected. The tenant
field is a required non-null string, the version is a required non-null integer,
and all three source metadata fields are marked `server_managed`.

Every field explicitly declares a parsed path, one type, requiredness, nullability,
and `missing: "preserve" | "reject"`. Required fields reject missing. Opaque
`object`/`array` fields disable filtering and sorting; subpaths must be authored
as separate fields. Scalar types are `string`, `integer`, `float`, `boolean`, and
`binary`; each adapter still has to declare which it can execute losslessly.
There is no coercion, raw native expression, executable metadata, automatic
default, arbitrary dynamic-key expansion, or implicit write permission.

Paths contain 1–32 string key segments, each 1–128 bytes in the portable alphabet
`[A-Za-z_][A-Za-z0-9_-]*`. Dotted strings, dollar-prefixed operators, NULs, numeric
array offsets, and arbitrary atoms are rejected. Inference array steps use the
typed JSON object `{"each": true}`; executable root/child field paths contain
object keys only. The combined parent/array-step/child path also fits 32 steps.
V1 deliberately does not expose source keys outside that portable alphabet.

The shape has a finite string discriminator registry with required, non-null
discriminator field and `unknown_policy: "reject"`. Variant-specific fields can
be declared optional, but this version does not model variant-conditioned
requiredness, structural predicate variants, union coercions, or precedence.
Unknown unexposed source fields are ignored by the reviewed shape.

Exactly one root relation publishes explicit shape field ids. A child relation
names its root parent, declared array path, stable element identity, element
fields, source ordering, duplicate-identity rejection, and maximum fan-out
(1–1,000). An absent or null optional array produces no child rows; the root
field retains its declared missing/null state. Ordinality is not stable identity
and no positional mutation permission is inferred. Each relation declares named
access patterns with an index identifier and ordered published-field keys. The
adapter must verify actual index presence and capability support; a release
declaration alone does not prove either.

`ShapeRelease.relation/2` returns the selected relation with its id attached.
`field/3` resolves only published fields, using root-relative paths for root
fields and element-relative paths for children. `validate_document/2` checks
required/null/type rules, known variants, child fan-out, object elements, and
unique stable child identities against an approved release. This is an
executable per-document check, not a proof about every document in a collection.

`Path.fetch/2` returns `%Selecto.Document.Missing{}` for an absent path, `nil` for
present null, and the actual value otherwise. JSON encoding of that sentinel is
`{"$selecto":"missing"}`. Consumers must treat the tag as result metadata;
missing must not be collapsed into null before predicate or mutation planning.

## Drift and proof limits

`Drift.compare/2` leaves both inputs unchanged and links their digests. It reports
observed incompatible types/nulls as breaking sample evidence and new unexposed
paths as additive review candidates. Unseen fields are inconclusive. Required
root-field absence is reported only when the sample was not truncated; child
presence counts do not prove per-element requiredness. Discriminator values,
identity uniqueness, indexes, references, live authorization, and datetime
meaning are explicitly listed as unevaluated.

No helper publishes a Domain, creates an index or validator, applies a live
schema change, or grants a governed action. BSON families, richer inference
statistics, opt-in redacted value inspection, validator previews, Studio drift
monitoring, change streams, Couchbase, and other database families remain outside
these core contracts. The focused tests cover deterministic synthetic evidence,
bounds, safe paths, malformed artifacts, approval/digest checks, drift semantics,
and work-order validation; live adapter behavior requires its own database tests.
