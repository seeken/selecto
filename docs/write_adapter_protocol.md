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
identified-element increment remains the only mutation in that profile.
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
