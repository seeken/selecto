# Selecto

> Alpha software. Expect API churn and breaking changes while the core package is still being hardened.

Selecto includes bounded formal-verification suites for tenant query scope and
provider/consumer domain compatibility. Run `mix selecto.verify`; see
[`docs/formal_verification.md`](docs/formal_verification.md) for the exact proof
boundary and JSON artifact support.

`selecto` is the core query engine in the Selecto ecosystem.

It gives you:

- domain-driven query configuration
- safe select/filter/group/order composition
- automatic join resolution from configured relationships
- aggregate and OLAP-style query support
- CTEs, lateral joins, and other advanced SQL shapes
- expression helpers and a named-function registry for reusable query AST

## Ecosystem

Use `selecto` with companion packages when you need more than the core engine:

- `selecto_components` for Phoenix LiveView query UI
- `selecto_mix` for domain generation and installation tasks
- `selecto_updato` for write operations over Selecto domains
- adapter packages such as `selecto_db_postgresql`, `selecto_db_mysql`, `selecto_db_sqlite`, and others
- `selecto_postgis` for spatial/map extension support

## Installation

Add `selecto` and the adapter package your app uses:

```elixir
def deps do
  [
    {:selecto, ">= 0.4.13 and < 0.6.0"},
    {:selecto_db_postgresql, ">= 0.4.11 and < 0.6.0"}
  ]
end
```

## Quick Start

Define a domain:

```elixir
domain = %{
  name: "Orders",
  source: %{
    source_table: "orders",
    primary_key: :id,
    fields: [:id, :total, :customer_id, :created_at],
    columns: %{
      id: %{type: :integer},
      total: %{type: :decimal},
      customer_id: %{type: :integer},
      created_at: %{type: :utc_datetime}
    },
    associations: %{
      customer: %{queryable: :customers, field: :customer, owner_key: :customer_id, related_key: :id}
    }
  },
  schemas: %{
    customers: %{
      source_table: "customers",
      fields: [:id, :name],
      columns: %{
        id: %{type: :integer},
        name: %{type: :string}
      }
    }
  },
  joins: %{
    customer: %{type: :star_dimension, display_field: :name}
  }
}
```

Build and run a query:

```elixir
selecto = Selecto.configure(domain, Repo)

{:ok, {rows, columns, aliases}} =
  selecto
  |> Selecto.select(["id", "total", "customer.name"])
  |> Selecto.filter([{"total", {:gt, 100}}])
  |> Selecto.order_by(["created_at"])
  |> Selecto.execute()
```

## Strict Mode

Use strict mode when query callers—including UI builders, saved queries, APIs,
and AI tooling—must stay inside a governed domain:

```elixir
selecto = Selecto.configure(domain, Repo, mode: :strict)

selecto
|> Selecto.select(["id", "total", "customer.name"])
|> Selecto.filter({"total", {:gt, 100}})
|> Selecto.execute()
```

Strict mode requires domain validation, seals the fully composed domain and its
compiled authority, rejects query-authored raw SQL, and prohibits structural or
ad-hoc joins. Domain joins may be enabled without overrides, and advanced row
sources must be applied through named `domain.query_members` definitions.

Trusted SQL declared by the domain remains available by default, which lets a
governed domain hide brownfield compatibility expressions behind stable field
names. Pass `domain_sql: :forbid` to reject declared SQL as well. Strict mode is
a Selecto governance boundary, not a substitute for database roles or row-level
security. See [`docs/strict_mode.md`](docs/strict_mode.md) for the complete
contract.

## Expression Helpers

Use `Selecto.Expr` when query structure is assembled dynamically in Elixir:

```elixir
alias Selecto.Expr, as: X

query =
  selecto
  |> Selecto.filter(
    X.compact_and([
      X.eq("status", "active"),
      X.when_present(search, &X.ilike("customer.name", "%#{&1}%")),
      X.gte("total", 100)
    ])
  )
  |> Selecto.select([
    X.field("id"),
    X.field("customer.name"),
    X.as(X.count("*"), "row_count")
  ])
```

For lighter authoring, Selecto also ships macro and sigil support. See `docs/expression_dsl.md` for the detailed guide.

## Named Functions (UDF Registry)

Selecto domains can register named database functions under `domain[:functions]`.

That lets you reuse typed scalar, predicate, and table-function definitions instead of scattering raw SQL fragments through your code.

```elixir
domain = %{
  # ...
  functions: %{
    "name_lower" => %{
      kind: :scalar,
      sql_name: "lower",
      returns: :string,
      allowed_in: [:select, :order_by],
      args: [%{name: :value, type: :string, source: :selector}]
    }
  }
}

query =
  selecto
  |> Selecto.select([
    "name",
    Selecto.Expr.as(Selecto.udf("name_lower", ["name"]), "normalized_name")
  ])
```

UDF-backed custom columns are also supported through `custom_columns[*].select`.

Registered function arguments are type-checked when Selecto can infer their
types. Functions with database overloads can declare an `overloads` list; each
entry supplies `args` and `returns` and may override `sql_name`. Selecto rejects
known type mismatches and ambiguous overloads before generating SQL. This is a
Selecto contract check, not proof that the connected database provides the
declared function or overload.

Adapters can optionally verify a resolved signature against a connected
database without executing the function:

```elixir
Selecto.verify_function(selecto, "similarity", ["name", "Acme"],
  call_site: :select,
  mode: :strict
)
```

The adapter must both advertise `supports?(:function_verification)` and
implement `verify_function/3`. It receives a protocol-versioned signature
request without the runtime argument values. `:warn` returns explicit
unsupported or indeterminate evidence; `:strict` fails unless the adapter
reports `:database_resolved`. Core ships the contract and dispatcher, but a
connected implementation remains adapter-owned;
`selecto_db_postgresql` implements catalog plus non-executing parse/describe
verification.

To verify every registered signature and optionally archive deterministic JSON,
provide a module that returns a configured Selecto value:

```elixir
defmodule MyApp.SelectoDomain do
  def selecto do
    Selecto.configure(MyApp.Domain.domain(), MyApp.Repo,
      adapter: SelectoDBPostgreSQL.Adapter
    )
  end
end
```

```sh
mix selecto.functions.verify --domain MyApp.SelectoDomain
mix selecto.functions.verify --domain MyApp.SelectoDomain \
  --strict --output tmp/selecto-functions.json
```

The task reports every overload in stable function-ID/signature order and
omits timestamps from the JSON artifact. Warn mode collects finite failure or
unsupported evidence without failing the command. `--strict` writes the
artifact first, then fails unless every signature is `:database_resolved`.
Both text and JSON state that connected resolution does not prove function
semantics or arbitrary database behavior.

See [`docs/function_verification.md`](docs/function_verification.md) for the
complete registry, PostgreSQL type-mapping, diagnostics, CLI-provider, and
evidence-boundary guide.

## Extensions

Selecto supports extension packages through the `:extensions` key on domains.

Example with PostGIS:

```elixir
domain = %{
  # ...
  extensions: [Selecto.Extensions.PostGIS]
}
```

Use extensions when a package needs to contribute domain metadata, overlay DSL, adapter type mapping, or companion-package integrations.

## Status

Current `0.4.x` scope:

- core query building is usable but not stable
- advanced subfilter internals are still high-risk/experimental
- adapter support exists across multiple databases, but PostgreSQL remains the most complete path
- schema/domain generation and UI are intentionally outside this package and live in companion repos

## Demos And Tutorials

- `selecto_livebooks` for guided notebooks
- `selecto_northwind` for tutorial-style examples
- `testselecto.fly.dev` for a hosted demo app

## Developer Guides

- `docs/developer_contracts.md` for authored domain contracts, capabilities,
  choice sources, published views, writes, and domain actions.
- `docs/write_adapter_protocol.md` for portable write ownership, versioned
  capability preflight, and the adapter support matrix.
- `docs/domain_schema_v1.md` for the normalized domain schema contract.
- `docs/expression_dsl.md` for dynamic expression helpers, macros, and sigils.
- `docs/strict_mode.md` for sealed domains and governed query construction.

## Related Repos

- `selecto_components`
- `selecto_mix`
- `selecto_updato`
- `selecto_postgis`
- `selecto_test`
