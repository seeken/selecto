# Selecto telemetry contract

Selecto emits vendor-neutral `:telemetry` events. Applications may attach any
compatible Elixir integration; Selecto has no required metrics, tracing, or
error-reporting vendor.

Canonical version 1 events use `[:selecto, :telemetry, ...]`. Every public
operation emits `:start` and exactly one observed `:stop` or `:exception` while
the owning BEAM process remains alive. Durations and system/monotonic times use
native time units. Missing measurements are omitted rather than reported as
zero.

The operation events are:

* `[:selecto, :telemetry, :operation, :start]`
* `[:selecto, :telemetry, :operation, :stop]`
* `[:selecto, :telemetry, :operation, :exception]`

Each database dispatch also emits the corresponding lifecycle under
`[:selecto, :telemetry, :adapter, ...]`. An adapter stop may include a row
count. The adapter event measures Selecto's adapter call; it does not claim to
separate driver queue, network, server, and decode time.

SQL compilation and result conversion emit lifecycles under `:compile` and
`:transform`. Cache-enabled execution emits one
`[:selecto, :telemetry, :cache, :lookup]` event with `count: 1` and the bounded
`cache_result` metadata value `:hit` or `:miss`.

Metadata contains only the versioned safe envelope: `schema_version`, an opaque
`operation_id`, `operation_kind`, adapter name, bounded `outcome` and
`error_category`, and the standard opaque `telemetry_span_context`. A successful
row-returning operation may include `row_count` on stop. IDs are correlation
fields and must not be metric tags.

SQL, parameters, result values, connection configuration, database error text,
tenant/user identifiers, and raw exceptions are excluded. Applications that
capture raised exceptions own that separate policy and must redact them for the
chosen error service.

Supported operation kinds include `execute`, `execute_with_metadata`, `count`,
`execute_one`, and `stream_open`. A stream-open success means a stream handle
was returned; it does not mean enumeration completed. Actual enumeration emits
`[:selecto, :telemetry, :stream, :start]` followed by `:stop` with
`stream_result: :completed/:cancelled`, or a sanitized `:exception`. Stop and
exception measurements include the number of rows delivered. An unconsumed or
suspended-and-abandoned stream has no false terminal event; consumers should
expire incomplete observations operationally.

Hosts may configure a module implementing
`Selecto.Telemetry.ContextProvider` under
`config :selecto, :telemetry_context_provider, MyProvider`. Selecto captures,
attaches, and detaches that optional context around its supervised task
boundaries. Callbacks must be local, fast, and must not perform network I/O.
Callback failures are isolated and do not change query behavior.

Legacy `[:selecto, :query, ...]` and `[:selecto, :cache, ...]` events remain for
compatibility. High-risk SQL text, cache keys, arbitrary analysis details, and
raw error terms are excluded from their default producers. Their names,
metadata, and units remain outside the canonical contract; new integrations
should consume canonical events only.

The packaged `priv/telemetry_events.json` file provides a machine-readable
inventory for tooling. Companion packages emit their own canonical namespaces,
including PostgreSQL transaction, Updato operation, Components action, Ledger,
and Operations gateway events.
