defmodule Selecto.Query.Plan do
  @moduledoc """
  Versioned query intent over an explicitly approved document ShapeRelease.

  Query input uses string field identifiers, never native paths or operators.
  Tenant values come exclusively from the host's `:trusted_context`. The first
  version is strict: unsupported operations have no client-side fallback.
  """
  alias Selecto.Document.{Missing, Path, ShapeRelease}
  alias Selecto.Error

  @derive [Jason.Encoder, {Inspect, only: [:version, :required_capabilities, :bounds]}]
  defstruct version: 1,
            release: nil,
            source: nil,
            relation: nil,
            projection: [],
            aggregates: [],
            predicates: nil,
            ordering: [],
            page: %{},
            bounds: %{},
            tenant: nil,
            cursor_token: nil,
            required_capabilities: [],
            metadata: %{},
            request: %{}

  @type t :: %__MODULE__{}
  @operators ~w(eq ne gt gte lt lte in exists missing is_null is_not_null)
  @unary ~w(exists missing is_null is_not_null)
  @array_predicates ~w(contains contains_any contains_all)
  @bounds %{
    "max_rows" => 100,
    "max_bytes" => 1_048_576,
    "timeout_ms" => 5000,
    "max_predicates" => 32
  }
  @hard_bounds %{
    "max_rows" => 1000,
    "max_bytes" => 16_777_216,
    "timeout_ms" => 30_000,
    "max_predicates" => 128
  }
  @query_keys ~w(select where order_by limit cursor bounds access_pattern parent_identity aggregate)
  @aggregate_ops ~w(count sum min max)
  @portable_integer 9_007_199_254_740_991

  @doc "Build validated intent; the host supplies trusted tenant scope and cursor signing keys."
  def new(release, relation_id, query \\ %{}, opts \\ []) do
    with :ok <- approved(release),
         :ok <- query_input(query),
         {:ok, relation} <- ShapeRelease.relation(release, relation_id),
         {:ok, relation} <- parent_scope(relation, query),
         {:ok, tenant} <- tenant(opts),
         {:ok, aggregates} <- aggregates(release, relation_id, relation, query),
         {:ok, bounds} <- bounds(Map.get(query, "bounds", %{}), aggregates),
         :ok <- input_tree_bound(Map.get(query, "where"), bounds["max_predicates"]),
         {:ok, projection} <- query_projection(release, relation_id, query, relation, aggregates),
         {:ok, predicates} <- predicate(release, relation_id, Map.get(query, "where"), 0),
         :ok <- predicate_bound(predicates, bounds),
         {:ok, ordering} <- query_ordering(release, relation_id, relation, query, aggregates),
         {:ok, page} <- query_page(query, bounds, aggregates),
         {:ok, access} <- access_pattern(relation, query) do
      plan = %__MODULE__{
        release: release,
        source: release["source"],
        relation: Map.put(relation, "id", relation_id),
        projection: projection,
        aggregates: aggregates,
        predicates: predicates,
        ordering: ordering,
        page: page,
        bounds: bounds,
        tenant: tenant,
        request: Map.delete(query, "cursor"),
        metadata: %{
          "access_pattern" => access,
          "mode" => "strict",
          "residual" => [],
          "scope_digest" => :crypto.hash(:sha256, tenant) |> Base.encode16(case: :lower)
        }
      }

      plan = %{plan | required_capabilities: requirements(plan)}
      apply_cursor(plan, Map.get(query, "cursor"), opts)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _} -> error("Invalid document query contract")
    end
  end

  @doc "Revalidate derived intent before an adapter receives it."
  def validate(plan, opts \\ [])

  def validate(%__MODULE__{version: 1} = plan, opts) do
    with {:ok, rebuilt} <-
           new(plan.release, plan.relation["id"], plan.request,
             trusted_context: %{tenant_id: plan.tenant}
           ),
         true <- equivalent?(plan, rebuilt),
         :ok <- verified_cursor(plan, opts) do
      :ok
    else
      _ -> error("Document query plan was modified or is invalid")
    end
  rescue
    _ -> error("Invalid document query plan")
  end

  def validate(_, _), do: error("Unsupported document query plan version")

  @doc false
  def cursor_values(_plan, nil), do: :ok

  def cursor_values(%{aggregates: [_ | _]}, _),
    do: error("Aggregate queries do not support cursors")

  def cursor_values(plan, values) when is_list(values) do
    valid =
      length(values) == length(plan.ordering) and
        Enum.all?(Enum.zip(plan.ordering, values), fn {order, value} ->
          value != nil and typed?(order["field"]["type"], value)
        end)

    if valid, do: :ok, else: error("Invalid typed cursor values")
  end

  def cursor_values(_, _), do: error("Invalid typed cursor values")

  @doc false
  def typed?("string", v), do: is_binary(v) and byte_size(v) <= 16_384

  def typed?("integer", v),
    do: is_integer(v) and v >= -9_007_199_254_740_991 and v <= 9_007_199_254_740_991

  def typed?("number", v), do: (is_float(v) or is_integer(v)) and abs(v) <= 9_007_199_254_740_991
  def typed?("float", v), do: is_float(v)
  def typed?("boolean", v), do: is_boolean(v)
  def typed?(_, _), do: false

  @doc "Largest absolute integer input supported by an aggregate's exact arithmetic contract."
  def aggregate_input_limit(plan, %{"op" => "sum"}),
    do: div(@portable_integer, plan.bounds["max_input_rows"])

  def aggregate_input_limit(_plan, %{"op" => op}) when op in ~w(min max),
    do: @portable_integer

  @doc "Validate a numeric aggregate input after independent ShapeRelease validation."
  def aggregate_input?(_plan, %{"op" => "count"}, _value), do: true
  def aggregate_input?(_plan, _aggregate, %Missing{}), do: true
  def aggregate_input?(_plan, _aggregate, nil), do: true

  def aggregate_input?(plan, aggregate, value),
    do: is_integer(value) and abs(value) <= aggregate_input_limit(plan, aggregate)

  defp approved(release) do
    case ShapeRelease.validate(release, require_approved: true) do
      :ok -> :ok
      _ -> error("An approved, unmodified ShapeRelease is required")
    end
  end

  defp query_input(query) when is_map(query) and not is_struct(query) do
    if Enum.all?(Map.keys(query), &(&1 in @query_keys)),
      do: :ok,
      else: error("Unknown document query option")
  end

  defp query_input(_), do: error("Query must be a string-keyed object")

  defp tenant(opts) do
    value =
      case Keyword.get(opts, :trusted_context) do
        %{tenant_id: value} -> value
        %{"tenant_id" => value} -> value
        _ -> nil
      end

    if is_binary(value) and byte_size(value) in 1..256,
      do: {:ok, value},
      else: error("Trusted tenant context is required")
  end

  defp bounds(overrides, aggregates) when is_map(overrides) and not is_struct(overrides) do
    defaults =
      if aggregates == [], do: @bounds, else: Map.put(@bounds, "max_input_rows", 1000)

    maxima =
      if aggregates == [], do: @hard_bounds, else: Map.put(@hard_bounds, "max_input_rows", 10_000)

    valid =
      Enum.all?(overrides, fn {key, value} ->
        Map.has_key?(maxima, key) and is_integer(value) and value > 0 and
          value <= maxima[key]
      end)

    if valid, do: {:ok, Map.merge(defaults, overrides)}, else: error("Invalid execution bounds")
  end

  defp bounds(_, _), do: error("Invalid execution bounds")

  defp aggregates(release, relation_id, relation, query) do
    if Map.has_key?(query, "aggregate") do
      input = query["aggregate"]

      with true <- relation["kind"] == "root",
           false <- Enum.any?(~w(select order_by limit cursor), &Map.has_key?(query, &1)),
           true <- is_list(input) and length(input) in 1..16,
           {:ok, values} <- map_ok(input, &aggregate(release, relation_id, relation, &1)),
           aliases = Enum.map(values, & &1["id"]),
           true <- Enum.uniq(aliases) == aliases do
        {:ok, values}
      else
        _ -> error("Invalid aggregate query or incompatible row-query options")
      end
    else
      {:ok, []}
    end
  end

  defp aggregate(release, relation_id, relation, %{"op" => op, "as" => id} = input)
       when op in @aggregate_ops do
    expected = if op == "count", do: ~w(as op), else: ~w(as field op)

    with true <- Enum.sort(Map.keys(input)) == expected and Path.safe_key?(id),
         {:ok, field} <- aggregate_field(release, relation_id, relation, input) do
      {:ok,
       %{
         "op" => op,
         "id" => id,
         "field" => field,
         "type" => "integer",
         "nullable" => op != "count"
       }}
    else
      _ ->
        error("Aggregate must name an explicitly granted operation and published integer field")
    end
  end

  defp aggregate(_, _, _, _), do: error("Invalid aggregate operation")

  defp aggregate_field(_release, _id, relation, %{"op" => "count"}) do
    if "count" in Map.get(relation, "aggregate_ops", []),
      do: {:ok, nil},
      else: error("Relation does not grant count")
  end

  defp aggregate_field(release, relation_id, _relation, %{"op" => op, "field" => id}) do
    with {:ok, field} <- field(release, relation_id, id),
         true <- field["type"] == "integer" and op in Map.get(field, "aggregate_ops", []) do
      {:ok, field}
    else
      _ -> error("Field does not grant the typed aggregate")
    end
  end

  defp query_projection(release, id, query, relation, []),
    do: projection(release, id, query, relation)

  defp query_projection(_release, _id, _query, _relation, aggregates),
    do: {:ok, Enum.map(aggregates, &Map.take(&1, ~w(id type nullable)))}

  defp query_ordering(release, id, relation, query, []),
    do: ordering(release, id, relation, query)

  defp query_ordering(_release, _id, _relation, _query, _aggregates), do: {:ok, []}
  defp query_page(query, bounds, []), do: page(query, bounds)
  defp query_page(_query, _bounds, _aggregates), do: {:ok, %{"limit" => 1, "after" => nil}}

  defp projection(release, id, query, relation) do
    defaults =
      case relation["fields"] do
        fields when is_list(fields) -> fields
        fields when is_map(fields) -> fields |> Map.keys() |> Enum.sort()
      end

    fields = Map.get(query, "select", defaults)

    if is_list(fields) and length(fields) in 1..128 and Enum.uniq(fields) == fields do
      map_ok(fields, &field(release, id, &1))
    else
      error("Projection must contain unique published field ids")
    end
  end

  defp field(release, relation, id) when is_binary(id) do
    case ShapeRelease.field(release, relation, id) do
      {:ok, definition} -> {:ok, Map.put(definition, "id", id)}
      _ -> error("Unknown or unpublished field")
    end
  end

  defp field(_, _, _), do: error("Field ids must be strings")

  defp predicate(_, _, nil, _), do: {:ok, nil}
  defp predicate(_, _, _, depth) when depth > 8, do: error("Predicate nesting exceeds bound")

  defp predicate(release, relation, %{"op" => op, "args" => args} = input, depth)
       when op in ["and", "or"] and is_list(args) do
    if Enum.sort(Map.keys(input)) == ["args", "op"] and length(args) in 1..128 do
      with {:ok, children} <- map_ok(args, &predicate(release, relation, &1, depth + 1)),
           true <- Enum.all?(children, &(!is_nil(&1))) do
        {:ok, %{"op" => op, "args" => children}}
      else
        _ -> error("Invalid boolean predicate")
      end
    else
      error("Invalid boolean predicate")
    end
  end

  defp predicate(release, relation, %{"op" => op, "field" => id} = input, _)
       when op in @array_predicates do
    with true <- Enum.sort(Map.keys(input)) == ~w(field op value),
         {:ok, field} <- field(release, relation, id),
         %{"predicate_ops" => grants, "element_type" => type} <- field["scalar_array"],
         true <- op in grants,
         true <- scalar_array_operand?(op, type, input["value"]) do
      {:ok, Map.put(input, "field", field)}
    else
      _ -> error("Scalar array predicate requires an explicit typed grant and bounded operand")
    end
  end

  defp predicate(release, relation, %{"op" => op, "field" => id} = input, _)
       when op in @operators do
    expected = if op in @unary, do: ~w(field op), else: ~w(field op value)

    with true <- Enum.sort(Map.keys(input)) == expected,
         {:ok, field} <- field(release, relation, id),
         true <- field["filterable"] == true,
         :ok <- predicate_value(op, field["type"], input["value"]) do
      {:ok, Map.put(input, "field", field)}
    else
      _ -> error("Unsupported predicate, field permission, or operand type")
    end
  end

  defp predicate(_, _, _, _), do: error("Invalid portable predicate")

  defp scalar_array_operand?("contains", type, value),
    do: ShapeRelease.scalar_array_element?(type, value)

  defp scalar_array_operand?(op, type, values)
       when op in ~w(contains_any contains_all) and is_list(values) and length(values) <= 100,
       do: Enum.all?(values, &ShapeRelease.scalar_array_element?(type, &1))

  defp scalar_array_operand?(_, _, _), do: false

  defp predicate_value(op, _, _) when op in @unary, do: :ok

  defp predicate_value("in", type, values) when is_list(values) and length(values) <= 100 do
    if Enum.all?(values, &typed?(type, &1)), do: :ok, else: error("Invalid IN values")
  end

  defp predicate_value(op, type, value) when op in ~w(eq ne gt gte lt lte) do
    if typed?(type, value), do: :ok, else: error("Invalid comparison value")
  end

  defp predicate_value(_, _, _), do: error("Invalid comparison value")

  defp predicate_bound(predicate, bounds) do
    if predicate_count(predicate) <= bounds["max_predicates"],
      do: :ok,
      else: error("Predicate count exceeds bound")
  end

  defp predicate_count(nil), do: 0
  defp predicate_count(%{"args" => args}), do: 1 + Enum.sum(Enum.map(args, &predicate_count/1))
  defp predicate_count(_), do: 1

  defp input_tree_bound(input, maximum) do
    case count_input([input], maximum) do
      :ok -> :ok
      _ -> error("Predicate count exceeds bound")
    end
  end

  defp count_input([], _), do: :ok
  defp count_input([nil | rest], remaining), do: count_input(rest, remaining)
  defp count_input(_, remaining) when remaining <= 0, do: :error

  defp count_input([%{"args" => args} | rest], remaining) when is_list(args) do
    if length(args) <= remaining, do: count_input(args ++ rest, remaining - 1), else: :error
  end

  defp count_input([_ | rest], remaining), do: count_input(rest, remaining - 1)

  defp ordering(release, id, relation, query) do
    with {:ok, identity} <- identity_field(release, id, relation),
         orders when is_list(orders) <- Map.get(query, "order_by", []),
         true <- length(orders) <= 4,
         {:ok, fields} <- map_ok(orders, &order(release, id, &1)) do
      fields =
        if Enum.any?(fields, &(&1["field"]["id"] == identity["id"])),
          do: fields,
          else: fields ++ [%{"field" => identity, "direction" => "asc"}]

      ids = Enum.map(fields, & &1["field"]["id"])
      if ids == Enum.uniq(ids), do: {:ok, fields}, else: error("Duplicate ordering field")
    else
      _ -> error("Stable ordering requires a published required non-null scalar identity")
    end
  end

  defp identity_field(release, id, relation) do
    with {:ok, fields} <- projection(release, id, %{}, relation),
         field when not is_nil(field) <-
           Enum.find(fields, &(&1["path"] == relation["identity_path"])),
         true <- orderable?(field) do
      {:ok, field}
    else
      _ -> error("No stable identity field")
    end
  end

  defp order(release, id, %{"field" => name, "direction" => direction} = input)
       when direction in ["asc", "desc"] and map_size(input) == 2 do
    with {:ok, field} <- field(release, id, name), true <- orderable?(field) do
      {:ok, %{"field" => field, "direction" => direction}}
    else
      _ -> error("Ordering requires a required non-null sortable scalar")
    end
  end

  defp order(_, _, _), do: error("Invalid ordering")

  defp orderable?(field),
    do:
      field["sortable"] == true and field["required"] == true and
        field["nullable"] == false and field["type"] in ~w(string integer number float boolean)

  defp page(query, bounds) do
    limit = Map.get(query, "limit", bounds["max_rows"])

    if is_integer(limit) and limit > 0 and limit <= bounds["max_rows"],
      do: {:ok, %{"limit" => limit, "after" => nil}},
      else: error("Invalid page limit")
  end

  defp parent_scope(%{"kind" => "array"} = relation, query) do
    case query["parent_identity"] do
      value when is_binary(value) and byte_size(value) in 1..256 ->
        {:ok, Map.put(relation, "parent_identity", value)}

      _ ->
        error("Array relations require a parent identity within trusted tenant scope")
    end
  end

  defp parent_scope(relation, query) do
    if Map.has_key?(query, "parent_identity"),
      do: error("Parent identity applies only to child relations"),
      else: {:ok, relation}
  end

  defp access_pattern(relation, query) do
    patterns = Map.get(relation, "access_patterns", %{})
    requested = Map.get(query, "access_pattern")

    case {patterns, requested} do
      {patterns, nil} when is_map(patterns) and map_size(patterns) == 1 ->
        [{id, pattern}] = Map.to_list(patterns)
        {:ok, Map.put(pattern, "id", id)}

      {patterns, id} when is_map(patterns) and is_binary(id) ->
        case Map.fetch(patterns, id) do
          {:ok, pattern} -> {:ok, Map.put(pattern, "id", id)}
          _ -> error("Unknown access pattern")
        end

      _ ->
        error("A declared access pattern is required")
    end
  end

  defp requirements(%{aggregates: [_ | _]} = plan) do
    nested =
      if Enum.any?(plan.aggregates, fn aggregate ->
           aggregate["field"] && length(aggregate["field"]["path"]) > 1
         end),
         do: ["document.nested"],
         else: []

    (["document.root"] ++
       Enum.map(plan.aggregates, &("query.aggregate." <> &1["op"])) ++
       nested ++ shape_requirements(plan.release) ++ predicate_requirements(plan.predicates))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp requirements(plan) do
    source =
      if plan.relation["kind"] == "array", do: "document.array_relation", else: "document.root"

    nested =
      if Enum.any?(plan.projection, &(length(&1["path"]) > 1)), do: ["document.nested"], else: []

    Enum.sort(
      Enum.uniq(
        [source, "query.ordering", "query.cursor", "query.limit"] ++
          nested ++ shape_requirements(plan.release) ++ predicate_requirements(plan.predicates)
      )
    )
  end

  defp shape_requirements(release) do
    Enum.map(ShapeRelease.features(release), &("document." <> &1))
  end

  defp predicate_requirements(nil), do: []

  defp predicate_requirements(%{"op" => op, "args" => args}),
    do: ["predicate." <> op | Enum.flat_map(args, &predicate_requirements/1)]

  defp predicate_requirements(%{"op" => op}), do: ["predicate." <> op]

  defp apply_cursor(plan, nil, _), do: {:ok, plan}

  defp apply_cursor(plan, token, opts) do
    with {:ok, values} <- Selecto.Query.Cursor.decode(plan, token, opts),
         :ok <- cursor_values(plan, values) do
      {:ok, %{plan | page: Map.put(plan.page, "after", values), cursor_token: token}}
    end
  end

  defp equivalent?(left, right) do
    left = %{left | page: Map.put(left.page, "after", nil), cursor_token: nil}
    left == right
  end

  defp verified_cursor(%{cursor_token: nil, page: %{"after" => nil}}, _), do: :ok

  defp verified_cursor(%{cursor_token: token} = plan, opts) when is_binary(token) do
    with {:ok, values} <- Selecto.Query.Cursor.decode(plan, token, opts),
         true <- values == plan.page["after"] do
      :ok
    else
      _ -> error("Cursor provenance does not match the query plan")
    end
  end

  defp verified_cursor(_, _), do: error("Unsigned cursor values are not executable")

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp error(message), do: {:error, Error.validation_error(message)}
end
