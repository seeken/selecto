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
joins, unrestricted arrays, offsets, aggregation, arbitrary vendor types and
residual query execution are outside this initial profile.

The default query bounds are 100 returned rows, 1 MiB of results, 5 seconds of
backend operation time and 32 predicates. Hard maxima are 1,000 rows, 16 MiB,
30 seconds and 128 predicates, with depth capped at 8. Connected adapters may
impose lower limits. Adapters fetch one extra row to decide whether a next
page exists. Bounds apply to fetched material as well as normalized output;
the extra row may cause an otherwise near-limit request to fail explicitly.

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
