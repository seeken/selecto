defmodule Selecto.Executor do
  @moduledoc """
  Query execution engine for Selecto.

  Handles execution of generated SQL queries through configured adapter or repo
  contexts, with proper error handling and connection management.
  """

  require Logger

  @query_execution_event [:selecto, :query, :execution]
  @max_filter_nodes 50_000

  # The names the statement compiled before prepare_read/1 names (see
  # put_emitted_names/1); kept in the query only while it prepares.
  @emitted_names :selecto_emitted_names

  @doc """
  Execute a query and return results with standardized error handling.

  ## Parameters

  - `selecto` - The Selecto struct containing connection and query info
  - `opts` - Execution options (currently unused but reserved for future use)

  ## Returns

  - `{:ok, {rows, columns, aliases}}` - Successful execution with results
  - `{:error, %Selecto.Error{}}` - Execution failure with detailed error

  ## Examples

      case Selecto.Executor.execute(selecto) do
        {:ok, {rows, columns, aliases}} ->
          # Process successful results
          handle_results(rows, columns, aliases)
        {:error, error} ->
          # Handle database error
          Logger.error("Query failed: \#{inspect(error)}")
      end
  """
  @spec execute(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          Selecto.Types.safe_execute_result()
  def execute(selecto, opts \\ []) do
    Selecto.Telemetry.operation(:execute, selecto, fn -> do_execute(selecto, opts) end)
  end

  defp do_execute(%Selecto{provider: provider} = selecto, opts) when not is_nil(provider) do
    Selecto.Configuration.Provider.invoke(selecto, :execute, [opts])
  end

  defp do_execute(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)
    query_id = query_id()

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         {:ok, selecto} <- prepare_read(selecto) do
      try do
        execute_safe(selecto, opts, query_id, start_time)
      rescue
        refusal in Selecto.Builder.ScopeRefusal -> {:error, Selecto.Error.from_reason(refusal)}
      end
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Selecto.Error.from_reason(reason)}
    end
  end

  @doc false
  # Every statement Selecto's executor runs (execute, count, projection sum,
  # stream) reaches the adapter with `selecto_read: true`, so an adapter can
  # guard Selecto's own reads (the PostgreSQL session checks, items 56 and
  # 61; MySQL-family temporary shadows) without guarding SQL the host runs
  # through the same adapter.
  def selecto_read?(opts) when is_list(opts), do: Keyword.get(opts, :selecto_read) == true
  def selecto_read?(_opts), do: false

  # The adapter options of a Selecto read: the read mark, and the
  # schema-qualified relation names an adapter resolved in prepare_read/2
  # (PostgreSQL, ruling R23b).
  defp read_opts(selecto, opts) do
    raw? = raw_sql?(selecto)

    opts =
      opts
      |> Keyword.put(:selecto_read, true)
      |> put_declared_functions(declared_functions(selecto))
      |> put_raw_mark(raw?)

    case selecto |> Map.get(:set) |> Kernel.||(%{}) |> Map.get(:qualified_relations) do
      relations when is_map(relations) and map_size(relations) > 0 ->
        Keyword.put(opts, :selecto_qualified_relations, relations)

      _ ->
        opts
    end
  end

  # An adapter treats a statement as Selecto's own only with this stamp: text
  # is hand-built unless the compile proved otherwise.
  defp put_raw_mark(opts, raw?) do
    opts = Keyword.delete(opts, :selecto_generated)

    if raw?,
      do: Keyword.put(opts, :selecto_raw_sql, true),
      else: opts |> Keyword.delete(:selecto_raw_sql) |> Keyword.put(:selecto_generated, true)
  end

  # prepare_read/1 records it; a read that skipped it compiles to find out.
  defp raw_sql?(selecto) do
    case selecto |> Map.get(:set) |> Kernel.||(%{}) |> Map.fetch(:raw_sql_compiled) do
      {:ok, marked?} -> marked?
      :error -> selecto |> compile_provenance() |> elem(0)
    end
  end

  # A statement that cannot compile counts as marked; its compile raises where
  # it always did.
  defp compile_provenance(selecto) do
    {_sql, marked?, nodes} =
      Selecto.Builder.Provenance.capture(fn -> Selecto.Builder.Sql.build(selecto, []) end)

    {marked? or Selecto.Builder.Provenance.config_text?(selecto), nodes}
  rescue
    _exception -> {true, 0}
  end

  defp put_declared_functions(opts, []), do: Keyword.delete(opts, :selecto_declared_functions)

  defp put_declared_functions(opts, functions),
    do: Keyword.put(opts, :selecto_declared_functions, functions)

  # The sql_names of the functions the domain declares (UDFs).
  defp declared_functions(selecto) do
    selecto
    |> Selecto.UDF.functions()
    |> Enum.flat_map(fn
      {_id, %{} = spec} -> List.wrap(Map.get(spec, :sql_name) || Map.get(spec, "sql_name"))
      _other -> []
    end)
    |> Enum.map(&to_string/1)
  end

  @doc false
  # A read's statement as it would execute: the adapter's prepare_read/2
  # applied, compiled, with the options the adapter's read path takes. For
  # entry points that run the statement another way (EXPLAIN).
  def read_statement(selecto, to_sql_opts) do
    with {:ok, selecto, opts} <- read_context(selecto) do
      {sql, params} = Selecto.to_sql(selecto, to_sql_opts)
      {:ok, sql, params, opts}
    end
  rescue
    refusal in Selecto.Builder.ScopeRefusal -> {:error, Selecto.Error.from_reason(refusal)}
  end

  @doc false
  # The query as prepare_read/2 leaves it, and the adapter options of a read
  # over it: for a caller that wraps the compiled statement (a count), then
  # runs it through the adapter's guarded read path.
  def read_context(selecto) do
    with {:ok, selecto} <- prepare_read(selecto) do
      {:ok, selecto, read_opts(selecto, [])}
    end
  end

  @doc false
  # Every relation a read names: its domains' source and schema tables and
  # association bridges, the tables its ad-hoc joins name, across every query
  # the statement compiles, each without the names a CTE or VALUES list makes
  # visible at its own position (read_scopes/1).
  def domain_relations(selecto) do
    selecto
    |> read_scopes()
    |> Enum.flat_map(&scope_relations/1)
    |> Enum.uniq()
  end

  @doc false
  # The relations one query names itself, before the names visible at its
  # position are taken out: its domain's tables, those its joins generate, its
  # ad-hoc sources.
  def own_relations(query) do
    collect_relations(Map.get(query, :domain), []) ++
      generated_relations(query) ++ declared_sources(query) ++ dynamic_sources(query)
  end

  @doc false
  # The relations an adapter resolves for one read_scopes/1 entry: its own,
  # without a root read as a list (list_root/1) and the ad-hoc join sources
  # that name a visible list. prepare_read/1 refuses a statement where a name
  # it defines is any other relation it reads (read_relations/1), so nothing
  # else is left out here.
  def scope_relations(%{set_result: true}), do: []

  def scope_relations(%{query: query, visible: visible} = scope) do
    (List.delete(collect_relations(Map.get(query, :domain), []), list_root(scope)) ++
       Enum.reject(dynamic_sources(query), &(&1 in visible)) ++
       declared_sources(query) ++ generated_relations(query))
    |> Enum.filter(&emitted?(&1, Map.get(scope, :emitted, :all)))
  end

  @doc false
  # The queries one statement compiles, in read_scopes/1's order.
  def read_queries(selecto), do: selecto |> read_scopes() |> Enum.map(& &1.query)

  @doc false
  # One entry per query the statement compiles: the read, its set operands, the
  # query each subquery join carries, and the queries its CTEs and LATERAL joins
  # build, with theirs. Each entry carries the names a CTE or VALUES list makes
  # visible at the query's own position (they hide a table of that name): its
  # own and its enclosing queries'; in a non-recursive WITH, a body sees only the
  # CTEs before it. It also carries the queries that enclose it, nearest first.
  # Set operation members and a retargeted query's origin are siblings, and
  # enclose nothing of each other. A builder that raises adds nothing here:
  # compiling raises too.
  #
  # A retargeted query's origin compiles inside the target's WHERE, under the
  # target's WITH: it is nested in the target. A name the target defines that
  # the origin's tables also name is listed as `forbidden`: the origin would
  # read the target's list for its own table (prepare_read/1 refuses it). Each
  # entry's `roots` are the queries whose declared `source_schema` its tables
  # take, nearest first: its own, then a retarget origin's (R59: a target
  # declaring none takes its origin's), then its enclosing queries'.
  #
  # Each entry also carries its `kind` (:query, :member, :origin, :nested,
  # :cte_body, :recursive_part) and `outer`, the names visible from enclosing
  # queries where it sits.
  def read_scopes(selecto) do
    emitted = emitted_names(selecto)

    selecto
    |> scopes([], [], [], [], :query, [])
    |> Enum.map(&Map.put(&1, :emitted, emitted))
  end

  # A set operation's result is its left member plus the operations: each
  # member compiles on its own, with its own WITH (parenthesized, or a derived
  # table on SQLite), so the result defines and reads nothing of its own; its
  # members are listed. Each entry's `path` names the set members it sits in:
  # two lists in different members are private to each (cte_name_redefined
  # compares only lists whose paths are nested, prefix-wise).
  defp scopes(query, visible, enclosing, outer_roots, forbidden, kind, path) do
    case set_operation_members(query) do
      [] ->
        query_scopes(query, visible, enclosing, outer_roots, forbidden, kind, path)

      members ->
        token = make_ref()

        siblings =
          members
          |> Enum.with_index()
          |> Enum.flat_map(fn {member, index} ->
            scopes(member, visible, enclosing, outer_roots, [], :member, path ++ [{token, index}])
          end)

        [
          %{
            query: query,
            kind: kind,
            outer: visible,
            visible: visible,
            enclosing: enclosing,
            roots: [query | outer_roots],
            forbidden: forbidden,
            path: path,
            set_result: true
          }
          | siblings
        ]
    end
  end

  defp query_scopes(query, visible, enclosing, outer_roots, forbidden, kind, path) do
    set = Map.get(query, :set) || %{}
    ctes = List.wrap(Map.get(set, :ctes))
    own = statement_names(query)
    main = visible ++ own
    inside = [query | enclosing]
    roots = [query | origin_chain(query)] ++ outer_roots

    origins =
      query
      |> retarget_origins()
      |> Enum.flat_map(&scopes(&1, main, inside, roots, own, :origin, path))

    joined = subquery_reads(query) ++ lateral_reads(query)

    nested =
      Enum.flat_map(joined, &scopes(&1, main, inside, roots, [], :nested, path)) ++
        (query
         |> embedded_queries()
         |> Enum.reject(&(&1 in joined))
         |> Enum.flat_map(fn embedded ->
           [entry | rest] = scopes(embedded, main, inside, roots, [], :nested, path)
           [Map.put(entry, :embedded, true) | rest]
         end))

    # VALUES lists and join-generated CTEs are emitted before the user CTEs,
    # and the user CTEs in dependency order (Selecto.Builder.Sql.visible_ctes/2).
    before_user = visible ++ values_names(query) ++ generated_cte_names(query)

    bodies =
      Enum.flat_map(ctes, fn spec ->
        before = Selecto.Builder.Sql.visible_ctes(query, spec)
        recursive_part? = match?(%{type: :recursive}, spec)
        # A recursive CTE's own name is visible to its recursive query.
        own_name = if recursive_part?, do: cte_names([spec]), else: []
        seen = before_user ++ cte_names(before) ++ own_name
        part = if recursive_part?, do: :recursive_part, else: :cte_body

        spec
        |> cte_queries()
        |> Enum.map(
          &Selecto.Builder.Sql.own_ctes(&1, Selecto.Builder.Sql.carried_ctes(query, spec))
        )
        |> Enum.flat_map(fn body ->
          [entry | rest] = scopes(body, seen, inside, roots, [], part, path)
          [Map.put(entry, :cte_spec, spec) | rest]
        end)
      end)

    [
      %{
        query: query,
        kind: kind,
        outer: visible,
        visible: main,
        enclosing: enclosing,
        roots: roots,
        forbidden: forbidden,
        path: path
      }
      | origins ++ nested ++ bodies
    ]
  end

  # The queries a filter, a selection or any other part of a query embeds and
  # compiles inside it (`{:exists, query}`, `{field, {:subquery, :in, query}}`,
  # `{field, op, {:subquery, :any, query}}`, a scope or HAVING filter, a
  # select expression): every %Selecto{} in its set that read_scopes/1 does not
  # already list (set members, a retarget origin,
  # subquery and LATERAL joins, CTE bodies).
  defp embedded_queries(query) do
    set = Map.get(query, :set) || %{}

    set_part =
      set
      |> Map.drop([:set_operations, :retarget_state, :ctes, :lateral_joins])
      |> Map.update(:dynamic_joins, %{}, fn joins ->
        if is_map(joins),
          do: Map.new(joins, fn {id, join} -> {id, drop_subquery_read(join)} end),
          else: joins
      end)

    # Only the query's own set: a domain or configuration may hold queries
    # (query members) the query does not use.
    set_part
    |> find_queries([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp drop_subquery_read(%{} = join) when not is_struct(join),
    do: Map.delete(join, :subquery_read)

  defp drop_subquery_read(join), do: join

  defp find_queries(%Selecto{} = query, acc), do: [query | acc]

  # A CASE, window, pivot, JSON or array spec, or any other struct a builder
  # compiles, may carry a query of its own.
  defp find_queries(%_{} = struct, acc), do: struct |> Map.from_struct() |> find_queries(acc)

  defp find_queries(%{} = map, acc) when not is_struct(map),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> find_queries(value, acc) end)

  defp find_queries(list, acc) when is_list(list), do: Enum.reduce(list, acc, &find_queries/2)

  defp find_queries(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> find_queries(acc)

  defp find_queries(_value, acc), do: acc

  @doc false
  # The names a CTE body defines for itself (its own CTEs and VALUES lists).
  def defined_names(query), do: statement_names(query) -- generated_cte_names(query)

  defp set_operation_members(query) do
    (Map.get(query, :set) || %{})
    |> Map.get(:set_operations, [])
    |> List.wrap()
    |> Enum.flat_map(&[&1.left_query, &1.right_query])
  end

  defp retarget_origins(query) do
    case (Map.get(query, :set) || %{}) |> Map.get(:retarget_state) do
      %{origin: %{} = origin} -> [origin]
      _ -> []
    end
  end

  defp origin_chain(query) do
    Enum.flat_map(retarget_origins(query), &[&1 | origin_chain(&1)])
  end

  defp subquery_reads(query) do
    query
    |> dynamic_joins()
    |> Enum.flat_map(fn
      {_id, %{subquery_read: %{} = subquery}} -> [subquery]
      _join -> []
    end)
  end

  defp lateral_reads(query) do
    set = Map.get(query, :set) || %{}
    Enum.flat_map(List.wrap(Map.get(set, :lateral_joins)), &lateral_query(&1, query))
  end

  defp cte_names(specs, dialect \\ :any), do: Enum.flat_map(specs, &list_name(&1, dialect))

  @doc false
  # A CTE spec's name; every name a raw CTE's text (`{:raw_cte, sql, params}`,
  # the host's own, R68) defines as `dialect` lexes it (Selecto.Builder.RawCte);
  # [] for raw text that does not parse, which prepare_read/1 refuses
  # (`raw_cte_unparsed`).
  def list_name(spec, dialect \\ :any)
  def list_name(%{name: name}, _dialect) when not is_nil(name), do: [to_string(name)]

  def list_name({tag, sql, _params}, dialect) when tag in [:raw_cte, :raw_recursive_cte] do
    case Selecto.Builder.RawCte.names(sql, dialect) do
      {:ok, names} -> names
      :error -> []
    end
  end

  def list_name(_spec, _dialect), do: []

  @doc false
  # The dialect raw CTE text of `query` is read in: its adapter's name.
  def dialect(query) do
    case Selecto.AdapterSupport.adapter_name(Map.get(query, :adapter)) do
      name when name in [:postgresql, :mysql, :mariadb, :sqlite, :duckdb] -> name
      _other -> :any
    end
  end

  defp cte_queries(%{type: :recursive, name: name, base_query: base, recursive_query: step})
       when is_function(base, 0) and is_function(step, 1) do
    reference = Selecto.Builder.CteSql.create_cte_reference(to_string(name))
    built([fn -> base.() end, fn -> step.(reference) end])
  end

  defp cte_queries(%{query_builder: builder}) when is_function(builder, 0), do: built([builder])
  defp cte_queries(_spec), do: []

  defp lateral_query(%{subquery_builder: builder}, query) when is_function(builder, 1),
    do: built([fn -> builder.(query) end])

  defp lateral_query(_spec, _query), do: []

  defp built(builders) do
    Enum.flat_map(builders, fn builder ->
      try do
        case builder.() do
          %{domain: domain} = inner when is_map(domain) -> [inner]
          _other -> []
        end
      rescue
        _exception -> []
      end
    end)
  end

  @doc false
  # The tables `Selecto.join/3` names with `source:`. A CTE or VALUES list the
  # statement defines is no table: the statement's own name shadows one.
  def dynamic_sources(selecto) do
    local = statement_names(selecto)

    selecto
    |> dynamic_joins()
    |> Enum.flat_map(fn
      {_id, %{join_type: :custom, source_kind: :cte}} ->
        []

      {_id, %{join_type: :custom, source: source}}
      when is_binary(source) or (is_atom(source) and not is_nil(source)) ->
        if to_string(source) in local, do: [], else: [to_string(source)]

      _join ->
        []
    end)
  end

  @doc false
  # The tables a domain's declared non-association joins (`non_assoc: true`,
  # join_type :custom) name with `source:`; an ad-hoc join (Selecto.join/3) is
  # registered there too and counts with dynamic_sources/1.
  def declared_sources(selecto) do
    ad_hoc = selecto |> dynamic_joins() |> Map.keys()

    selecto
    |> Map.get(:config)
    |> Kernel.||(%{})
    |> Map.get(:joins, %{})
    |> Enum.reject(fn {id, _join} -> id in ad_hoc end)
    |> Enum.flat_map(fn
      {_id, %{join_type: :custom, source_kind: :cte}} ->
        []

      {_id, %{join_type: :custom, is_custom: true, source: source}}
      when is_binary(source) or (is_atom(source) and not is_nil(source)) ->
        [to_string(source)]

      _join ->
        []
    end)
  end

  defp statement_names(selecto) do
    set = Map.get(selecto, :set) || %{}

    values_names(selecto) ++
      generated_cte_names(selecto) ++ cte_names(List.wrap(Map.get(set, :ctes)), dialect(selecto))
  end

  defp values_names(selecto) do
    set = Map.get(selecto, :set) || %{}

    for %{} = values <- List.wrap(Map.get(set, :values_clauses)),
        name = Map.get(values, :alias),
        not is_nil(name),
        do: to_string(name)
  end

  # The CTEs hierarchy joins emit (Selecto.Builder.Sql.Hierarchy).
  defp generated_cte_names(selecto) do
    selecto
    |> Map.get(:config)
    |> Kernel.||(%{})
    |> Map.get(:joins, %{})
    |> Enum.flat_map(fn
      {id, %{join_type: :hierarchical_adjacency} = join} ->
        [Selecto.Builder.GeneratedName.hierarchy(id, join)]

      {id, %{join_type: :hierarchical_materialized_path} = join} ->
        [Selecto.Builder.GeneratedName.materialized_path(id, join)]

      {id, %{join_type: :hierarchical_closure_table} = join} ->
        [Selecto.Builder.GeneratedName.closure(id, join)]

      _join ->
        []
    end)
  end

  defp dynamic_joins(selecto) do
    case Map.get(selecto, :set) do
      %{} = set -> Map.get(set, :dynamic_joins) || %{}
      _none -> %{}
    end
  end

  # Relations a join's compile names beyond the domain's tables: a tagging
  # join's junction table, a closure table, a snowflake's normalization chain.
  defp generated_relations(selecto) do
    selecto
    |> Map.get(:config)
    |> Kernel.||(%{})
    |> Map.get(:joins, %{})
    |> Enum.flat_map(fn
      {_id, %{join_type: :many_to_many} = join} ->
        [to_string(Selecto.Builder.Sql.Tagging.join_table_name(join))]

      {_id, %{join_type: :hierarchical_closure_table} = join} ->
        [to_string(Selecto.Builder.Sql.Hierarchy.closure_table_name(join))]

      {_id, %{join_type: :snowflake_dimension} = join} ->
        join
        |> Map.get(:normalization_joins, [])
        |> Enum.flat_map(&List.wrap(Map.get(&1, :table)))
        |> Enum.map(&to_string/1)

      _join ->
        []
    end)
  end

  defp collect_relations(map, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn
      {key, value}, acc
      when key in [:source_table, "source_table"] and
             (is_binary(value) or (is_atom(value) and not is_nil(value))) ->
        [to_string(value) | acc]

      {key, %{} = through}, acc when key in [:through, "through"] ->
        table = Map.get(through, :table) || Map.get(through, "table")
        acc = if is_binary(table), do: [table | acc], else: acc
        collect_relations(through, acc)

      {_key, value}, acc ->
        collect_relations(value, acc)
    end)
  end

  defp collect_relations(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_relations/2)

  defp collect_relations(_value, acc), do: acc

  @doc false
  # Every query compiled into this one: set operation operands and a
  # retarget origin, recursively.
  def set_operands(selecto) do
    set = Map.get(selecto, :set) || %{}

    operands =
      set
      |> Map.get(:set_operations, [])
      |> Enum.flat_map(&[&1.left_query, &1.right_query])

    # A retargeted query compiles its origin (the scope it narrows from)
    # into the same statement.
    origin =
      case Map.get(set, :retarget_state) do
        %{origin: %{} = origin} -> [origin]
        _ -> []
      end

    Enum.flat_map(operands ++ origin, &[&1 | set_operands(&1)])
  end

  # An adapter may load what compiling a read needs from the database first
  # (`prepare_read/2`): MySQL and MariaDB load the storage types of the
  # domain's relations so TIMESTAMP scope comparisons compile
  # zone-independently (Selecto.Builder.ExactCompare.storage_kind/4).
  @doc false
  def prepare_read(selecto) do
    selecto = put_emitted_names(selecto)

    with :ok <- no_scope_collision(selecto),
         {:ok, prepared} <- prepare_adapter_read(selecto) do
      prepared = drop_emitted_names(prepared)
      {marked?, nodes} = compile_provenance(prepared)

      if nodes > @max_filter_nodes do
        {:error,
         Selecto.Error.validation_error("Filters are beyond the size Selecto will compile", %{
           reason: :filter_too_large,
           limit: @max_filter_nodes
         })}
      else
        {:ok, record_mark(prepared, marked?)}
      end
    end
  end

  defp no_scope_collision(selecto) do
    scopes = read_scopes(selecto)

    with :ok <- raw_ctes_parse(scopes),
         :ok <- raw_ctes_params_bind(scopes),
         :ok <- list_roots_quotable(scopes),
         :ok <- no_nested_recursive_with(scopes),
         :ok <- no_redefined_name(scopes),
         :ok <- no_name_collision(scopes) do
      embedded_tenant_scopes(scopes)
    end
  end

  # A raw CTE's text must be plain definitions whose names can be read
  # (Selecto.Builder.RawCte): otherwise which names it defines is unknown.
  defp raw_ctes_parse(scopes) do
    scopes
    |> Enum.flat_map(fn %{query: query} ->
      for list <- List.wrap(Map.get(Map.get(query, :set) || %{}, :ctes)),
          do: {list, dialect(query)}
    end)
    |> Enum.filter(fn
      {{tag, sql, _params}, dialect} when tag in [:raw_cte, :raw_recursive_cte] ->
        Selecto.Builder.RawCte.names(sql, dialect) == :error

      _spec ->
        false
    end)
    |> case do
      [] ->
        :ok

      _unparsed ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message:
             "A raw CTE's text is not plain `name [(columns)] AS (...)` definitions; " <>
               "Selecto cannot tell which names it defines",
           details: %{code: :query_rule_not_evaluable, reason: :raw_cte_unparsed}
         }}
    end
  end

  # A raw CTE's params must bind to its text's placeholders: a count that does
  # not match refuses typed rather than raise while compiling.
  defp raw_ctes_params_bind(scopes) do
    scopes
    |> Enum.flat_map(fn %{query: query} ->
      adapter = Map.get(query, :adapter, Selecto.AdapterSupport.default_adapter())
      for list <- List.wrap(Map.get(Map.get(query, :set) || %{}, :ctes)), do: {list, adapter}
    end)
    |> Enum.reject(fn
      {{tag, sql, params}, adapter} when tag in [:raw_cte, :raw_recursive_cte] ->
        Selecto.Builder.CteSql.raw_params_bind?(sql, params, adapter)

      _spec ->
        true
    end)
    |> case do
      [] ->
        :ok

      _unbound ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message: "A raw CTE's params do not match the placeholders in its text",
           details: %{code: :query_rule_not_evaluable, reason: :raw_cte_params_mismatch}
         }}
    end
  end

  # A root read as a list, and an ad-hoc join's source, is named in the SQL like
  # any table: a name an identifier cannot hold refuses typed rather than raise
  # while compiling.
  defp list_roots_quotable(scopes) do
    scopes
    |> Enum.flat_map(fn scope -> [list_root(scope) | dynamic_join_sources(scope.query)] end)
    |> Enum.reject(&(is_nil(&1) or Selecto.Builder.Sql.Helpers.valid_identifier?(&1)))
    |> case do
      [] ->
        :ok

      names ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message:
             "A CTE or VALUES list or a joined relation has a name an identifier cannot hold",
           details: %{
             code: :query_rule_not_evaluable,
             reason: :invalid_identifier,
             relations: Enum.uniq(names)
           }
         }}
    end
  end

  defp dynamic_join_sources(query) do
    for {_id, %{join_type: :custom, source: source}} <- dynamic_joins(query),
        is_binary(source) or (is_atom(source) and not is_nil(source)),
        do: to_string(source)
  end

  # A query a filter or selection embeds compiles on its own (Selecto.to_sql/2),
  # so its tenant scope is checked as its own: a missing, mismatched or
  # ambiguous one refuses typed here rather than raise while compiling.
  defp embedded_tenant_scopes(scopes) do
    Enum.reduce_while(scopes, :ok, fn
      %{embedded: true, query: query}, :ok ->
        case Selecto.Tenant.validate_scope(query, []) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      _scope, :ok ->
        {:cont, :ok}
    end)
  end

  # One rule on every adapter, whatever each dialect shows a body: a CTE or
  # VALUES name defined anywhere in the statement (a user's, or one Selecto
  # generates) that names a relation read anywhere in it refuses
  # (`cte_name_collision`). Every query counts: CTE bodies at any depth,
  # subquery and LATERAL joins, set members, recursive bases and steps, a
  # retarget origin, and the relations a join's generated CTE reads.
  defp no_name_collision(scopes) do
    names = scopes |> Enum.flat_map(&scope_definitions/1) |> Enum.map(&elem(&1, 0))
    folded = MapSet.new(names, &String.downcase/1)

    scopes
    |> Enum.flat_map(&read_relations/1)
    |> Enum.filter(&MapSet.member?(folded, String.downcase(&1)))
    |> Enum.uniq()
    |> case do
      [] ->
        :ok

      relations ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message:
             "A CTE or VALUES list is named like a relation the statement reads; " <>
               "rename the list",
           details: %{
             code: :query_rule_not_evaluable,
             reason: :cte_name_collision,
             relations: relations
           }
         }}
    end
  end

  # The same CTE or VALUES name defined at two places with different
  # definitions: which one a query reads would depend on the database's
  # scoping (MariaDB lets an enclosing name win over a body's own; SQLite and
  # MariaDB under WITH RECURSIVE show a body a later one). Identical copies are
  # one list. Lists in different members of one set operation are private to
  # each: every adapter compiles a member with its own WITH, parenthesized or
  # (SQLite) as a derived table, and no member sees another's.
  defp no_redefined_name(scopes) do
    scopes
    |> Enum.flat_map(fn scope ->
      for {name, definition} <- scope_definitions(scope), do: {name, {definition, scope.path}}
    end)
    |> Enum.group_by(&String.downcase(elem(&1, 0)), &elem(&1, 1))
    |> Enum.filter(fn {_name, placed} -> conflicting?(placed) end)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] ->
        :ok

      names ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message:
             "A CTE or VALUES name is defined twice in the statement with different " <>
               "definitions; rename one",
           details: %{
             code: :query_rule_not_evaluable,
             reason: :cte_name_redefined,
             relations: Enum.sort(names)
           }
         }}
    end
  end

  defp conflicting?(placed) do
    Enum.any?(placed, fn {definition, path} ->
      Enum.any?(placed, fn {other, other_path} ->
        other != definition and
          (List.starts_with?(path, other_path) or
             List.starts_with?(other_path, path))
      end)
    end)
  end

  # A set operation's result defines nothing of its own: its members do.
  defp scope_definitions(%{set_result: true}), do: []
  defp scope_definitions(%{query: query}), do: definitions(query)

  # What a CTE holds: its settings and the SQL its body compiles to under the
  # query that defines it (which scopes it), so two builder closures that build
  # one body define one list. A body that does not compile is compared by its
  # spec; compiling the statement raises for it anyway.
  defp cte_definition(spec, holder) do
    settings =
      Map.drop(spec, [:id, :validated, :query_builder, :query, :base_query, :recursive_query])

    bodies =
      try do
        spec
        |> cte_queries()
        |> Enum.map(fn body ->
          body |> Selecto.QueryMembers.Data.scope_member(holder) |> Selecto.to_sql()
        end)
      rescue
        _exception -> {:spec, Map.drop(spec, [:id, :validated])}
      end

    {settings, bodies}
  end

  @doc false
  # The names one query defines, each with what it holds: its user CTEs, its
  # VALUES lists, the CTEs its hierarchy joins generate (named by their
  # definition). A list's per-call id and validation mark are no part of what
  # it holds: two with_cte calls whose builders build one body define one list.
  def definitions(query) do
    set = Map.get(query, :set) || %{}

    ctes =
      for %{name: name} = spec <- List.wrap(Map.get(set, :ctes)),
          not is_nil(name),
          do: {to_string(name), {:cte, cte_definition(spec, query)}}

    values =
      for %{} = values <- List.wrap(Map.get(set, :values_clauses)),
          name = Map.get(values, :alias),
          not is_nil(name),
          do: {to_string(name), {:values, Map.drop(values, [:id, :validated])}}

    generated = for name <- generated_cte_names(query), do: {name, {:generated, name}}

    raw =
      for {tag, sql, params} = list <- List.wrap(Map.get(set, :ctes)),
          tag in [:raw_cte, :raw_recursive_cte],
          name <- list_name(list, dialect(query)),
          do: {name, {:raw, sql, params}}

    ctes ++ values ++ generated ++ raw
  end

  @doc false
  # The relations one read_scopes/1 entry reads as tables, every name not a
  # reference to a CTE or VALUES list: its domain's relations, but for a root
  # read as a list (list_root/1); each ad-hoc join's source, unless it names a
  # list visible where it sits (a retarget origin never takes its target's);
  # each declared non-association join's source, and the tables its joins
  # generate (a closure or junction table), always.
  def read_relations(%{set_result: true}), do: []

  def read_relations(%{query: query, visible: visible, forbidden: forbidden} = scope) do
    references = visible -- forbidden

    (List.delete(collect_relations(Map.get(query, :domain), []), list_root(scope)) ++
       Enum.reject(dynamic_sources(query), &(&1 in references)) ++
       declared_sources(query) ++ generated_relations(query))
    |> Enum.filter(&emitted?(&1, Map.get(scope, :emitted, :all)))
  end

  @doc false
  # The list a read_scopes/1 entry's root reads, or nil: its domain's own
  # source_table, when the domain declares no source_schema and the name is a
  # CTE or VALUES list the query defines itself (a domain over a CTE), or, for
  # a CTE body, one visible where the body sits. Joined schemas, through tables
  # and anything a schema is declared for stay tables.
  def list_root(%{set_result: true}), do: nil

  def list_root(%{query: query, kind: kind, visible: visible, forbidden: forbidden}) do
    source = (Map.get(query, :domain) || %{}) |> Map.get(:source) || %{}
    root = Map.get(source, :source_table) || Map.get(source, "source_table")
    declared = Map.get(source, :source_schema) || Map.get(source, "source_schema")

    lists =
      if kind in [:cte_body, :recursive_part],
        do: visible -- forbidden,
        else: statement_names(query) -- forbidden

    cond do
      is_nil(root) or declared not in [nil, ""] -> nil
      to_string(root) in lists -> to_string(root)
      true -> nil
    end
  end

  def list_root(_scope), do: nil

  @doc false
  # Each list root's name with the identifier the SQL names it by (unquoted when
  # plain, as Selecto.Builder.Sql.Helpers.relation_identifier/2 writes it;
  # "double quoted" otherwise, or where a raw CTE's text quotes it): what an
  # adapter that resolves relations looks the name up as.
  def list_root_identifiers(selecto) do
    scopes = read_scopes(selecto)

    quoted_raw =
      for %{query: query} <- scopes,
          {tag, sql, _params} <- List.wrap(Map.get(Map.get(query, :set) || %{}, :ctes)),
          tag in [:raw_cte, :raw_recursive_cte],
          {:ok, entries} <- [Selecto.Builder.RawCte.entries(sql, dialect(query))],
          {name, true} <- entries,
          do: name

    scopes
    |> Enum.map(&list_root/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn name ->
      if Selecto.Builder.Sql.Helpers.plain_name?(name) and name not in quoted_raw,
        do: {name, name},
        else: {name, "\"" <> String.replace(name, "\"", "\"\"") <> "\""}
    end)
  end

  @doc false
  # The names the statement's roots read as lists (list_root/1): an adapter
  # that resolves relations refuses one that also names a relation it can see.
  def list_roots(selecto),
    do:
      selecto |> read_scopes() |> Enum.map(&list_root/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  # A recursive CTE's base or step that defines its own CTE or VALUES list: the
  # nested WITH would scope over the whole UNION, or follow UNION ALL, which no
  # dialect parses. Refused on every adapter.
  defp no_nested_recursive_with(scopes) do
    scopes
    |> Enum.filter(&(&1.kind == :recursive_part))
    |> Enum.flat_map(&defined_names(&1.query))
    |> case do
      [] ->
        :ok

      names ->
        {:error,
         %Selecto.Error{
           type: :query_enforcement,
           message:
             "A recursive CTE's base or recursive query cannot define its own CTE or " <>
               "VALUES list",
           details: %{
             code: :query_rule_not_evaluable,
             reason: :recursive_cte_nested_with,
             relations: Enum.uniq(names)
           }
         }}
    end
  end

  # A domain names relations its read may never touch: the tables of declared
  # joins, through and closure tables the query does not use. Only those the
  # statement compiles to name are resolved and checked (scope_relations/1,
  # read_relations/1): the read is compiled once first, the definitions of the
  # lists it defines (`name [(columns)] AS [[NOT] MATERIALIZED] (`) are taken
  # out of its text, and a relation whose name the rest holds as a word, in any
  # case, is kept. Text holding a name it does not read (a column, an alias, a
  # literal, a reference to a list) only keeps the relation in. A statement that
  # does not compile keeps every relation.
  defp put_emitted_names(%{set: set} = selecto) when is_map(set) do
    case compiled_names(selecto) do
      :all -> selecto
      names -> %{selecto | set: Map.put(set, @emitted_names, names)}
    end
  end

  defp put_emitted_names(selecto), do: selecto

  defp drop_emitted_names(%{set: set} = selecto) when is_map(set),
    do: %{selecto | set: Map.delete(set, @emitted_names)}

  defp drop_emitted_names(selecto), do: selecto

  defp emitted_names(selecto) do
    case selecto |> Map.get(:set) |> Kernel.||(%{}) |> Map.get(@emitted_names) do
      {:names, %MapSet{}, text} = names when is_binary(text) -> names
      _none -> :all
    end
  end

  @word ~r/[a-z_\x80-\xff][a-z0-9_$\x80-\xff]*/
  @quoted [{~r/"((?:[^"]|"")*)"/, ~s(""), ~s(")}, {~r/`((?:[^`]|``)*)`/, "``", "`"}]

  # The compiled text, its list definitions taken out, and its words and
  # quoted identifiers, lower case.
  defp compiled_names(selecto) do
    {{sql, _aliases, _params}, _marked?, _nodes} =
      Selecto.Builder.Provenance.capture(fn -> Selecto.Builder.Sql.build(selecto, []) end)

    text = without_definitions(String.downcase(sql), list_names(selecto))

    quoted =
      for {pattern, doubled, quote} <- @quoted,
          [_all, name] <- Regex.scan(pattern, text),
          do: String.replace(name, doubled, quote)

    words = for [word] <- Regex.scan(@word, text), do: word
    {:names, MapSet.new(words ++ quoted), text}
  rescue
    _exception -> :all
  catch
    _kind, _reason -> :all
  end

  defp list_names(selecto) do
    selecto
    |> scopes([], [], [], [], :query, [])
    |> Enum.flat_map(&statement_names(&1.query))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp without_definitions(text, []), do: text

  defp without_definitions(text, lists) do
    names = lists |> Enum.flat_map(&spellings/1) |> Enum.map_join("|", &Regex.escape/1)

    Regex.replace(
      ~r/(?<![a-z0-9_$\x80-\xff])(?:#{names})(?![a-z0-9_$\x80-\xff])(?:\s*\([^()]*\))?\s+as\s*(?:not\s+materialized\s*|materialized\s*)?\(/,
      text,
      " ("
    )
  end

  # A name as a statement may write it: bare, or in double quotes, backticks
  # or brackets, its quote doubled.
  defp spellings(name) do
    [
      name,
      ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s("),
      "`" <> String.replace(name, "`", "``") <> "`",
      "[" <> String.replace(name, "]", "]]") <> "]"
    ]
  end

  # Whether the compiled text, its list definitions taken out, names a
  # relation (or, schema-qualified, its last segment): as a word or quoted
  # identifier, or, for a name with other characters, anywhere in the text.
  defp emitted?(_name, :all), do: true

  defp emitted?(name, {:names, names, text}) do
    name = String.downcase(to_string(name))

    Enum.any?([name, name |> String.split(".") |> List.last()], fn name ->
      name in names or
        (not Regex.match?(~r/\A[a-z_\x80-\xff][a-z0-9_$\x80-\xff]*\z/, name) and
           String.contains?(text, name))
    end)
  end

  defp record_mark(%{set: set} = selecto, marked?) when is_map(set),
    do: %{selecto | set: Map.put(set, :raw_sql_compiled, marked?)}

  defp record_mark(selecto, _marked?), do: selecto

  defp prepare_adapter_read(selecto) do
    adapter = runtime_adapter(selecto)

    if is_atom(adapter) and not is_nil(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :prepare_read, 2) do
      case adapter.prepare_read(selecto, runtime_connection(selecto)) do
        {:ok, %Selecto{} = prepared} -> {:ok, prepared}
        {:ok, prepared} when is_map(prepared) -> {:ok, prepared}
        {:error, %Selecto.Error{}} = error -> error
        {:error, reason} -> {:error, Selecto.Error.from_reason(reason)}
      end
    else
      {:ok, selecto}
    end
  end

  defp query_id do
    case Selecto.Telemetry.Context.current_operation() do
      %{operation_id: operation_id} -> operation_id
      _ -> :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    end
  end

  # The complexity check and task timeout of execute/2, for the other
  # execution entry points (metadata, count and projection sum).
  defp guarded(selecto, opts, work) do
    start_time = System.monotonic_time(:millisecond)
    query_id = query_id()

    with :ok <- check_query_complexity(selecto, opts, query_id) do
      with_timeout_protection(
        selecto,
        opts,
        query_id,
        start_time,
        Selecto.Performance.Hooks.snapshot_hooks(),
        work
      )
    end
  end

  defp execute_safe(selecto, opts, query_id, start_time) do
    hook_options = hook_options(opts)
    hook_snapshot = Selecto.Performance.Hooks.snapshot_hooks()

    with {:ok, compiled} <- compile_and_check(selecto, opts, query_id, hook_options) do
      hook_options =
        if compiled, do: Keyword.put(hook_options, :compiled, compiled), else: hook_options

      work = fn deadline ->
        execute_with_hooks(selecto, hook_options, query_id, start_time, deadline)
      end

      result =
        if run_in_caller?(selecto, opts, hook_snapshot) do
          with_adapter_timeout(opts, query_id, start_time, work)
        else
          with_timeout_protection(selecto, opts, query_id, start_time, hook_snapshot, fn ->
            work.(nil)
          end)
        end

      # Apply output format transformation if specified
      case result do
        {:ok, {rows, columns, aliases}} ->
          format = Keyword.get(opts, :format, :raw)
          format_options = Keyword.get(opts, :format_options, [])

          case Selecto.Telemetry.span([:transform], %{}, fn ->
                 Selecto.Output.Formats.transform(
                   {rows, columns, aliases},
                   format,
                   format_options
                 )
               end) do
            {:ok, transformed_result} ->
              {:ok, transformed_result}

            {:error, transform_error} ->
              {:error,
               Selecto.Error.transformation_error("Output format transformation failed", %{
                 format: format,
                 options: format_options,
                 error: transform_error
               })}
          end

        error_result ->
          error_result
      end
    end
  end

  # The complexity check needs the joins the query resolves, which compiling
  # the query resolves anyway. So the query is compiled once, here, and the
  # check reads the compile's joins; execution reuses the compiled SQL rather
  # than compiling again. Without the check (`analyze_complexity: false`)
  # nothing is compiled here and execution compiles as before.
  defp compile_and_check(selecto, opts, query_id, hook_options) do
    if opts[:analyze_complexity] == false do
      {:ok, nil}
    else
      case compile(selecto, Keyword.fetch!(hook_options, :gen_sql_opts)) do
        {:ok, compiled, nil} ->
          # Set operations do not resolve joins while compiling.
          with :ok <- analyze_query_complexity(selecto, opts, query_id, compiled.sql) do
            {:ok, compiled}
          end

        {:ok, compiled, joins_in_order} ->
          analysis =
            Selecto.Performance.ComplexityAnalyzer.analyze_resolved(
              selecto,
              joins_in_order,
              opts
            )

          with :ok <- complexity_outcome(analysis, query_id, compiled.sql) do
            {:ok, compiled}
          end

        {:raised, %Selecto.Builder.ScopeRefusal{} = refusal, _stacktrace} ->
          # A scope comparison the adapter's storage cannot make exact is a
          # typed refusal, never a raise.
          {:error, Selecto.Error.from_reason(refusal)}

        {:raised, exception, stacktrace} ->
          # A query the check rejects is rejected even when it cannot compile,
          # as when the check ran before compiling; otherwise the compile
          # error is raised as before.
          with :ok <- analyze_query_complexity(selecto, opts, query_id, nil) do
            reraise exception, stacktrace
          end
      end
    end
  end

  defp compile(selecto, gen_sql_opts) do
    started_at = System.monotonic_time(:millisecond)

    {sql, aliases, params, joins_in_order} =
      Selecto.Telemetry.span([:compile], %{}, fn ->
        Selecto.gen_sql_with_joins(selecto, gen_sql_opts)
      end)

    compiled = %{
      sql: sql,
      aliases: aliases,
      params: params,
      started_at: started_at,
      built_at: System.monotonic_time(:millisecond)
    }

    {:ok, compiled, joins_in_order}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end

  defp check_query_complexity(selecto, opts, query_id) do
    if opts[:analyze_complexity] == false do
      :ok
    else
      analyze_query_complexity(selecto, opts, query_id, nil)
    end
  end

  defp analyze_query_complexity(selecto, opts, query_id, sql) do
    selecto
    |> Selecto.Performance.ComplexityAnalyzer.analyze(opts)
    |> complexity_outcome(query_id, sql)
  end

  # `sql` names the query shape when it is known, so that a warning is
  # logged once per shape (see Selecto.Performance.ComplexityWarnings).
  defp complexity_outcome(analysis_result, query_id, sql) do
    case analysis_result do
      {:ok, analysis} ->
        Enum.each(analysis.warnings, fn warning ->
          if Selecto.Performance.ComplexityWarnings.log?(sql, warning) do
            Logger.warning("[Selecto] Query complexity: #{warning}")
          end
        end)

        :telemetry.execute(
          [:selecto, :query, :complexity_analyzed],
          %{complexity_score: analysis.score},
          %{query_id: query_id, warning_count: length(analysis.warnings)}
        )

        :ok

      {:error, :too_complex, analysis} ->
        Logger.error("[Selecto] Query rejected due to high complexity",
          score: analysis.score,
          issues: analysis.blocking_issues
        )

        :telemetry.execute(
          [:selecto, :query, :complexity_rejected],
          %{complexity_score: analysis.score},
          %{
            query_id: query_id,
            issue_count: length(analysis.blocking_issues)
          }
        )

        {:error,
         Selecto.Error.validation_error("Query too complex to execute safely", %{
           complexity_score: analysis.score,
           max_score: analysis.details.max_score,
           issues: analysis.blocking_issues,
           recommendations: analysis.recommendations,
           details: analysis.details
         })}
    end
  end

  # Default 30 seconds, at most 5 minutes.
  @default_timeout 30_000
  @max_timeout 300_000

  defp effective_timeout(opts), do: min(opts[:timeout] || @default_timeout, @max_timeout)

  # Time an adapter that enforces the deadline itself has to end a read and undo
  # it before its task is shut down.
  @adapter_grace 5_000
  @task_deadline :selecto_executor_task_deadline

  # Run the execution work with timeout protection: in a supervised task that
  # is abandoned (shut down) when the timeout elapses. A task killed in a read
  # abandons the read's reply and transaction state on a connection the host may
  # hold, so an adapter that enforces the deadline (`supports?(:execute_timeout)`)
  # gets it and ends the read itself; the shutdown is left for a server that
  # never answers.
  defp with_timeout_protection(selecto, opts, query_id, start_time, hook_snapshot, work) do
    timeout = effective_timeout(opts)
    restore_hooks? = not Selecto.Performance.Hooks.empty_snapshot?(hook_snapshot)
    started_at = System.monotonic_time(:millisecond)
    adapter_deadline? = timeout > 0 and adapter_enforces_timeout?(runtime_adapter(selecto))

    # Wrap execution in Task.async for timeout enforcement
    task =
      Selecto.TaskSupervisor.async(fn ->
        if adapter_deadline?, do: Process.put(@task_deadline, started_at + timeout)

        if restore_hooks? do
          Selecto.Performance.Hooks.restore_hooks(hook_snapshot)

          try do
            work.()
          after
            Selecto.Performance.Hooks.restore_hooks(%{})
          end
        else
          work.()
        end
      end)

    wait = if adapter_deadline?, do: timeout + @adapter_grace, else: timeout

    # Wait for task with timeout
    case Task.yield(task, wait) || Task.shutdown(task) do
      {:ok, result} ->
        if adapter_deadline? and System.monotonic_time(:millisecond) - started_at >= timeout,
          do: timeout_result(timeout, query_id, start_time),
          else: result

      {:exit, reason} ->
        exited_result(reason, query_id, start_time)

      nil ->
        # Task was killed due to timeout
        timeout_result(timeout, query_id, start_time)
    end
  end

  # Run the execution work in the calling process when the adapter enforces
  # the timeout itself (`supports?(:execute_timeout)`), so the result is not
  # copied out of a task. The outcome matches with_timeout_protection/5: work
  # that does not finish within the timeout yields the same timeout error
  # however it ends, an exit or throw the same connection error, and an
  # exception is raised again.
  defp with_adapter_timeout(opts, query_id, start_time, work) do
    timeout = effective_timeout(opts)
    started_at = System.monotonic_time(:millisecond)

    outcome =
      if timeout == 0 do
        :not_started
      else
        try do
          {:done, work.(started_at + timeout)}
        catch
          :exit, reason -> {:exited, reason}
          :throw, value -> {:exited, {{:nocatch, value}, __STACKTRACE__}}
          :error, reason -> {:raised, reason, __STACKTRACE__}
        end
      end

    # The deadline is a millisecond tick, and an adapter's timer can end the
    # work within that tick: reaching it counts as timing out.
    if outcome == :not_started or System.monotonic_time(:millisecond) - started_at >= timeout do
      timeout_result(timeout, query_id, start_time)
    else
      case outcome do
        {:done, result} -> result
        {:exited, reason} -> exited_result(reason, query_id, start_time)
        {:raised, reason, stacktrace} -> :erlang.raise(:error, reason, stacktrace)
      end
    end
  end

  defp run_in_caller?(selecto, opts, hook_snapshot) do
    !opts[:cache] and Selecto.Performance.Hooks.empty_snapshot?(hook_snapshot) and
      adapter_enforces_timeout?(runtime_adapter(selecto))
  end

  defp adapter_enforces_timeout?(adapter) do
    Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) and
      adapter.supports?(:execute_timeout) == true
  rescue
    _ -> false
  end

  defp exited_result({%_{} = error, stacktrace}, _query_id, _start_time)
       when is_list(stacktrace) do
    reraise error, stacktrace
  end

  defp exited_result(reason, query_id, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:selecto, :query, :error],
      %{count: 1},
      %{query_id: query_id, error_type: infer_error_type(reason), duration: duration}
    )

    {:error,
     Selecto.Error.connection_error(
       "Database execution process exited",
       Selecto.Error.exit_details(reason)
     )}
  end

  defp timeout_result(timeout, query_id, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    Logger.error("[Selecto] Query timeout after #{timeout}ms")

    # Emit timeout telemetry
    :telemetry.execute(
      [:selecto, :query, :timeout],
      %{duration: duration, timeout: timeout},
      %{query_id: query_id}
    )

    {:error,
     Selecto.Error.timeout_error(
       "Query exceeded timeout of #{timeout}ms",
       %{timeout: timeout, duration: duration}
     )}
  end

  @doc """
  Execute a query and return results with metadata including SQL, params, and execution time.

  ## Parameters

  - `selecto` - The Selecto struct containing connection and query info
  - `opts` - Execution options

  ## Returns

  - `{:ok, result, metadata}` - Successful execution with results and metadata
  - `{:error, error}` - Execution failure with detailed error

  The metadata map includes:
  - `:sql` - The generated SQL query string
  - `:params` - The query parameters
  - `:execution_time` - Query execution time in milliseconds

  As in `execute/2`, the query passes the complexity check
  (`analyze_complexity: false` skips it) and runs under the `:timeout`
  option (default 30 seconds, at most 5 minutes). The count and projection
  sum variants apply the same guards.

  ## Examples

      case Selecto.Executor.execute_with_metadata(selecto) do
        {:ok, {rows, columns, aliases}, _meta} ->
          # Process successful results with metadata
          handle_results(rows, columns, aliases)
        {:error, error} ->
          # Handle database error
          Logger.error("Query failed: \#{inspect(error)}")
      end
  """
  @spec execute_with_metadata(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          {:ok, Selecto.Types.execute_result(), map()} | {:error, Selecto.Error.t()}
  def execute_with_metadata(selecto, opts \\ [])

  def execute_with_metadata(%Selecto{provider: provider} = selecto, opts)
      when not is_nil(provider),
      do: Selecto.Configuration.Provider.invoke(selecto, :execute_with_metadata, [opts])

  def execute_with_metadata(selecto, opts) do
    Selecto.Telemetry.operation(:execute_with_metadata, selecto, fn ->
      do_execute_with_metadata(selecto, opts)
    end)
  end

  defp do_execute_with_metadata(selecto, opts) do
    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         {:ok, selecto} <- prepare_read(selecto) do
      guarded(selecto, opts, fn -> execute_with_metadata_work(selecto, opts) end)
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Selecto.Error.from_reason(reason)}
    end
  end

  defp execute_with_metadata_work(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)

    try do
      {query, aliases, params} = Selecto.gen_sql(selecto, opts)

      # Track the SQL and params for metadata
      sql_metadata = %{
        sql: query,
        params: params
      }

      # Handle different execution contexts: adapters, repos, or direct connections
      result =
        execute_for_context(selecto, query, params, aliases)

      # Calculate execution time
      duration = System.monotonic_time(:millisecond) - start_time

      # Apply output format transformation if specified and add metadata
      case result do
        {:ok, {rows, columns, aliases}} ->
          format = Keyword.get(opts, :format, :raw)
          format_options = Keyword.get(opts, :format_options, [])

          transformed_result =
            case Selecto.Telemetry.span([:transform], %{}, fn ->
                   Selecto.Output.Formats.transform(
                     {rows, columns, aliases},
                     format,
                     format_options
                   )
                 end) do
              {:ok, transformed} -> transformed
              {:error, _transform_error} -> {rows, columns, aliases}
            end

          metadata = Map.put(sql_metadata, :execution_time, duration)
          {:ok, transformed_result, metadata}

        error_result ->
          error_result
      end
    rescue
      error ->
        error_result = {:error, Selecto.Error.from_reason(error)}
        error_result
    catch
      :exit, reason ->
        error_result =
          {:error,
           Selecto.Error.connection_error(
             "Database connection failed",
             Selecto.Error.exit_details(reason)
           )}

        error_result
    end
  end

  @doc """
  Execute an exact count of the rows produced by an unpaginated Selecto query.

  The compiled query is wrapped as a derived table so Detail, Aggregate, and
  grouped queries all share the same count semantics. The returned metadata
  contains the wrapped SQL, bound parameters, and execution time.
  """
  @spec execute_count_with_metadata(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          {:ok, non_neg_integer(), map()} | {:error, Selecto.Error.t()}
  def execute_count_with_metadata(selecto, opts \\ [])

  def execute_count_with_metadata(%Selecto{provider: provider} = selecto, opts)
      when not is_nil(provider),
      do: Selecto.Configuration.Provider.invoke(selecto, :execute_count_with_metadata, [opts])

  def execute_count_with_metadata(selecto, opts) do
    Selecto.Telemetry.operation(:count, selecto, fn ->
      do_execute_count_with_metadata(selecto, opts)
    end)
  end

  @doc """
  Execute one database-side sum over a named numeric projection of a governed
  Selecto query. The input query retains its own filters and pagination. This
  is intended for totals over per-root correlated contributions; no root rows
  are returned to the caller. Adapters must advertise `:projection_sum`.
  """
  @spec execute_projection_sum_with_metadata(
          Selecto.Types.t(),
          binary(),
          Selecto.Types.execute_options()
        ) :: {:ok, term(), map()} | {:error, Selecto.Error.t()}
  def execute_projection_sum_with_metadata(selecto, column, opts \\ [])

  def execute_projection_sum_with_metadata(%Selecto{provider: provider} = selecto, column, opts)
      when not is_nil(provider),
      do:
        Selecto.Configuration.Provider.invoke(selecto, :execute_projection_sum_with_metadata, [
          column,
          opts
        ])

  def execute_projection_sum_with_metadata(selecto, column, opts) do
    Selecto.Telemetry.operation(:projection_sum, selecto, fn ->
      do_execute_projection_sum_with_metadata(selecto, column, opts)
    end)
  end

  defp do_execute_projection_sum_with_metadata(selecto, column, opts) do
    adapter = runtime_adapter(selecto)

    cond do
      not is_binary(column) or not String.match?(column, ~r/\A[A-Za-z][A-Za-z0-9_]*\z/) ->
        {:error, Selecto.Error.query_error("Projection sum column is invalid", "", [], %{})}

      not Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) or
        not adapter.supports?(:projection_sum) or
          not Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) ->
        {:error, Selecto.Error.query_error("Projection sum is unavailable", "", [], %{})}

      true ->
        execute_projection_sum_query(selecto, adapter, column, opts)
    end
  end

  defp execute_projection_sum_query(selecto, adapter, column, opts) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         {:ok, selecto} <- prepare_read(selecto) do
      guarded(selecto, opts, fn ->
        try do
          {query, aliases, params} = derived_source_sql(selecto, opts)

          subselect_aliases =
            Enum.map(Map.get(selecto.set, :subselected, []), fn config ->
              Map.get(config, :alias)
            end)

          source_column =
            case Enum.find_index(aliases, &(is_binary(&1) and &1 == column)) do
              nil ->
                if Enum.any?(subselect_aliases, &(is_binary(&1) and &1 == column)),
                  do: column

              index ->
                Selecto.Builder.Sql.projection_alias(index + 1)
            end

          if source_column do
            quoted_column = adapter.quote_identifier(source_column)

            sum_query =
              "SELECT COALESCE(SUM(selecto_projection_source.#{quoted_column}), 0) " <>
                "AS selecto_projection_sum FROM (" <>
                String.trim_trailing(query, ";") <> ") AS selecto_projection_source"

            result = execute_for_context(selecto, sum_query, params, ["selecto_projection_sum"])
            duration = System.monotonic_time(:millisecond) - start_time
            metadata = %{sql: sum_query, params: params, execution_time: duration}

            case result do
              {:ok, {[[value]], _columns, _aliases}} when not is_nil(value) ->
                {:ok, value, metadata}

              {:ok, _other} ->
                {:error, Selecto.Error.query_error("Projection sum returned an invalid result")}

              error ->
                error
            end
          else
            {:error, Selecto.Error.query_error("Projection sum column is not selected")}
          end
        rescue
          error -> {:error, Selecto.Error.from_reason(error)}
        catch
          :exit, reason ->
            {:error,
             Selecto.Error.connection_error(
               "Database projection sum execution failed",
               Selecto.Error.exit_details(reason)
             )}
        end
      end)
    end
  end

  # Compile the governed query for use as a COUNT or SUM derived table. Every
  # selected column gets a unique positional alias because MySQL, MariaDB and
  # SQL Server reject derived tables whose columns share a name (for example
  # `name` and `category.name`) or have no name. Aliases never change rows.
  defp derived_source_sql(selecto, opts) do
    Selecto.gen_sql(
      unordered_source(selecto),
      Keyword.put(opts, :unique_projection_aliases, true)
    )
  end

  # A derived table used only for COUNT or SUM does not need its ORDER BY,
  # and SQL Server rejects ORDER BY in a derived table without TOP/OFFSET.
  # Keep the ordering when LIMIT/OFFSET select which rows are aggregated.
  defp unordered_source(%{set: set} = selecto) when is_map(set) do
    if is_nil(Map.get(set, :limit)) and is_nil(Map.get(set, :offset)) and
         Map.has_key?(set, :order_by) do
      put_in(selecto.set.order_by, [])
    else
      selecto
    end
  end

  defp unordered_source(selecto), do: selecto

  defp do_execute_count_with_metadata(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         {:ok, selecto} <- prepare_read(selecto) do
      guarded(selecto, opts, fn ->
        try do
          {query, _aliases, params} = derived_source_sql(selecto, opts)

          count_query =
            "SELECT COUNT(*) AS selecto_total_count FROM (" <>
              String.trim_trailing(query, ";") <> ") AS selecto_count_source"

          result = execute_for_context(selecto, count_query, params, ["selecto_total_count"])
          duration = System.monotonic_time(:millisecond) - start_time
          metadata = %{sql: count_query, params: params, execution_time: duration}

          case result do
            {:ok, {[[count]], _columns, _aliases}} when is_integer(count) and count >= 0 ->
              {:ok, count, metadata}

            {:ok, _other} ->
              {:error, Selecto.Error.query_error("Count query returned an invalid result")}

            error ->
              error
          end
        rescue
          error -> {:error, Selecto.Error.from_reason(error)}
        catch
          :exit, reason ->
            {:error,
             Selecto.Error.connection_error(
               "Database count execution failed",
               Selecto.Error.exit_details(reason)
             )}
        end
      end)
    else
      {:error, %Selecto.Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Selecto.Error.from_reason(reason)}
    end
  end

  @doc """
  Execute a query as a stream of `{row, columns, aliases}` tuples.

  Streaming is available only when the configured adapter advertises stream
  support and implements `stream/4`. The query passes the complexity check
  before the stream opens; row delivery is bounded by the adapter's stream
  options, not by `:timeout`.
  """
  @spec execute_stream(Selecto.Types.t(), keyword()) :: Selecto.Types.safe_execute_stream_result()
  def execute_stream(selecto, opts \\ [])

  def execute_stream(%Selecto{provider: provider} = selecto, opts) when not is_nil(provider),
    do: Selecto.Configuration.Provider.invoke(selecto, :execute_stream, [opts])

  def execute_stream(selecto, opts) do
    Selecto.Telemetry.operation(:stream_open, selecto, fn -> do_execute_stream(selecto, opts) end)
  end

  # A stream is checked for complexity before it opens. Its rows are read
  # lazily by the caller, so the task timeout of execute/2 cannot bound it;
  # adapters bound row delivery (for example `:receive_timeout`).
  defp do_execute_stream(selecto, opts) do
    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         {:ok, selecto} <- prepare_read(selecto),
         :ok <- check_query_complexity(selecto, opts, query_id()) do
      try do
        stream_sql_opts =
          Keyword.drop(opts, [
            :max_rows,
            :receive_timeout,
            :queue_timeout,
            :stream_timeout,
            :stream_producer
          ])

        {query, aliases, params} = Selecto.gen_sql(selecto, stream_sql_opts)

        case execute_stream_for_context(selecto, query, params, aliases, opts) do
          {:ok, stream} -> {:ok, Selecto.Telemetry.Stream.wrap(stream)}
          {:error, error} -> {:error, error}
        end
      rescue
        error ->
          {:error, Selecto.Error.from_reason(error)}
      catch
        :exit, reason ->
          {:error,
           Selecto.Error.connection_error(
             "Database stream execution failed",
             Selecto.Error.exit_details(reason)
           )}
      end
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Selecto.Error.from_reason(reason)}
    end
  end

  @doc """
  Execute a query expecting exactly one row, returning {:ok, row} or {:error, reason}.

  Useful for queries that should return a single record (e.g., with LIMIT 1 or aggregate functions).
  Returns an error if zero rows or multiple rows are returned.

  ## Examples

      case Selecto.Executor.execute_one(selecto) do
        {:ok, row} ->
          # Handle single row result
          process_single_result(row)
        {:error, :no_results} ->
          # Handle case where no rows were found
        {:error, :multiple_results} ->
          # Handle case where multiple rows were found
        {:error, error} ->
          # Handle database or other errors
      end
  """
  @spec execute_one(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          Selecto.Types.safe_execute_one_result()
  def execute_one(selecto, opts \\ []) do
    Selecto.Telemetry.operation(:execute_one, selecto, fn -> do_execute_one(selecto, opts) end)
  end

  defp do_execute_one(selecto, opts) do
    case do_execute(selecto, opts) do
      {:ok, {[], _columns, _aliases}} ->
        {:error, Selecto.Error.no_results_error()}

      {:ok, {[single_row], _columns, aliases}} ->
        {:ok, {single_row, aliases}}

      {:ok, {_multiple_rows, _columns, _aliases}} ->
        {:error, Selecto.Error.multiple_results_error()}

      {:error, %Selecto.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Execute query using a database adapter.

  This function delegates to the adapter's execute/4 function, allowing
  for different database types like SQLite, MySQL, etc.

  Adapter and driver failures are returned as `Selecto.Error.from_driver/2`
  errors: they never carry the SQL, parameters, connection, or the
  database's own message and detail.
  """
  def execute_with_adapter(adapter, connection, query, params, aliases, opts \\ []) do
    try do
      execution_port =
        if function_exported?(adapter, :execute_query, 4), do: :execute_query, else: :execute

      case apply(adapter, execution_port, [connection, query, params, opts]) do
        {:ok, result} ->
          case Selecto.AdapterSupport.normalize_result(adapter, result) do
            {:ok, normalized} ->
              {:ok, {Map.get(normalized, :rows, []), Map.get(normalized, :columns, []), aliases}}

            {:error, reason} ->
              {:error, driver_error(adapter, reason)}
          end

        {:error, reason} ->
          {:error, driver_error(adapter, reason)}
      end
    rescue
      error ->
        {:error,
         Selecto.Error.connection_error("Adapter execution failed", %{
           adapter: adapter,
           reason: Selecto.Error.reason_kind(error)
         })}
    catch
      :exit, reason ->
        {:error,
         Selecto.Error.connection_error(
           "Adapter connection failed",
           Map.put(Selecto.Error.exit_details(reason), :adapter, adapter)
         )}
    end
  end

  defp driver_error(adapter, reason),
    do: Selecto.Error.from_driver(reason, Selecto.AdapterSupport.normalize_error(adapter, reason))

  @doc """
  Execute query using connection pool.
  """
  def execute_with_connection_pool(pool_ref, query, params, aliases) do
    case Selecto.ConnectionPool.execute(pool_ref, query, params, prepared: true) do
      {:ok, result} ->
        rows = Map.get(result, :rows, [])
        columns = Map.get(result, :columns, [])
        {:ok, {rows, columns, aliases}}

      {:error, reason} ->
        {:error, Selecto.Error.from_driver(reason, Selecto.Error.from_reason(reason))}
    end
  end

  @doc """
  Validate connection before executing query.

  Returns `:ok` if connection is valid, `{:error, reason}` otherwise.
  """
  def validate_connection(selecto) do
    adapter = runtime_adapter(selecto)
    connection = runtime_connection(selecto)

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :validate_connection, 1) ->
        Kernel.apply(adapter, :validate_connection, [connection])

      true ->
        {:error, "Invalid connection configuration"}
    end
  end

  @doc """
  Get connection statistics for monitoring.

  Returns information about the current connection state.
  """
  def connection_info(selecto) do
    adapter = runtime_adapter(selecto)
    connection = runtime_connection(selecto)

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :connection_info, 1) ->
        Kernel.apply(adapter, :connection_info, [connection])

      true ->
        %{
          type: :unknown,
          value: connection,
          status: :invalid
        }
    end
  end

  defp runtime_connection(selecto), do: Selecto.Runtime.Context.connection(selecto)
  defp runtime_adapter(selecto), do: Selecto.Runtime.Context.adapter(selecto)

  # `deadline` (monotonic milliseconds) is set when the adapter enforces the
  # timeout itself; it then receives the time remaining as `:timeout`.
  defp execute_with_hooks(selecto, hook_options, query_id, start_time, deadline) do
    Selecto.Performance.Hooks.with_hooks(
      selecto,
      fn _selecto, sql, params, context ->
        aliases = Map.get(context, :aliases, [])

        result =
          :telemetry.span(@query_execution_event, %{query_id: query_id}, fn ->
            result =
              execute_for_context(selecto, sql, params, aliases, deadline_options(deadline))

            duration = System.monotonic_time(:millisecond) - start_time

            stop_metadata =
              telemetry_stop_metadata(result, query_id)
              |> Map.put(:execution_time, duration)

            {result, stop_metadata}
          end)

        result
      end,
      hook_options
    )
  end

  defp task_deadline_options(adapter_opts) do
    case Process.get(@task_deadline) do
      nil -> adapter_opts
      deadline -> Keyword.merge(deadline_options(deadline), adapter_opts)
    end
  end

  defp deadline_options(nil), do: []

  defp deadline_options(deadline),
    do: [timeout: max(deadline - System.monotonic_time(:millisecond), 1)]

  defp hook_options(opts) do
    [
      cache: Keyword.get(opts, :cache, false),
      cache_ttl: Keyword.get(opts, :cache_ttl),
      cache_namespace: Keyword.get(opts, :cache_namespace),
      include_aliases: true,
      gen_sql_opts:
        Keyword.drop(opts, [
          :timeout,
          :analyze_complexity,
          :format,
          :format_options,
          :cache,
          :cache_ttl,
          :cache_namespace
        ])
    ]
  end

  defp execute_for_context(selecto, query, params, aliases, adapter_opts \\ []) do
    adapter = runtime_adapter(selecto)
    adapter_opts = task_deadline_options(adapter_opts)

    Selecto.Telemetry.span([:adapter], %{adapter: adapter}, fn ->
      execute_with_adapter(
        adapter,
        runtime_connection(selecto),
        query,
        params,
        aliases,
        read_opts(selecto, adapter_opts)
      )
    end)
  end

  defp execute_stream_for_context(selecto, query, params, aliases, opts) do
    execute_with_adapter_stream(
      runtime_adapter(selecto),
      runtime_connection(selecto),
      query,
      params,
      aliases,
      read_opts(selecto, opts)
    )
  end

  defp execute_with_adapter_stream(adapter, connection, query, params, aliases, opts) do
    cond do
      not adapter_supports_stream?(adapter) ->
        {:error,
         Selecto.Error.validation_error(
           "Streaming requires adapter.supports?(:stream) capability",
           %{
             adapter: adapter,
             stream_context: :adapter,
             adapter_contract: :supports_stream,
             unsupported_feature: :stream
           }
         )}

      not Selecto.AdapterSupport.callback_available?(adapter, :stream, 4) ->
        {:error,
         Selecto.Error.validation_error(
           "Adapter declares stream support but does not implement stream/4",
           %{adapter: adapter, stream_context: :adapter, adapter_contract: :stream_callback}
         )}

      true ->
        try do
          case adapter.stream(connection, query, params, opts) do
            {:ok, stream, columns} ->
              {:ok, Stream.map(stream, &{&1, List.wrap(columns), aliases})}

            {:ok, stream} ->
              {:ok, Stream.map(stream, &{&1, [], aliases})}

            {:error, {:invalid_stream_pool, details}} ->
              {:error,
               Selecto.Error.validation_error(
                 "Streaming requires a valid adapter pool connection reference",
                 details
               )}

            {:error, {:invalid_connection, _connection}} ->
              {:error,
               Selecto.Error.validation_error(
                 "Streaming requires adapter stream support for this connection",
                 %{adapter: adapter}
               )}

            {:error, reason} ->
              {:error, driver_error(adapter, reason)}
          end
        rescue
          FunctionClauseError ->
            {:error,
             Selecto.Error.validation_error(
               "Streaming requires adapter stream support for this connection",
               %{adapter: adapter}
             )}

          UndefinedFunctionError ->
            {:error,
             Selecto.Error.validation_error(
               "Adapter stream callback is unavailable",
               %{adapter: adapter, stream_context: :adapter, adapter_contract: :stream_callback}
             )}
        end
    end
  end

  defp adapter_supports_stream?(adapter) do
    Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) and
      adapter.supports?(:stream)
  rescue
    _ -> false
  end

  defp result_row_count({:ok, {rows, _columns, _aliases}}) when is_list(rows), do: length(rows)
  defp result_row_count(_), do: 0

  defp telemetry_stop_metadata(result, query_id) do
    %{
      query_id: query_id,
      row_count: result_row_count(result),
      status: telemetry_result_status(result)
    }
    |> maybe_put_error_type(result)
  end

  defp telemetry_result_status({:ok, _result}), do: :ok
  defp telemetry_result_status({:error, _reason}), do: :error
  defp telemetry_result_status(_), do: :unknown

  defp maybe_put_error_type(metadata, {:error, %Selecto.Error{type: type}}),
    do: Map.put(metadata, :error_type, type)

  defp maybe_put_error_type(metadata, {:error, reason}),
    do: Map.put(metadata, :error_type, infer_error_type(reason))

  defp maybe_put_error_type(metadata, _), do: metadata

  defp infer_error_type(reason) when is_exception(reason), do: reason.__struct__
  defp infer_error_type(reason) when is_atom(reason), do: reason
  defp infer_error_type(_reason), do: :unknown
end
