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
    all_of([:active_products, :priced_at_least])
  end

  defsegment visible_products do
    any_of([:active_products, :preorder_products])
  end

  defprojection product_identity do
    fields([:id, :name])
  end

  defprojection product_pricing do
    fields([:price])
  end

  defprojection product_card do
    include_projections([:product_identity, :product_pricing])

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

## Compose segments

An included segment is an implicit AND. Use the named combinators when the
boolean relationship should be explicit:

```elixir
defsegment purchasable_products do
  all_of([:visible_products, :in_stock_products])
end

defsegment visible_products do
  any_of do
    segment(:active_products)
    segment(:preorder_products)
  end
end

defsegment non_archived_products do
  not_segment(:archived_products)
end

defsegment neither_hidden_nor_archived do
  nor_segments([:hidden_products, :archived_products])
end

defsegment retail_xor_wholesale do
  xor_segments([:retail_products, :wholesale_products])
end
```

`and_segments/1` and `or_segments/1` are explicit aliases for `all_of/1` and
`any_of/1`. `none_of/1` aliases `nor_segments/1`, while `one_of/1` aliases the
binary `xor_segments/1`. XOR requires exactly two segments.

The library stores the operator and segment references as data. At application
time NOR and XOR lower to the existing portable AND/OR/NOT filter AST, so they
do not require adapter-specific SQL operators. Boolean combinators may nest by
referencing another composed segment.

## Combine projections

A projection can include one or more named projections:

```elixir
defprojection product_card do
  include_projection(:product_identity)
  include_projections([:product_pricing, :product_availability])
end
```

Fields are merged in stable composition order and deduplicated. Association
branches with the same name are merged recursively, so separate projections
can contribute different fields or nested associations to the same result
branch.

Callers can also combine definitions without declaring a wrapper projection:

```elixir
query = Selecto.apply_projection(query, [:product_identity, :product_pricing])
```

Projection references are cycle-checked before query application.

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

Required filters stay outside boolean segment expressions. For example, an OR
between two optional segments cannot accidentally turn a required tenant or
visibility predicate into one branch of that OR.

The domain contract validates definition structure, references, segment and
ordering fields, and nested projection paths. SQL generation performs the
normal query validation again after definitions have been applied.

Keep authorization decisions in required domain policy or the surrounding
application boundary. A query-library segment is a reusable filter, not an
authorization mechanism by itself.
