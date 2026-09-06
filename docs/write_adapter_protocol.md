# Portable write adapter protocol

This document describes the Selecto 0.4.13 default-branch contract. Until the
coordinated packages are published, released Hex versions may expose the older
capability shape.

## Ownership

`selecto_updato` validates domain-governed intent and emits a database-neutral
`Selecto.Write.Command`, `Batch`, or `Graph`. Core `selecto` validates that
portable value, validates the adapter's versioned capability report, and fails
before dispatch if the adapter cannot preserve every requested semantic. The
configured `selecto_db_*` adapter owns SQL generation, bound parameters, the
native driver, connection affinity, transactions, returning values, logical
affected-row normalization, and rollback.

No layer requires an Ecto Repo, schema, changeset, or application Ecto
configuration. An adapter may offer an optional integration, but native driver
connections remain sufficient.

```text
domain policy -> selecto_updato -> Selecto.Write value
                                      |
                              selecto preflight
                                      |
                              selecto_db adapter
                                      |
                          native driver and database
```

## Versioned capabilities

Every write adapter reports `protocol_version: 1`. Core derives requirements
from the concrete write value:

- a command requires its operation and operation-specific returning when used;
- a batch also requires transactions and atomic batch execution;
- a graph also requires transactions and graph execution, plus generated keys
  for bindings and operation-specific returning for requested root results.

Missing or incompatible capability metadata returns a structured
`Selecto.Write.Error` before the adapter preview or execution callback runs.
`affected_rows` always means logical rows matched and authorized by the
governed command, not a database's physical changed-byte count.

Execution failures cross the portable boundary only as sanitized adapter and
reason categories. Driver exception structs, connection handles, SQL text, and
bound values are not retained in `Selecto.Write.Error.details`; adapters should
add portable constraint codes deliberately rather than forwarding driver data.

### Document shape refinements

The experimental single-document action profile attaches a typed
`Selecto.Write.DocumentMutation` to `Command.metadata.document`. The existing
identified-element increment and the root scalar-patch profile are separate;
they cannot be mixed in one command.
`DocumentMutation.capabilities/0` preserves the original required capability
list. `capabilities/1` also derives requirements from the mutation's optional
`shape_features`, which defaults to `[]` for existing shapes.

An approved release with any root or child scalar-array refinement contributes
`"scalar_array"` through `ShapeRelease.features/1`. Updato carries that exact
list into the governed mutation; core then requires `:document_scalar_array`
from the write adapter. The adapter must compare the declared features with
the actual approved release and preserve those shape checks atomically. This
closes a compatibility gap for writes targeting newer shapes; it grants no new
write operation or writable path. Unknown or duplicate feature names are invalid.

### Root scalar patches and selected postimages

A root patch contains 1–8 exact portable entries:

```elixir
[
  %{op: :set, path: ["title"], value: "Updated"},
  %{op: :unset, path: ["schedule", "due_at"]}
]
```

`DocumentMutation.root_patch?/1` identifies this profile without granting its
validity. `validate/1` rejects additional entry keys, unsafe paths, duplicate or
overlapping paths, and writes overlapping identity, tenant, version, or receipt
storage. `scalar_value?/1` accepts UTF-8 strings of at most 16,384 bytes,
integer53, booleans, canonical ObjectIds, and null. Floats, arbitrary objects,
arrays, native structs, and the Missing sentinel are outside this profile.
`scalar_value_bytes/1` returns `{:ok, bytes}` for valid values: raw string bytes
or canonical JSON bytes for the other scalars. Set values total at most 65,536
bytes; unset contributes zero. Tagged set values require the `"object_id"`
shape feature even when the selectors are strings.

Core derives `:document_set` and `:document_unset` from actual entries. The
existing `capabilities/0` result, mutation struct fields, deterministic increment
hashes, and receipt encoding remain unchanged. Root patches use `returning:
:none` or 1–16 distinct safe string field IDs, in authored order. They reject
`:all`, empty lists, and native paths. Returning a list derives both
`:document_postimage` and `{:returning, :update}`, even if the caller supplies
no required capabilities. Existing element returning remains subject to the
adapter's previously unsupported profile.

The action layer resolves published root fields and verifies explicit write and
returning grants. It also protects discriminator and server-managed paths,
requires nullable fields for set-null and missing-preserve fields for unset,
and enforces each declared scalar type. The adapter must verify these policies,
require existing plain-object intermediate parents, validate both the complete
original and candidate document including owned-object refinements, and apply
the patch, version, receipt, and durable effects in one conditional atomic write.
This portable core contract alone does not prove that a database implements it.

`Selecto.Write.DocumentPostimage` validates the persisted `receipt.postimage`
cells. The ordered projection contains exact string-keyed entries:

```elixir
projection = [
  %{"id" => "title", "type" => "string", "nullable" => false, "missing" => "reject"},
  %{"id" => "due_at", "type" => "string", "nullable" => true, "missing" => "preserve"}
]

cells = [
  %{"field" => "title", "present" => true, "value" => "Updated"},
  %{"field" => "due_at", "present" => false}
]
```

Projection types are string, integer, boolean, or object_id. Every cell has
exactly the displayed keys; a present null includes `"value" => nil`, while
an absent cell has no value key. `validate(cells, projection)` returns `:ok`
or a sanitized write error. `decode/2` returns `{:ok, [row_map]}`, converting
absent cells to `Selecto.Document.Missing` and preserving null and ObjectId tags.
The row map uses the projection's field IDs.

`budget(cells)` returns `{:ok, bytes}` for syntactically valid cells, including
valid cells whose budget exceeds the limit. The conservative formula is 64 plus
256 per cell, plus six times each field ID's UTF-8 bytes, plus six times each
string value's UTF-8 bytes. `validate/2` and `decode/2` require at most 16,384.
This bounds JSON escaping without depending on the adapter's JSON implementation.
The adapter must enforce it before committing. Replays decode the originally
persisted cells, including after later successful edits; a separate read of the
current document is not an equivalent result.

## Default-branch capability matrix

This table summarizes the executable `write_capabilities/1` reports and suites
in this workspace; the maps in adapter code are the source of truth.

| Adapter | Flat writes | Returning | Atomic batch | Generated-key graph | Native upsert strategy |
| --- | --- | --- | --- | --- | --- |
| PostgreSQL | yes | `RETURNING` | yes | yes | conflict upsert; PostgreSQL 17 MERGE for eligible sync |
| DuckDB | yes | `RETURNING` | yes | yes | `ON CONFLICT`; ordered graph fallback |
| SQLite | yes | SQLite 3.35+ | yes | SQLite 3.35+ | `ON CONFLICT` |
| SQL Server | yes | `OUTPUT` | yes | yes | `MERGE WITH (HOLDLOCK)` |
| MariaDB | yes | no portable arbitrary returning | yes | no | `ON DUPLICATE KEY UPDATE`; one declared target only |
| MySQL | yes | no | yes | no | `ON DUPLICATE KEY UPDATE`; one declared target only |

MariaDB and MySQL reject graph or returning requests rather than constructing a
weaker multi-statement imitation. DuckDB reports MERGE availability for
diagnostics but does not advertise portable MERGE execution because its current
prepared driver path cannot bind MERGE parameters safely.

MySQL and MariaDB accept upsert only when Updato metadata proves that the domain
declares one matching conflict target. Their native syntax cannot name a target
constraint, so zero- or multi-target contracts fail closed rather than risk
activating the update arm through a different unique index.

For every adapter, a tenant-scoped Updato domain must include its tenant field
in each upsert conflict target. The trusted tenant value is also an insert
assignment, so both conflict selection and the insert arm remain tenant-bound.

## Verification boundary

Core's bounded `selecto.write_capability_preflight.v1` model checks 30 finite
states and 90 invariants. It proves fail-closed dispatch only within that model.
It does not prove SQL, drivers, database engines, triggers, constraints,
transactions, concurrency, or external side effects.

DuckDB and SQLite have local live execution tests. PostgreSQL retains its
separate live matrix. SQL Server, MariaDB, and MySQL currently have compiler and
callback suites in this workspace; their external-service concurrency and
trigger matrices remain release gates.
