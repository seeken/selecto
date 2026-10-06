# Adapter Migration

Selecto now expects app-owned database adapter packages.

## What This Means

- `selecto` provides the query builder and shared adapter contract
- applications add the adapter package they actually use
- adapter packages live in separate Hex modules such as:
  - `selecto_db_postgresql`
  - `selecto_db_mysql`
  - `selecto_db_mariadb`
  - `selecto_db_mssql`
  - `selecto_db_duckdb`
  - `selecto_db_sqlite`

## Installation Pattern

Add `selecto` plus the adapter package your app needs:

```elixir
def deps do
  [
    {:selecto, ">= 0.5.0 and < 0.6.0"},
    {:selecto_db_postgresql, ">= 0.5.0 and < 0.6.0"}
  ]
end
```

Then configure Selecto with that adapter module:

```elixir
Selecto.configure(domain, db_opts, adapter: SelectoDBPostgreSQL.Adapter)
```

## Current Direction

PostgreSQL remains the reference backend, but database-specific behavior now
lives outside core `selecto`, including PostgreSQL behavior in
`selecto_db_postgresql`.

The historical `postgrex_opts` struct field has been removed. Pass an explicit
adapter and adapter-specific connection input to `Selecto.configure/3`; core
stores the resulting connection as an opaque runtime handle and does not infer
a database from its shape.

## 0.5 Migration Checklist

- Add the database adapter package explicitly and pass its adapter module when
  configuring Selecto. There is no implicit PostgreSQL default.
- Replace `postgrex_opts` with the adapter-neutral runtime connection input.
- Replace `Selecto.DB.PostgreSQL` calls with the corresponding adapter API.
- Replace `Selecto.Jsonb`/`:jsonb` domain declarations with portable
  `Selecto.Json`/`:json`, or use an explicitly scoped
  `{:native, :postgresql, type}` declaration when portability is not intended.
- Treat text search, collections, intervals, hierarchy paths, table functions,
  and views as capability-gated requests. Unsupported adapters now return
  structured errors instead of inheriting PostgreSQL SQL.
- Move PostgreSQL query analysis and `mix selecto.bench` usage to
  `selecto_db_postgresql`.

Run the package boundary gate after migration:

```sh
scripts/check_postgresql_boundary.sh
```

## Computed-value rendering

The governed computed-value AST remains unchanged. Core composes field references,
addition/subtraction/multiplication, coalesce, lower/upper and case expressions
using the configured adapter's quoting and parameters. A condition or child
expression may itself need an adapter-owned fragment.

Typed literals, explicit casts, the casts used by concatenation and division,
and `json_text` require the optional dialect callback `render_computed_value/2`.
It receives a `Selecto.Dialect.ComputedValue` with exactly two operations:

- `:cast`: a compiled expression and a canonical type (`string`, `integer`,
  `decimal`, `boolean`, `date` or `utc_datetime`).
- `:json_text`: a compiled JSON expression and ordered, bound path markers.

The renderer owns native cast targets and JSON syntax and must preserve parameter
markers and their order. It rejects unknown types, operations and malformed
fragments. Core has no database-specific fallback. A dialect without the callback
returns a structured `:computed_value` unsupported-fragment error when one of
these operations is requested; other queries continue to compile normally.

Use the PostgreSQL companion adapter containing `render_computed_value/2` before
upgrading Core. That adapter can also compile against older Core pins, which do
not call the optional callback. Previously published adapters without it do not
support the newly delegated computed fragments. This change does not enroll any
additional runtime, adapter or portable certification profile.

The boundary audit's only input compatibility exceptions are three exact lines
recognizing historical JSON and zone-aware timestamp aliases. Those exceptions
do not allow native rendering or exempt an entire source file. Runtime identifier
interning has a separately documented one-line atom-audit exception: its validated
creation site is serialized with process-specific global-lock requesters and
charged against a fixed VM-lifetime budget.
