# Native builder composition in 0.6.0

This alpha implements native builder contract 1.0.0 (certification spec 4.0.0).
`select/2` no longer deduplicates. The former `Enum.uniq` served convenience,
not SQL validity or governance: repeated fields are valid positional SQL output.
Existing explicit alias validation and set-query mutation restrictions remain.

```elixir
base = Selecto.select(query, ["id"])
composed = base |> Selecto.select(["id", "name"]) # id, id, name
fresh = Selecto.replace_select(composed, ["name"]) # name
cleared = Selecto.clear_select(fresh) # configured initial selection
filtered = query |> Selecto.filter({"id", {:gte, 1}}) |> Selecto.filter({"id", {:lte, 5}})
reset = filtered |> Selecto.replace_filter({"id", 3}) |> Selecto.clear_filter()
```

Empty append leaves the query unchanged. Empty replacement clears its clause.
Filters AND in order, retaining repetitions; OR remains explicit. Replace/clear
operate on regular caller filters on the current root (the target after retarget),
retaining the origin context, required filters, host-recorded scope and trusted
tenant. Specialized JSON/array filter APIs retain their separate state.

Use explicit replacement for complete-intent lowerers, field-choice queries,
count projections and related/member derivations. If a consumer intentionally
wants idempotent projection composition, deduplicate its authored selector list
before passing it, rather than relying on implicit SDK deduplication. Persistent
builder branches retain their values.

Central protocol 1 certificates observe complete intents and cannot prove
native chaining. Native regressions cover chaining, SQL/parameters and governed
execution in addition to unchanged wire observations. No Hex release is performed
by this source migration.
