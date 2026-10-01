defmodule Selecto.Query do
  @moduledoc """
  Core query building operations for Selecto.

  This module contains the basic query building functions like select, filter,
  order_by, group_by, limit, and offset.
  """

  @doc """
  Add fields to the select list.

  For macro-free query composition, prefer importing `Selecto.Expr` and passing
  string field paths plus runtime helper constructors.

  ## Examples

      import Selecto.Expr

      selecto
      |> Selecto.Query.select(["name", "email", as(count(), "total")])
      |> Selecto.Query.select(avg("price"))
  """
  @spec select(Selecto.Types.t(), [Selecto.Types.selector()]) :: Selecto.Types.t()
  def select(selecto, fields) when is_list(fields) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :select)
    normalized_fields = Selecto.Expr.normalize(fields)
    Selecto.QueryValidator.validate_selectors!(selecto, normalized_fields)
    put_in(selecto.set.selected, Enum.uniq(selecto.set.selected ++ normalized_fields))
  end

  @spec select(Selecto.Types.t(), Selecto.Types.selector()) :: Selecto.Types.t()
  def select(selecto, field) do
    select(selecto, [field])
  end

  @doc """
  Add filters to the query.

  For macro-free query composition, prefer importing `Selecto.Expr` and using
  runtime filter constructors like `eq/2`, `gte/2`, and `compact_and/1`.

  ## Examples

      import Selecto.Expr

      selecto
      |> Selecto.Query.filter(eq("active", true))
      |> Selecto.Query.filter(compact_and([gte("age", 18), not_null("email")]))
  """
  @spec filter(Selecto.Types.t(), [Selecto.Types.filter()]) :: Selecto.Types.t()
  def filter(selecto, filters) when is_list(filters) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :filter)
    normalized_filters = Selecto.Expr.normalize(filters)
    Selecto.QueryValidator.validate_filters!(selecto, normalized_filters)

    required_filters = required_filters(selecto)

    # A retargeted query is rooted at its target, so its filters resolve and
    # apply there; its context filters live on the origin query.
    updated_set =
      selecto.set
      |> Map.put(
        :filtered,
        uniq_filters(selecto.set.filtered ++ normalized_filters ++ required_filters)
      )
      |> Map.put(:required_filters, required_filters)

    %{selecto | set: updated_set}
  end

  @spec filter(Selecto.Types.t(), Selecto.Types.filter()) :: Selecto.Types.t()
  def filter(selecto, filter) do
    filter(selecto, [filter])
  end

  @doc """
  Append filters to the retarget context.

  On a retargeted query the filters apply to the origin query, whose filters
  decide which target rows are reached. On any other query they are ordinary
  root filters.
  """
  @spec pre_retarget_filter(Selecto.Types.t(), [Selecto.Types.filter()]) :: Selecto.Types.t()
  def pre_retarget_filter(selecto, filters) when is_list(filters) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :pre_retarget_filter)

    case Selecto.Retarget.get_retarget_config(selecto) do
      %{origin: origin} = state ->
        put_in(selecto.set[:retarget_state], %{
          state
          | origin: pre_retarget_filter(origin, filters)
        })

      nil ->
        root_filter(selecto, filters)
    end
  end

  @spec pre_retarget_filter(Selecto.Types.t(), Selecto.Types.filter()) :: Selecto.Types.t()
  def pre_retarget_filter(selecto, filter) do
    pre_retarget_filter(selecto, [filter])
  end

  defp root_filter(selecto, filters) do
    normalized_filters = Selecto.Expr.normalize(filters)
    Selecto.QueryValidator.validate_filters!(selecto, normalized_filters)
    current_required = required_filters(selecto)

    put_in(
      selecto.set.filtered,
      uniq_filters(selecto.set.filtered ++ normalized_filters ++ current_required)
    )
  end

  @doc """
  Append filters to the target of a retargeted query.

  This is `filter/2` on a retargeted query. A query that has not been
  retargeted has no target to filter, so it is refused.
  """
  @spec post_retarget_filter(Selecto.Types.t(), [Selecto.Types.filter()]) :: Selecto.Types.t()
  def post_retarget_filter(selecto, filters) when is_list(filters) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :post_retarget_filter)

    unless Selecto.Retarget.has_retarget?(selecto) do
      raise ArgumentError, "post_retarget_filter requires a retargeted query; retarget first"
    end

    filter(selecto, filters)
  end

  @spec post_retarget_filter(Selecto.Types.t(), Selecto.Types.filter()) :: Selecto.Types.t()
  def post_retarget_filter(selecto, filter) do
    post_retarget_filter(selecto, [filter])
  end

  @doc """
  Return the root filters: on a retargeted query, the context filters of its
  origin query; otherwise `set.filtered`.
  """
  @spec pre_retarget_filters(Selecto.Types.t()) :: [Selecto.Types.filter()]
  def pre_retarget_filters(selecto) do
    case Selecto.Retarget.get_retarget_config(selecto) do
      %{origin: origin} -> Map.get(origin.set, :filtered, [])
      nil -> Map.get(selecto.set, :filtered, [])
    end
  end

  @doc """
  Return the filters applied to the target of a retargeted query, or `[]`
  for a query that has not been retargeted.
  """
  @spec post_retarget_filters(Selecto.Types.t()) :: [Selecto.Types.filter()]
  def post_retarget_filters(selecto) do
    if Selecto.Retarget.has_retarget?(selecto),
      do: Map.get(selecto.set, :filtered, []),
      else: []
  end

  @doc """
  Return required filters currently attached to the query.

  This includes domain-level required filters and query-level required filters
  added at runtime.
  """
  @spec required_filters(Selecto.Types.t()) :: [Selecto.Types.filter()]
  def required_filters(selecto) do
    domain_required =
      selecto
      |> Selecto.domain()
      |> Map.get(:required_filters, [])

    set_required =
      selecto
      |> Map.get(:set, %{})
      |> Map.get(:required_filters, [])

    uniq_filters(domain_required ++ set_required)
  end

  @doc """
  Return query filters across current buckets as a flat list.

  This is useful for integrations that need to copy filters between Selecto and
  other query/update builders.

  ## Options

  - `:include_post_retarget` - accepted for compatibility; a retargeted query
    keeps its target filters in `set.filtered`.

  A retargeted query is refused: its filters describe the target rows, and
  its context restriction is not a filter list, so they cannot scope writes
  or be copied to another query.
  """
  @spec query_filters(Selecto.Types.t(), keyword()) :: [Selecto.Types.filter()]
  def query_filters(selecto, opts \\ []) do
    if Selecto.Retarget.has_retarget?(selecto) do
      raise ArgumentError,
            "query filters of a retargeted query do not include its retarget context"
    end

    include_post_retarget = Keyword.get(opts, :include_post_retarget, true)

    validate_tenant = Keyword.get(opts, :validate_tenant, true)

    if validate_tenant do
      Selecto.Tenant.ensure_scope!(selecto, opts)
    end

    set_filters =
      case Map.get(selecto, :set) do
        %{} = set -> Map.get(set, :filtered, [])
        _ -> []
      end

    post_retarget_filters =
      if include_post_retarget do
        case Map.get(selecto, :set) do
          %{} = set ->
            Map.get(set, :post_retarget_filters, [])

          _ ->
            []
        end
      else
        []
      end

    [required_filters(selecto), set_filters, post_retarget_filters]
    |> Enum.flat_map(fn
      filters when is_list(filters) -> filters
      _ -> []
    end)
    |> uniq_filters()
  end

  defp uniq_filters(filters) do
    Enum.reduce(filters, [], fn filter, acc ->
      if filter in acc do
        acc
      else
        acc ++ [filter]
      end
    end)
  end

  @doc """
  Add to the Order By clause.

  ## Examples

      import Selecto.Expr

      selecto
      |> Selecto.Query.order_by([asc("created_at"), desc("name")])
  """
  @spec order_by(Selecto.Types.t(), [Selecto.Types.order_spec()]) :: Selecto.Types.t()
  def order_by(selecto, orders) when is_list(orders) do
    normalized_orders = Selecto.Expr.normalize(orders)
    Selecto.QueryValidator.validate_order_specs!(selecto, normalized_orders)
    put_in(selecto.set.order_by, selecto.set.order_by ++ normalized_orders)
  end

  @spec order_by(Selecto.Types.t(), Selecto.Types.order_spec()) :: Selecto.Types.t()
  def order_by(selecto, orders) do
    normalized_order = Selecto.Expr.normalize(orders)
    Selecto.QueryValidator.validate_order_specs!(selecto, normalized_order)
    put_in(selecto.set.order_by, selecto.set.order_by ++ [normalized_order])
  end

  @doc """
  Add to the Group By clause.

  ## Examples

      import Selecto.Expr

      selecto
      |> Selecto.Query.group_by(["category", "region"])
      |> Selecto.Query.group_by(rollup(["status"]))
  """
  @spec group_by(Selecto.Types.t(), [Selecto.Types.field_name()]) :: Selecto.Types.t()
  def group_by(selecto, groups) when is_list(groups) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :group_by)
    normalized_groups = Selecto.Expr.normalize(groups)
    Selecto.QueryValidator.validate_group_specs!(selecto, normalized_groups)
    put_in(selecto.set.group_by, selecto.set.group_by ++ normalized_groups)
  end

  @spec group_by(Selecto.Types.t(), Selecto.Types.field_name()) :: Selecto.Types.t()
  def group_by(selecto, groups) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :group_by)
    normalized_group = Selecto.Expr.normalize(groups)
    Selecto.QueryValidator.validate_group_specs!(selecto, normalized_group)
    put_in(selecto.set.group_by, selecto.set.group_by ++ [normalized_group])
  end

  @doc """
  Limit the number of rows returned by the query.

  ## Examples

      # Limit to 10 rows
      selecto |> Selecto.Query.limit(10)

      # Limit with offset for pagination
      selecto |> Selecto.Query.limit(10) |> Selecto.Query.offset(20)
  """
  @spec limit(Selecto.Types.t(), non_neg_integer()) :: Selecto.Types.t()
  def limit(selecto, limit_value) when is_integer(limit_value) and limit_value >= 0 do
    put_in(selecto.set[:limit], limit_value)
  end

  @doc """
  Set the offset for the query results.

  ## Examples

      # Skip first 20 rows
      selecto |> Selecto.Query.offset(20)

      # Pagination: page 3 with 10 items per page
      selecto |> Selecto.Query.limit(10) |> Selecto.Query.offset(20)
  """
  @spec offset(Selecto.Types.t(), non_neg_integer()) :: Selecto.Types.t()
  def offset(selecto, offset_value) when is_integer(offset_value) and offset_value >= 0 do
    put_in(selecto.set[:offset], offset_value)
  end

  @doc """
  Remove root LIMIT and OFFSET while retaining the query's authorization,
  filters, selections, and ordering.

  This is intended for a separately executed exact count of the same filtered
  membership. It does not remove per-parent collection limits or mutate the
  original query.
  """
  @spec unpaginate(Selecto.Types.t()) :: Selecto.Types.t()
  def unpaginate(selecto) do
    %{selecto | set: Map.drop(selecto.set, [:limit, :offset])}
  end

  @doc """
  Build a root-row count input from a detail query without weakening its filters.

  The returned query selects only the verified root field and removes selections
  that cannot affect root membership, including correlated subselects, ordering,
  and root pagination. Execute it with `Selecto.execute_count_with_metadata/2`.
  Grouped queries require their own count semantics and are rejected.
  """
  @spec root_count_query(Selecto.Types.t(), Selecto.Types.field_name()) :: Selecto.Types.t()
  def root_count_query(selecto, field) when is_binary(field) or is_atom(field) do
    root_membership_query(selecto, field, :filtered)
  end

  @doc """
  Keep one row per authorized root while discarding display projections.

  `:page` retains root ordering and pagination; `:filtered` removes both.
  The result can receive a correlated per-root projection before a database-side
  fold. Grouped queries cannot define this root membership and are rejected.
  """
  @spec root_membership_query(Selecto.Types.t(), Selecto.Types.field_name(), :page | :filtered) ::
          Selecto.Types.t()
  def root_membership_query(selecto, field, scope)
      when (is_binary(field) or is_atom(field)) and scope in [:page, :filtered] do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :select)

    if Map.get(selecto.set, :group_by, []) != [] do
      raise ArgumentError, "root count requires an ungrouped detail query"
    end

    selected = Selecto.Expr.normalize([field])
    Selecto.QueryValidator.validate_selectors!(selecto, selected)

    set =
      selecto.set
      |> Map.put(:selected, selected)
      |> Map.put(:subselected, [])

    set =
      if scope == :filtered do
        set |> Map.put(:order_by, []) |> Map.drop([:limit, :offset])
      else
        set
      end

    %{selecto | set: set}
  end

  @doc """
  Generate SQL without executing - useful for debugging and caching.

  ## Examples

      {sql, params} = Selecto.Query.to_sql(selecto)
      IO.puts(sql)

  ## Options

  - `:pretty` - format SQL for readability
  - `:highlight` - apply highlighting (`:ansi` or `:markdown`)
  - `:indent` - indentation string used by pretty formatter
  - `:validate_tenant` - enforce required tenant scope (defaults to `true`)
  """
  @spec to_sql(Selecto.Types.t(), keyword()) :: {String.t(), list()}
  def to_sql(selecto, opts \\ []) do
    # gen_sql/2 enforces the tenant scope unless `validate_tenant: false`.
    {query, _aliases, params} = Selecto.gen_sql(selecto, opts)

    query =
      if Keyword.get(opts, :pretty, false) do
        Selecto.SQL.Formatter.format(query, opts)
      else
        query
      end

    query =
      case Keyword.get(opts, :highlight) do
        nil -> query
        false -> query
        style -> Selecto.SQL.Formatter.highlight(query, style)
      end

    {query, params}
  end
end
