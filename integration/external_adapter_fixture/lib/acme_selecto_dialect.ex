defmodule AcmeSelectoDialect do
  @behaviour Selecto.DB.Dialect

  @impl true
  def query_strategy(:recursive_cte, _context), do: :plain
  def query_strategy(_strategy, _context), do: :default

  @impl true
  def aggregate_function_name(:stddev, _context), do: "ACME_STDDEV"
  def aggregate_function_name(:variance, _context), do: "ACME_VARIANCE"

  @impl true
  def render_scalar_predicate(%Selecto.Dialect.Query.Predicate{} = fragment, _context) do
    {:ok, {["TRUTH(", fragment.expression, ")"], fragment.params}}
  end

  @impl true
  def render_filtered_aggregate(%Selecto.Dialect.Query.Aggregate{} = fragment, _context) do
    {:ok, [fragment.function, "(", fragment.arguments, ") WHERE ", fragment.filter]}
  end

  @impl true
  def render_collection_query(%Selecto.Dialect.Query.Collection{}, _context),
    do: {:error, :external_collection_refusal}
end
