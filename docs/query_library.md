# Portable Query Libraries

Selecto domains can carry a portable library of named query definitions. The
library keeps recurring application query intent as inspectable data instead
of hiding it in context-specific callbacks.

Four definition types cover the usual context concerns:

- a **segment** constrains which rows belong to a named subset;
- a **projection** defines the returned shape, including nested associations;
- an **ordering** defines deterministic result order;
- a **view** composes segments, one projection, and one ordering.

## Author a library

Use `Selecto.QueryLibrary.DSL` in a context or a dedicated query module:

```elixir
defmodule MyApp.Catalog do
  use Selecto.QueryLibrary.DSL

  defsegment active_products do
    where(:status, eq: "active")
  end

  defsegment priced_at_least do
    param(:minimum, :decimal)
    where(:price, gte: param(:minimum))
  end

  defseg active_products_at_price do
    include_segment(:active_products)
    include_segment(:priced_at_least)
  end

  defprojection product_card do
    fields([:id, :name, :price])

    association(:category) do
      fields([:id, :name])
    end
  end

  defordering product_cards_by_name do
    order_by(:name, :asc)
    order_by(:id, :asc)
  end

  defview active_catalog do
    segment(:active_products_at_price)
    projection(:product_card)
    ordering(:product_cards_by_name)
  end
end
```

Attach the generated data to the domain:

```elixir
def domain do
  %{
    name: "Catalog",
    source: source(),
    query_library: query_library()
  }
end
```

The library remains a plain map and is retained by domain normalization and
query-contract projection. That makes the same definitions available to
inspection, generators, and non-Elixir runtimes without evaluating module
callbacks.

## Apply definitions

Apply a definition after configuring the domain:

```elixir
query =
  domain()
  |> Selecto.configure(connection)
  |> Selecto.apply_segment(:active_products_at_price, minimum: "19.95")
  |> Selecto.apply_projection(:product_card)
  |> Selecto.apply_ordering(:product_cards_by_name)

view_query =
  domain()
  |> Selecto.configure(connection)
  |> Selecto.apply_view(:active_catalog, minimum: Decimal.new("19.95"))
```

`Selecto.query_library/1` exposes the normalized registry and
`Selecto.applied_query_library/1` reports which names have been applied to a
query.

Segment parameters accept maps or keyword lists. Built-in portable types are
`string`, `integer`, `float`, `decimal`, `boolean`, `date`, `datetime`,
`naive_datetime`, `utc_datetime`, and `uuid`. Values for these types are
checked or cast before SQL generation. Adapter- or application-specific type
names are retained and passed through.

## Governance boundaries

Named definitions add application intent; they do not weaken domain policy.
Required filters, required selections, and required ordering remain in force.
A segment therefore cannot remove tenant or visibility scope, and a projection
cannot omit fields declared as required by the domain.

The domain contract validates definition structure, references, segment and
ordering fields, and nested projection paths. SQL generation performs the
normal query validation again after definitions have been applied.

Keep authorization decisions in required domain policy or the surrounding
application boundary. A query-library segment is a reusable filter, not an
authorization mechanism by itself.
