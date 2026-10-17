defmodule Selecto.Retarget do
  @moduledoc """
  Retarget moves a query's row grain from the domain root to the relation at
  a join path.

  The query's filters at the time of the retarget become its context. The
  retargeted query returns the distinct target rows that the original query's
  joined read reaches under that context and its required filters. A filter
  on a join of the path therefore constrains that join's rows: filtering
  attendees by name and retargeting to their orders returns those attendees'
  orders.

  `retarget/3` returns a query configured on a domain rooted at the target
  relation. Selections, filters, grouping, ordering, pagination, and
  subselects added afterwards resolve against the target and its own joins.
  The original query is kept as the context; `reset_retarget/1` returns it.

      selecto
      |> Selecto.filter({"region", "west"})
      |> Selecto.retarget("attendees.orders")
      |> Selecto.filter({"total", {:gt, 10}})
      |> Selecto.select(["id", "total", "product.name"])

  ## Target paths

  A target is a join id (`:orders`) or a dotted join path from the root
  (`"attendees.orders"`) that names the domain's join tree. Each hop keeps
  its declared join semantics. The target must be a table-backed relation
  whose primary key is one of its fields.

  ## Domain governance

  A domain's `retarget` section may declare `targets`, an allow-list keyed by
  join path with optional `label` and `default_selected`, and a
  `default_target`. When `targets` is declared, only those paths can be
  retargeted to.

  ## Tenant scope

  The context keeps the original required filters, including an applied
  tenant scope. When the target relation declares `tenant_field`, the root's
  tenant conditions are re-expressed on it and required of the target too. A
  scoped root whose tenant condition cannot be carried to a tenant-scoped
  target fails closed with `:missing_tenant_scope`.

  The `where` policy of the association that reaches the target is
  re-applied to the target rows, so a key that repeats across the policy's
  scopes never brings back rows the join excludes.

  ## Options

    * `:strategy` - `:in` (default) or `:exists`. Both return the same rows.
  """

  alias Selecto.Types

  defmodule Error do
    @moduledoc "Raised when a retarget is not allowed or cannot be planned."
    defexception [:code, :message, details: %{}]
  end

  @strategies [:in, :exists]
  @context_alias "selecto_retarget_context"

  @doc """
  Retarget `selecto` to the relation at `target`.

  See the module documentation for semantics and options.
  """
  @spec retarget(Types.t(), atom() | String.t(), keyword()) :: Types.t()
  def retarget(%Selecto{} = selecto, target, opts \\ []) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :retarget)
    strategy = strategy!(opts)

    if has_retarget?(selecto) do
      fail!(:invalid_query, "a query can be retargeted only once")
    end

    ensure_root_sources_absent!(selecto)

    plan = plan!(selecto, target)

    retargeted =
      plan.domain
      |> Selecto.configure(selecto.runtime, configure_options(selecto))
      |> carry_tenant_scope!(selecto, plan)

    put_in(retargeted.set[:retarget_state], %{
      path: plan.path,
      join: plan.join,
      target_schema: plan.target_schema,
      primary_key: plan.primary_key,
      scope_keys: plan.scope_keys,
      policy: plan.policy,
      strategy: strategy,
      origin: selecto
    })
  end

  @doc "Whether `selecto` is a retargeted query."
  @spec has_retarget?(Types.t()) :: boolean()
  def has_retarget?(%{set: set}) when is_map(set), do: Map.has_key?(set, :retarget_state)
  def has_retarget?(_selecto), do: false

  @doc """
  The retarget of a retargeted query: its `path`, target `join` id,
  `target_schema`, target `primary_key`, `strategy`, and the `origin` query
  whose filters are the context. `nil` for an ordinary query.
  """
  @spec get_retarget_config(Types.t()) :: map() | nil
  def get_retarget_config(%{set: set}) when is_map(set), do: Map.get(set, :retarget_state)
  def get_retarget_config(_selecto), do: nil

  @doc "Return the query a retargeted query was retargeted from."
  @spec reset_retarget(Types.t()) :: Types.t()
  def reset_retarget(selecto) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :reset_retarget)

    case get_retarget_config(selecto) do
      %{origin: origin} -> origin
      nil -> selecto
    end
  end

  @doc """
  The context query of a retargeted query: the origin with its filters,
  selecting the target's primary key through the join path.
  """
  @spec context(Types.t()) :: Types.t()
  def context(selecto) do
    %{origin: origin, join: join, primary_key: primary_key} =
      config = get_retarget_config(selecto)

    # A target confined by scope keys repeats its primary key across scopes,
    # so the context also selects the scope keys that identify the row.
    selected = Enum.map([primary_key | scope_keys(config)], &"#{join}.#{&1}")

    set =
      origin.set
      |> Map.merge(%{selected: selected, order_by: [], group_by: []})
      |> Map.drop([
        :limit,
        :offset,
        :subselected,
        :window_functions,
        :json_selects,
        :json_order_by,
        :array_operations
      ])

    %{origin | set: set}
  end

  @doc false
  # The WHERE condition that restricts a retargeted query to the target rows
  # its context reaches.
  @spec context_filter(Types.t()) :: Types.filter() | nil
  def context_filter(selecto) do
    case get_retarget_config(selecto) do
      nil ->
        nil

      config ->
        case policy_filter(selecto, config) do
          nil -> key_context_filter(selecto, config)
          policy -> {:and, [key_context_filter(selecto, config), policy]}
        end
    end
  end

  # The association `where` policy of the last hop confines the target rows
  # the join reaches (ADDENDUM 8). The context correlates on the target's key
  # (and scope keys) alone, and a key can repeat across the policy's scopes,
  # so the policy is re-applied to the outer target rows: with host
  # exactness on MySQL and MariaDB by each column's declared type, plainly
  # elsewhere (Selecto.Builder.Association.policy_conditions/4).
  defp policy_filter(selecto, config) do
    case Map.get(config, :policy) do
      policy when is_map(policy) and map_size(policy) > 0 ->
        conditions =
          Selecto.Builder.Association.policy_conditions(
            selecto,
            "selecto_root",
            policy,
            Map.get(selecto.domain, :source)
          )

        {:raw_sql_filter, ["(", Enum.intersperse(conditions, " AND "), ")"]}

      _ ->
        nil
    end
  end

  defp key_context_filter(selecto, config) do
    case config do
      %{scope_keys: [_ | _]} = config ->
        scoped_context_filter(selecto, config)

      %{strategy: :in, primary_key: primary_key} ->
        {to_string(primary_key), {:subquery, :in, context(selecto)}}

      %{strategy: :exists, primary_key: primary_key} ->
        # The context selects only the target key, so its one column carries
        # the key's name; correlate on it outside the derived table.
        {sql, params} = Selecto.to_sql(context(selecto))
        quote_id = &Selecto.Builder.Sql.Helpers.quote_identifier(selecto, &1)
        key = quote_id.(to_string(primary_key))

        correlated =
          "select 1 from (#{sql}) #{quote_id.(@context_alias)} where " <>
            "#{quote_id.(@context_alias)}.#{key} = selecto_root.#{key}"

        {:exists, correlated, params}
    end
  end

  defp scope_keys(config), do: Map.get(config, :scope_keys) || []

  # A target reached through scope keys (lesson 41: authored scope keys or a
  # tenant pair confine the association, the target declares no tenant_field)
  # is identified by its primary key AND those keys: the same id can belong to
  # several scopes. The outer query matches the whole tuple, at the context's
  # last hop; the context's own joins already pair every earlier hop. On
  # exact-compare adapters (MySQL, MariaDB) each text key also compares its
  # utf8mb4 bytes (Selecto.Builder.ExactCompare).
  defp scoped_context_filter(selecto, %{strategy: strategy, primary_key: primary_key} = config) do
    keys = [primary_key | scope_keys(config)]
    relation = Map.get(selecto.domain, :source)
    quote_id = &Selecto.Builder.Sql.Helpers.quote_identifier(selecto, &1)
    context_alias = quote_id.(@context_alias)

    {sql, _aliases, params} =
      Selecto.gen_sql(context(selecto), unique_projection_aliases: true)

    columns =
      keys
      |> Enum.with_index(1)
      |> Enum.map(fn {key, index} ->
        mode =
          if key == primary_key,
            do: false,
            else: Selecto.Builder.ExactCompare.pair?(selecto, {relation, key}, {relation, key})

        {"selecto_root.#{quote_id.(to_string(key))}",
         "#{context_alias}.#{quote_id.(Selecto.Builder.Sql.projection_alias(index))}", mode}
      end)

    case strategy do
      :exists ->
        conditions =
          Enum.map(columns, fn {outer, inner, mode} ->
            Selecto.Builder.ExactCompare.eq(inner, outer, mode)
          end)

        correlated =
          IO.iodata_to_binary([
            "select 1 from (#{sql}) #{context_alias} where ",
            Enum.intersperse(conditions, " and ")
          ])

        {:exists, correlated, params}

      :in ->
        outer = Enum.flat_map(columns, &tuple_terms(elem(&1, 0), elem(&1, 2)))
        inner = Enum.flat_map(columns, &tuple_terms(elem(&1, 1), elem(&1, 2)))
        rebound = Selecto.SQL.Params.rebind_finalized(sql, params, selecto.adapter)

        {:raw_sql_filter,
         [
           "(",
           Enum.intersperse(outer, ", "),
           ") in (select ",
           Enum.intersperse(inner, ", "),
           " from (",
           rebound,
           ") ",
           context_alias,
           ")"
         ]}
    end
  end

  defp tuple_terms(column, false), do: [column]

  defp tuple_terms(column, mode),
    do: [column, Selecto.Builder.ExactCompare.bytes(column, mode)]

  @doc """
  The domain's declared retarget targets, keyed by join path, or `nil` when
  the domain declares none.
  """
  @spec declared_targets(Types.t() | map()) :: %{String.t() => map()} | nil
  def declared_targets(%Selecto{domain: domain}), do: declared_targets(domain)

  def declared_targets(domain) when is_map(domain) do
    case domain |> Map.get(:retarget) |> section_value(:targets) do
      targets when is_map(targets) -> Map.new(targets, fn {k, v} -> {to_string(k), v} end)
      _ -> nil
    end
  end

  @doc """
  Calculate the join path from the domain root to `target_schema`, a join id
  in the domain's join tree or, failing that, a schema reached through the
  root's associations. Subselects use it to correlate related rows.
  """
  @spec calculate_join_path(Types.t(), atom()) :: {:ok, [atom()]} | {:error, String.t()}
  def calculate_join_path(selecto, target_schema) do
    domain = selecto.domain

    case find_join_path(Map.get(domain, :joins, %{}), target_schema, []) do
      {:ok, path} ->
        {:ok, path}

      :not_found ->
        case find_association_path(domain, :source, target_schema, []) do
          {:ok, path} -> {:ok, path}
          :not_found -> {:error, "No join path found from source to #{target_schema}"}
        end
    end
  end

  @doc "Validate that each join of `join_path` follows a declared association."
  @spec validate_retarget_path(Types.t(), [atom()]) :: :ok | {:error, String.t()}
  def validate_retarget_path(selecto, join_path) do
    case walk(selecto.domain, join_path) do
      {:ok, _hops} -> :ok
      {:error, _code, message} -> {:error, message}
    end
  end

  ## Planning

  defp plan!(selecto, target) do
    domain = selecto.domain
    path = resolve_path!(domain, target)
    path_string = Enum.map_join(path, ".", &to_string/1)

    case declared_targets(domain) do
      nil ->
        :ok

      targets ->
        unless Map.has_key?(targets, path_string) do
          fail!(:retarget_not_allowed, "retarget to #{path_string} is not allowed by the domain",
            path: path_string
          )
        end
    end

    validate_default_target!(domain, targets_or_nil(domain))

    hops =
      case walk(domain, path) do
        {:ok, hops} -> hops
        {:error, code, message} -> fail!(code, message, path: path_string)
      end

    %{schema_key: target_schema, relation: relation} = List.last(hops)

    if Map.has_key?(relation, :values) or not Map.has_key?(relation, :source_table) do
      fail!(
        :unsupported_feature,
        "retarget targets must be table-backed relations",
        path: path_string
      )
    end

    primary_key = Map.get(relation, :primary_key, :id)

    unless primary_key in List.wrap(Map.get(relation, :fields)) do
      fail!(:invalid_query, "the retarget target must expose its primary key", path: path_string)
    end

    join = List.last(path)

    %{
      path: path_string,
      join: join,
      target_schema: target_schema,
      primary_key: primary_key,
      scope_keys: target_scope_keys(List.last(hops), primary_key),
      policy: target_policy(List.last(hops)),
      relation: relation,
      domain: target_domain(domain, relation, join_subtree(domain, path))
    }
  end

  defp targets_or_nil(domain), do: declared_targets(domain)

  defp validate_default_target!(domain, targets) do
    case domain |> Map.get(:retarget) |> section_value(:default_target) do
      nil ->
        :ok

      default ->
        default = to_string(default)

        if is_map(targets) and not Map.has_key?(targets, default) do
          fail!(
            :invalid_retarget,
            "retarget default_target must be one of the declared targets",
            path: default
          )
        end

        resolve_path!(domain, default)
        :ok
    end
  end

  # A join id names its position in the tree; a dotted path must follow the
  # tree from the root.
  defp resolve_path!(domain, target) do
    joins = Map.get(domain, :joins, %{})

    segments =
      case target do
        atom when is_atom(atom) and not is_nil(atom) -> [to_string(atom)]
        string when is_binary(string) -> String.split(string, ".")
        _ -> fail!(:invalid_query, "retarget requires a join id or join path")
      end

    unless Enum.all?(segments, &(&1 =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/)) do
      fail!(:invalid_query, "retarget requires a join id or join path")
    end

    case segments do
      [single] ->
        case find_join_path(joins, single, []) do
          {:ok, path} -> path
          :not_found -> fail!(:unknown_association, "unknown join #{single}", path: single)
        end

      many ->
        follow_joins!(joins, many, [])
    end
  end

  defp follow_joins!(_joins, [], acc), do: Enum.reverse(acc)

  defp follow_joins!(joins, [segment | rest], acc) do
    case Enum.find(joins || %{}, fn {id, _config} -> to_string(id) == segment end) do
      {id, config} ->
        follow_joins!(Map.get(config || %{}, :joins, %{}), rest, [id | acc])

      nil ->
        path = Enum.join(Enum.reverse([segment | Enum.map(acc, &to_string/1)]), ".")
        fail!(:unknown_association, "unknown join #{path}", path: path)
    end
  end

  defp find_join_path(joins, target, prefix) when is_map(joins) do
    target = to_string(target)

    Enum.reduce_while(joins, :not_found, fn {id, config}, _acc ->
      cond do
        to_string(id) == target ->
          {:halt, {:ok, Enum.reverse([id | prefix])}}

        is_map(config) and is_map(Map.get(config, :joins)) ->
          case find_join_path(config.joins, target, [id | prefix]) do
            {:ok, path} -> {:halt, {:ok, path}}
            :not_found -> {:cont, :not_found}
          end

        true ->
          {:cont, :not_found}
      end
    end)
  end

  defp find_join_path(_joins, _target, _prefix), do: :not_found

  defp find_association_path(_domain, schema, schema, _visited), do: {:ok, []}

  defp find_association_path(domain, from_schema, to_schema, visited) do
    relation =
      case from_schema do
        :source -> domain.source
        name -> Map.get(Map.get(domain, :schemas, %{}), name)
      end

    if is_nil(relation) or from_schema in visited do
      :not_found
    else
      relation
      |> Map.get(:associations, %{})
      |> Enum.reduce_while(:not_found, fn {name, association}, _acc ->
        case find_association_path(
               domain,
               Map.get(association, :queryable),
               to_schema,
               [from_schema | visited]
             ) do
          {:ok, path} -> {:halt, {:ok, [name | path]}}
          :not_found -> {:cont, :not_found}
        end
      end)
    end
  end

  # Follows each join's association from the root relation through the
  # domain's schemas.
  defp walk(domain, path) do
    path
    |> Enum.reduce_while({:ok, domain.source, []}, fn join, {:ok, relation, hops} ->
      association = relation |> Map.get(:associations, %{}) |> Map.get(join)
      queryable = association && Map.get(association, :queryable)
      target = queryable && Map.get(Map.get(domain, :schemas, %{}), queryable)

      cond do
        is_nil(association) ->
          {:halt, {:error, :unknown_association, "join #{join} does not follow an association"}}

        is_nil(target) ->
          {:halt, {:error, :unknown_association, "join #{join} names no domain schema"}}

        true ->
          {:cont,
           {:ok, target,
            hops ++
              [%{join: join, schema_key: queryable, relation: target, association: association}]}}
      end
    end)
    |> case do
      {:ok, _relation, []} -> {:error, :invalid_query, "retarget requires a join path"}
      {:ok, _relation, hops} -> {:ok, hops}
      {:error, _code, _message} = error -> error
    end
  end

  # The target-side scope keys of the association that reaches the target
  # (authored direct or through scope keys) that the target exposes.
  defp target_scope_keys(%{association: association, relation: relation}, primary_key) do
    through = association |> Map.get(:through) |> then(&if(is_map(&1), do: &1, else: %{}))
    fields = relation |> Map.get(:fields, []) |> List.wrap() |> Enum.map(&to_string/1)

    keys =
      [Map.get(association, :target_scope_key), Map.get(through, :target_scope_key)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&to_string/1)
      |> Enum.reject(&(to_string(&1) == to_string(primary_key)))

    # A scope key the target does not expose cannot identify its rows: refuse
    # rather than fall back to the key alone.
    case Enum.reject(keys, &(to_string(&1) in fields)) do
      [] ->
        keys

      missing ->
        fail!(
          :invalid_retarget,
          "the retarget target must expose the scope keys that confine it",
          scope_keys: Enum.map(missing, &to_string/1)
        )
    end
  end

  defp target_scope_keys(_hop, _primary_key), do: []

  # The association `where` policy that confines the target (the through
  # bridge's own policy is applied inside the context).
  defp target_policy(%{association: association}) do
    case Map.get(association, :where) || Map.get(association, "where") do
      policy when is_map(policy) -> policy
      _ -> %{}
    end
  end

  defp target_policy(_hop), do: %{}

  defp join_subtree(domain, path) do
    Enum.reduce(path, %{joins: Map.get(domain, :joins, %{})}, fn join, node ->
      node |> Map.get(:joins, %{}) |> Map.get(join, %{}) |> Kernel.||(%{})
    end)
    |> Map.get(:joins, %{})
  end

  # The domain rooted at the target relation: its own associations and the
  # join subtree below the target, over the same schemas.
  # A two-column domain keeps its tenant columns so every later hop still
  # pairs by name (lesson 41b).
  defp target_domain(domain, relation, joins) do
    columns = Selecto.Tenant.domain_tenant_columns(domain)

    %{
      source: Map.put_new(relation, :associations, %{}),
      schemas: Map.get(domain, :schemas, %{}),
      joins: joins || %{}
    }
    |> maybe_put(:name, Map.get(domain, :name))
    |> maybe_put(:tenant_columns, if(length(columns) > 1, do: columns))
  end

  defp configure_options(selecto) do
    policy = selecto.policy || %Selecto.Policy{}
    [adapter: selecto.adapter, mode: policy.mode, domain_sql: policy.domain_sql]
  end

  ## Tenant scope

  # A target relation that declares tenant_field gets the root's tenant
  # conditions on that field. A root whose required filters cannot reach it
  # fails closed rather than reading every tenant's target rows.
  defp carry_tenant_scope!(retargeted, origin, plan) do
    # A trusted tenant on a shared root is refused rather than bound (lesson
    # 42), so no hop of the path, however deep, is read under it unbounded.
    if is_nil(Selecto.Tenant.domain_tenant_field(origin)) and
         match?({:error, _}, Selecto.Tenant.tenant_boundary(origin)) do
      fail!(
        :missing_tenant_scope,
        "retarget to #{plan.path} cannot bind the trusted tenant to a shared root"
      )
    end

    # A trusted tenant the origin root cannot bind (a context naming another
    # column than the declared tenant_field) is refused here, typed.
    if Selecto.Tenant.engine_filters(origin) == [] and
         match?(
           {:error, %{details: %{code: :missing_tenant_scope}}},
           Selecto.Tenant.validate_scope(origin)
         ) do
      fail!(
        :missing_tenant_scope,
        "retarget to #{plan.path} cannot bind the trusted tenant to its root"
      )
    end

    root_field = Selecto.Tenant.domain_tenant_field(origin)
    columns = Selecto.Tenant.domain_tenant_columns(origin)
    target_field = plan.relation |> Map.get(:tenant_field) |> then(&(&1 && to_string(&1)))

    cond do
      # An untenanted target, or the scope column of a two-column domain
      # (bounded by the context path's by-name pairing, lesson 41c), is bounded
      # by the context. The tenant relations and members it reaches later carry
      # the scoped origin's admitted tenants (origin_column_query/2, lesson
      # 41b). An origin whose scope cannot be carried is refused.
      is_nil(target_field) or (length(columns) > 1 and target_field != root_field) ->
        if not is_nil(root_field) and not Selecto.Tenant.scoped?(origin) and
             Selecto.Tenant.carry_conditions(origin, root_field) == :error do
          fail!(
            :missing_tenant_scope,
            "retarget to #{plan.path} cannot carry the root tenant scope",
            tenant_field: root_field
          )
        end

        retargeted

      true ->
        carry_target_scope!(retargeted, origin, plan, target_field)
    end
  end

  @doc false
  # The scoped origin of a retargeted query projected onto the root column
  # whose values a relation's `target_field` takes (by name in a two-column
  # domain): the admitted tenant set a tenant relation reached later from an
  # untenanted retarget target is bound to (lesson 41b). `:error` when the
  # origin root has no such column.
  @spec origin_column_query(Types.t(), String.t()) :: {:ok, Types.t()} | :error
  def origin_column_query(selecto, target_field) do
    with %{origin: origin} <- get_retarget_config(selecto),
         column when is_binary(column) <-
           Selecto.Tenant.source_tenant_column(origin, target_field) do
      set =
        origin.set
        |> Map.merge(%{selected: [column], order_by: [], group_by: []})
        |> Map.drop([
          :limit,
          :offset,
          :subselected,
          :window_functions,
          :json_selects,
          :json_order_by,
          :array_operations
        ])

      {:ok, %{origin | set: set}}
    else
      _ -> :error
    end
  end

  defp carry_target_scope!(retargeted, origin, plan, target_field) do
    case Selecto.Tenant.carry_conditions(origin, target_field) do
      :unscoped ->
        retargeted

      :error ->
        fail!(
          :missing_tenant_scope,
          "retarget to #{plan.path} reads a tenant-scoped relation but the root tenant scope cannot be applied to it",
          tenant_field: target_field
        )

      {:ok, carried} ->
        retargeted =
          Enum.reduce(carried, retargeted, &Selecto.Tenant.require_tenant_filter(&2, &1))

        case Selecto.Tenant.tenant(origin) do
          nil -> retargeted
          tenant -> %{retargeted | tenant: Map.put(tenant, :tenant_field, target_field)}
        end
    end
  end

  ## Helpers

  defp strategy!(opts) do
    unknown = Keyword.keys(opts) -- [:strategy]

    if unknown != [] do
      fail!(:invalid_query, "retarget contains unsupported options #{inspect(unknown)}")
    end

    strategy = Keyword.get(opts, :strategy, :in)
    strategy = if is_binary(strategy), do: String.to_existing_atom(strategy), else: strategy

    unless strategy in @strategies do
      fail!(:invalid_query, "retarget strategy must be :in or :exists")
    end

    strategy
  rescue
    ArgumentError -> fail!(:invalid_query, "retarget strategy must be :in or :exists")
  end

  # Query sources and projections built for the root cannot follow the grain.
  defp ensure_root_sources_absent!(selecto) do
    present =
      [:ctes, :lateral_joins, :unnest, :values_clauses]
      |> Enum.filter(fn key -> Map.get(selecto.set, key) not in [nil, []] end)

    if present != [] do
      fail!(
        :invalid_query,
        "retarget must precede CTEs, lateral joins, unnest operations, and values clauses",
        sources: present
      )
    end
  end

  defp section_value(nil, _key), do: nil

  defp section_value(section, key) when is_map(section),
    do: Map.get(section, key, Map.get(section, to_string(key)))

  defp section_value(_section, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec fail!(atom(), String.t()) :: no_return()
  @spec fail!(atom(), String.t(), keyword()) :: no_return()
  defp fail!(code, message, details \\ []) do
    raise Error, code: code, message: message, details: Map.new(details)
  end
end
