defmodule Selecto.Builder.ExactCompare do
  @moduledoc false

  # Tenant and site identity must compare exactly. MySQL and MariaDB compare
  # text under the column's collation: under the default ones (
  # utf8mb4_0900_ai_ci, utf8mb4_uca1400_ai_ci, *_general_ci, *_unicode_ci) a
  # tenant column matches case- and accent-insensitively, and under PAD SPACE
  # collations it ignores trailing spaces, so tenant 't1' would read and pair
  # rows of 'T1' and 't1 '. PostgreSQL and SQLite compare exactly.
  #
  # Adapters declaring `:exact_tenant_compare` (MySQL, MariaDB) get every
  # tenant/site comparison as
  #
  #     (<col> = ? AND CAST(CONVERT(<col> USING utf8mb4) AS BINARY) = CAST(? AS BINARY))
  #
  # which keeps the column's index usable and decides on the stored bytes.
  # Every other adapter gets the plain comparison, byte-identical to before.
  #
  # A column takes the exact form when its name is a tenant or site column the
  # domain declares (the root's tenant_field, its writes.scope tenant field,
  # its tenant_columns, and every schema's tenant_field), unless every
  # declaration of that name in the domain gives it a type that compares
  # exactly already (integer, decimal, boolean, temporal, binary). A column
  # whose type is not declared takes the exact form: it is correct for numbers
  # too.
  #
  # The form is a mode: `true` converts the column to utf8mb4 before taking
  # its bytes (text, of any character set); `:bytes` takes the stored bytes
  # as they are. UUID types (:uuid, :binary_id) get `:bytes`: stored as
  # BINARY(16) the bytes are the value (CONVERT would mangle them), stored as
  # CHAR(36) text they are its ASCII bytes, so 'A0EE...' and a trailing-space
  # 'a0ee... ' never equal 'a0ee...'. `false` is the plain comparison.

  alias Selecto.AdapterSupport

  @feature :exact_tenant_compare

  # Three-way type classification (ADDENDUM 6), on the normalised type name
  # (lowercased, trimmed, without a `(...)` suffix or charset/collate clause):
  # known text compares by converted bytes, known non-text keeps the plain
  # comparison, and everything else (undeclared, uuid, custom names) is
  # guarded: the server decides by the column's collation.
  # Known text names, normalised (spaces become underscores). Only these are
  # exact: a custom name that merely contains "char" or "text" (charge_amount,
  # context_ts) is guarded, since it may name a numeric or temporal column.
  @text_types ~w(string text tinytext mediumtext longtext char character nchar
                 national_char national_character varchar char_varying character_varying
                 nvarchar national_varchar national_char_varying national_character_varying
                 nchar_varying citext clob enum set bpchar)
  @non_text_types ~w(id integer bigint smallint tinyint mediumint serial bigserial int
                     float double real decimal numeric money boolean bool date time time_usec
                     datetime naive_datetime naive_datetime_usec utc_datetime
                     utc_datetime_usec timestamp timestamptz epoch_datetime json jsonb map
                     binary bytes blob bytea varbinary)

  # Zone-independent TIMESTAMP identity (brief item 62a). MySQL stores a
  # TIMESTAMP as UTC but compares it in the session's time_zone, and a stored
  # function a view calls can switch time_zone mid-statement and back, so a
  # host `ts < '2024-01-01 00:00:00'` would admit an out-of-scope row while
  # the session looks unchanged before and after. An adapter that loads the
  # storage types of the domain's relations before a read
  # (`prepare_read/2`, MySQL and MariaDB) puts them in
  # `selecto.set.storage_column_types` (lower-cased column name => data
  # types); a host, trusted, required or tenant comparison, or an association
  # `where` pin, on a column stored as TIMESTAMP then compiles as
  # `UNIX_TIMESTAMP(col) <op> <epoch computed here>` (UTC, which the session
  # check requires before every statement). A declared temporal column the
  # lookup did not resolve is refused. Without loaded types (compile-only
  # contexts, other adapters) nothing changes.

  @temporal_types ~w(date datetime naive_datetime naive_datetime_usec utc_datetime
                     utc_datetime_usec timestamp timestamptz epoch_datetime)

  @scope_key {__MODULE__, :scope}
  @storage_context {__MODULE__, :storage}

  @doc false
  # Compiles `fun` as scope (a required, trusted, engine, evidence or member
  # filter, by provenance).
  def in_scope(fun) do
    previous = Process.get(@scope_key)
    Process.put(@scope_key, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
    end
  end

  @doc false
  def in_scope?, do: Process.get(@scope_key) == true

  @doc false
  # The storage types of the read being compiled, for nested compiles
  # (query members, set operands) whose own selecto does not carry them.
  def with_storage_context(selecto, fun) do
    storage =
      Map.take(Map.get(selecto, :set) || %{}, Selecto.Builder.SetOperations.storage_keys())

    if map_size(storage) == 0 or Process.get(@storage_context) do
      fun.()
    else
      Process.put(@storage_context, storage)

      try do
        fun.()
      after
        Process.delete(@storage_context)
      end
    end
  end

  defp storage_set(selecto) do
    set = Map.get(selecto, :set) || %{}

    if Map.has_key?(set, :storage_column_types),
      do: set,
      else: Map.merge(set, Process.get(@storage_context) || %{})
  end

  @doc false
  # How a scope comparison on `column` of `table` must compile, from the
  # storage types an adapter loaded before the read (prepare_read/2), keyed
  # by relation and column (R18): a same-named column of another relation
  # never decides.
  #
  # - nil: no storage types were loaded (compile-only contexts, adapters
  #   without the hook); everything compiles as before;
  # - DuckDB (`identity_text_bytes`): :duck_text for a VARCHAR column (its
  #   UTF-8 bytes, under every operator), else :plain (native);
  # - MySQL-family (`zone_independent_timestamps`): :timestamp for a column
  #   stored as TIMESTAMP (epoch compares, item 62a), :mysql_text for one
  #   stored as character data (utf8mb4 bytes, R3, R16, R26), :plain for any
  #   other storage. A column the lookup did not resolve is :mysql_text when
  #   declared text, :plain when declared a known non-temporal type, and
  #   :unresolved (refused) when declared temporal or of an unknown type.
  def storage_kind(selecto, table, column, declared_type \\ nil)

  def storage_kind(selecto, table, column, declared_type) when is_map(selecto) do
    case storage_set(selecto) do
      %{storage_column_types: types} = set when is_map(types) ->
        storage_kind_in(set, types, table, column, declared_type)

      _ ->
        nil
    end
  end

  def storage_kind(_selecto, _table, _column, _declared_type), do: nil

  defp storage_kind_in(set, types, table, column, declared_type) do
    found =
      with table when not is_nil(table) <- table,
           {:ok, columns} <- Map.fetch(types, to_string(table)),
           {:ok, column_types} <- Map.fetch(columns, storage_key(column)) do
        {:ok, column_types}
      else
        _ -> :error
      end

    cond do
      Map.get(set, :identity_text_bytes) == true ->
        case found do
          {:ok, column_types} ->
            if Enum.any?(column_types, &String.starts_with?(&1, "varchar")),
              do: :duck_text,
              else: :plain

          :error ->
            :plain
        end

      Map.get(set, :zone_independent_timestamps) == true ->
        case found do
          {:ok, column_types} -> mysql_kind(column_types)
          :error -> unresolved_kind(declared_type)
        end

      true ->
        nil
    end
  end

  @doc false
  # R3 clarification 2: refuses a literal a scope comparison binds against
  # a non-text storage type that cannot represent it exactly (the native
  # cast would round it). Integer families take integers and canonical
  # integer strings; DECIMAL(p,s) takes integers, Decimals and decimal
  # strings with at most s fractional digits. Floats against either are
  # refused. Other types, and compiles without loaded types, are unchanged.
  def exact_literals!(selecto, table, column, values) do
    case storage_types(selecto, table, column) do
      {:ok, types} ->
        Enum.each(types, fn type ->
          case numeric_kind(type) do
            nil ->
              :ok

            kind ->
              Enum.each(List.wrap(values), fn value ->
                unless exact_literal?(kind, value),
                  do:
                    refuse(
                      :identity_value,
                      "a scope literal is not exactly representable in the column's #{type} storage"
                    )
              end)
          end
        end)

      :error ->
        :ok
    end
  end

  defp storage_types(selecto, table, column) when is_map(selecto) and not is_nil(table) do
    with %{storage_column_types: types} = set when is_map(types) <- storage_set(selecto),
         true <-
           Map.get(set, :identity_text_bytes) == true or
             Map.get(set, :zone_independent_timestamps) == true,
         {:ok, columns} <- Map.fetch(types, to_string(table)),
         {:ok, column_types} <- Map.fetch(columns, storage_key(column)) do
      {:ok, column_types}
    else
      _ -> :error
    end
  end

  defp storage_types(_selecto, _table, _column), do: :error

  @integer_type ~r/\A(u?(tiny|small|medium|big|huge)?int(eger)?\d*|int\d+|serial|bigserial)( unsigned)?\z/
  @decimal_type ~r/\A(decimal|numeric)(\((\d+)\s*,\s*(\d+)\))?( unsigned)?\z/

  defp numeric_kind(type) do
    cond do
      Regex.match?(@integer_type, type) ->
        :integer

      match = Regex.run(@decimal_type, type) ->
        case match do
          [_, _, _, _precision, scale | _] -> {:decimal, String.to_integer(scale)}
          # DECIMAL without a scale: MySQL's is 0, DuckDB's 3; the smaller
          # one fails closed.
          _ -> {:decimal, 0}
        end

      true ->
        nil
    end
  end

  defp exact_literal?(_kind, nil), do: true
  defp exact_literal?(_kind, value) when is_integer(value), do: true
  defp exact_literal?(:integer, value) when is_boolean(value), do: true

  defp exact_literal?(:integer, %Decimal{} = value),
    do: Decimal.integer?(value)

  defp exact_literal?(:integer, value) when is_binary(value),
    do: Regex.match?(~r/\A(0|-?[1-9][0-9]*)\z/, value)

  # Text must be plain decimal notation of an exact value (R3c2): no
  # exponent ('1e0', '1.01e0'), no leading zeros, no '-0', at most s
  # fractional digits for DECIMAL(p,s) ('1.005' refuses for DECIMAL(10,2);
  # '10' and '1.01' are exact and accepted).
  defp exact_literal?({:decimal, scale}, value) when is_binary(value) do
    case Regex.run(~r/\A-?(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/, value) do
      [_, _] ->
        not String.starts_with?(value, "-0")

      [_, _, fraction] ->
        byte_size(fraction) <= scale and not Regex.match?(~r/\A-0(\.0+)?\z/, value)

      nil ->
        false
    end
  end

  defp exact_literal?({:decimal, scale}, %Decimal{} = value) do
    Decimal.inf?(value) == false and Decimal.nan?(value) == false and
      -Decimal.normalize(value).exp <= scale
  end

  defp exact_literal?(_kind, _value), do: false

  @mysql_text_types ~w(char varchar tinytext text mediumtext longtext enum set)

  defp mysql_kind(column_types) do
    cond do
      Enum.all?(column_types, &(&1 == "timestamp")) -> :timestamp
      Enum.all?(column_types, &(&1 in @mysql_text_types)) -> :mysql_text
      Enum.any?(column_types, &(&1 == "timestamp" or &1 in @mysql_text_types)) -> :unresolved
      true -> :plain
    end
  end

  defp unresolved_kind(declared_type) do
    cond do
      zone_type_name(declared_type) in @temporal_types -> :unresolved
      declared_type == nil -> :unresolved
      type_class(declared_type) == :text -> :mysql_text
      type_class(declared_type) == :non_text -> :plain
      true -> :unresolved
    end
  end

  @doc false
  # Whether a computed value reads a TIMESTAMP-stored column as a value
  # (outside CASE conditions), directly or through other computed columns;
  # an unresolved column counts (fails closed). R15.
  def computed_reads_timestamp?(selecto, expression, visited \\ MapSet.new()) do
    expression =
      case Selecto.Domain.Contract.ComputedValues.normalize(expression) do
        {:ok, normalized} -> normalized
        _ -> expression
      end

    {_conditions, fields} = value_parts(expression)

    Enum.any?(fields, fn field ->
      conf =
        try do
          Selecto.field(selecto, field)
        rescue
          _ -> nil
        end

      cond do
        MapSet.member?(visited, field) ->
          false

        match?(%{select: {:computed_value, _}}, conf) ->
          {:computed_value, inner} = conf.select
          computed_reads_timestamp?(selecto, inner, MapSet.put(visited, field))

        is_map(conf) ->
          storage_kind(
            selecto,
            field_relation(selecto, conf),
            Map.get(conf, :field) || field,
            Map.get(conf, :type)
          ) in [:timestamp, :unresolved]

        true ->
          storage_kind(selecto, nil, field, nil) in [:timestamp, :unresolved]
      end
    end)
  end

  @doc false
  def declared_type_of(relation, field), do: declared_type(relation, field)

  @doc false
  # The storage map key of a column name (case-insensitive in every
  # backend); relations are keyed exactly as the domain names them (R31).
  def storage_key(name), do: name |> to_string() |> String.downcase()

  @doc false
  # The relation a field reads: the root's source table, or the source
  # table of the join it requires.
  def field_relation(selecto, conf) when is_map(conf) do
    join = Map.get(conf, :source_join) || Map.get(conf, :requires_join)
    config = Map.get(selecto, :config) || %{}

    case join do
      root when root in [nil, :selecto_root] ->
        get(Map.get(selecto, :domain) || %{}, :source) |> relation_table()

      join ->
        case config |> Map.get(:joins, %{}) |> Map.get(join) do
          %{source: source} when is_binary(source) or is_atom(source) -> to_string(source)
          _ -> nil
        end
    end
  end

  def field_relation(selecto, _conf),
    do: get(Map.get(selecto, :domain) || %{}, :source) |> relation_table()

  @doc false
  def relation_table(relation) when is_map(relation) do
    case get(relation, :source_table) do
      nil -> nil
      table -> to_string(table)
    end
  end

  def relation_table(_relation), do: nil

  @doc false
  # Whether a host, trusted, required or engine predicate names `field`
  # under ANY operator (ranges included): the comparisons that must not move
  # with the session's time_zone.
  def host_scope_field?(selecto, field) when is_binary(field),
    do: field in host_scope_fields(selecto)

  def host_scope_field?(_selecto, _field), do: false

  @doc false
  # Every field a host, trusted, required or engine predicate names, under
  # any operator.
  # The columns a host-named computed column reads count too: its predicate
  # body and CASE conditions decide which rows the host admits (R7).
  def host_scope_fields(selecto) do
    filters = host_scope_filters(selecto)

    Enum.flat_map(filters, &scope_fields/1) ++
      computed_body_fields(selecto, filters, &scope_fields/1)
  end

  @doc false
  # The host, trusted, required and engine predicates of a query.
  def host_scope_filters(selecto) do
    set = Map.get(selecto, :set) || %{}
    domain = Map.get(selecto, :domain) || %{}
    context = Map.get(selecto, :tenant) || %{}

    List.wrap(get(domain, :required_filters)) ++
      List.wrap(Map.get(set, :required_filters)) ++
      List.wrap(get(context, :required_filters)) ++
      List.wrap(Map.get(set, :host_filtered)) ++ Selecto.Tenant.engine_filters(selecto)
  end

  @doc false
  def bytes_compare(column, operator, value),
    do: [
      " encode(",
      column,
      ") ",
      operator,
      " encode(CAST(",
      {:param, value},
      " AS VARCHAR)) "
    ]

  defp scope_fields({conj, filters}) when conj in [:and, :or] and is_list(filters),
    do: Enum.flat_map(filters, &scope_fields/1)

  defp scope_fields({:not, filter}), do: scope_fields(filter)

  defp scope_fields({field, _value})
       when is_binary(field) or (is_atom(field) and not is_nil(field)),
       do: [to_string(field)]

  defp scope_fields({field, _op, _value})
       when is_binary(field) or (is_atom(field) and not is_nil(field)),
       do: [to_string(field)]

  defp scope_fields(_filter), do: []

  @doc false
  # An exact, zone-independent comparison of a TIMESTAMP column (item 62a,
  # R5 revised):
  #
  #     CASE WHEN <col> = 0 THEN <col> <op> ? ELSE UNIX_TIMESTAMP(<col>) <op> <epoch> END
  #
  # A stored TIMESTAMP is UTC, so its epoch does not move with the session's
  # time_zone; the epoch of the bound value is computed here as UTC (the
  # session check requires UTC before every statement). A zero date
  # ('0000-00-00 00:00:00' is 0 in every zone) keeps the server's native
  # comparison, and NULL stays NULL. The expression is exact on its own, so
  # it stays exact under NOT, CASE ... ELSE, coalesce, <> and `= false`
  # (R7): no polarity needs tracking.
  def unix_compare(column, operator, value) do
    case epoch(value) do
      {:ok, epoch} ->
        [
          " (CASE WHEN ",
          column,
          " = 0 THEN ",
          column,
          " ",
          operator,
          " ",
          {:param, value},
          " ELSE UNIX_TIMESTAMP(",
          column,
          ") ",
          operator,
          " ",
          {:param, epoch},
          " END) "
        ]

      :error ->
        refuse(
          :timestamp_value,
          "a scope comparison on a TIMESTAMP column needs a date or time value"
        )
    end
  end

  @doc false
  def refuse(reason, message),
    do: raise(Selecto.Builder.ScopeRefusal, message: message, reason: reason)

  @doc false
  def binary_compare(column, operator, value),
    do: [
      " CAST(CONVERT(",
      column,
      " USING utf8mb4) AS BINARY) ",
      operator,
      " CAST(",
      {:param, value},
      " AS BINARY) "
    ]

  @doc false
  def binary_like(column, operator, pattern, escape),
    do: [
      " CAST(CONVERT(",
      column,
      " USING utf8mb4) AS BINARY) ",
      operator,
      " CAST(",
      {:param, pattern},
      " AS BINARY)",
      escape,
      " "
    ]

  @doc false
  # The UNIX epoch of a temporal value read as UTC: an integer for whole
  # seconds, else a Decimal with microseconds.
  def epoch(%DateTime{} = value), do: {:ok, micro_epoch(DateTime.to_unix(value, :microsecond))}

  def epoch(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> epoch()

  def epoch(%Date{} = value), do: value |> NaiveDateTime.new!(~T[00:00:00]) |> epoch()

  def epoch(value) when is_binary(value) do
    text = String.trim(value)

    with {:error, _} <- datetime(text),
         {:error, _} <- NaiveDateTime.from_iso8601(text),
         {:error, _} <- Date.from_iso8601(text) do
      :error
    else
      {:ok, parsed} -> epoch(parsed)
    end
  end

  def epoch(_value), do: :error

  defp datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      error -> error
    end
  end

  defp micro_epoch(microseconds) do
    if rem(microseconds, 1_000_000) == 0,
      do: div(microseconds, 1_000_000),
      else: Decimal.div(Decimal.new(microseconds), Decimal.new(1_000_000))
  end

  defp zone_type_name(nil), do: nil

  defp zone_type_name(type) when is_atom(type) or is_binary(type),
    do: type |> to_string() |> String.downcase() |> String.trim()

  defp zone_type_name(_type), do: nil

  @doc false
  def enabled?(%{adapter: adapter}) when is_atom(adapter) and not is_nil(adapter),
    do: AdapterSupport.supports_feature?(adapter, @feature)

  def enabled?(_selecto), do: false

  @doc false
  # The mode a column named `name` takes on this query (false when plain).
  def column?(selecto, name) when is_atom(name) and not is_nil(name),
    do: column?(selecto, Atom.to_string(name))

  def column?(selecto, name) when is_binary(name) do
    enabled?(selecto) and exact_name?(Map.get(selecto, :domain), name)
  end

  def column?(_selecto, _name), do: false

  @doc false
  # The mode of a tenant/site column named `name` of `domain`, by its declared
  # types (false when it is not a tenant/site column or compares exactly).
  def exact_name?(domain, name) when is_map(domain) and is_binary(name) do
    name in tenant_names(domain) and name_mode(domain, name)
  end

  def exact_name?(_domain, _name), do: false

  @doc false
  # Whether `name` is a tenant or site column the domain declares, whatever
  # its type.
  def tenant_name?(domain, name) when is_map(domain) and (is_binary(name) or is_atom(name)),
    do: to_string(name) in tenant_names(domain)

  def tenant_name?(_domain, _name), do: false

  @doc false
  # The mode of a column pair (a join key pair) when either column is a
  # tenant/site column: the strongest of both columns' own modes by their
  # declared types across the domain, so an INT tenant paired with a VARCHAR
  # key compares by bytes rather than numerically (ADDENDUM 6). false when
  # neither is a tenant/site column or both compare exactly already.
  def identity_pair(selecto, left, right) do
    domain = Map.get(selecto, :domain)

    enabled?(selecto) and is_map(domain) and
      (tenant_name?(domain, left) or tenant_name?(domain, right)) and
      strongest([name_mode(domain, to_string(left)), name_mode(domain, to_string(right))])
  end

  @doc false
  # Fields (as written: "org_key", "a.label") that host-installed predicates
  # compare with =, <>, !=, IN or NOT IN anywhere in their tree (through
  # AND/OR/NOT at any depth): the domain's and the query's required filters,
  # the trusted tenant context's required filters, the engine tenant
  # binding, and the filters the query held when its read boundary was
  # accepted (Selecto.Tenant.require_read_boundary/2 records them as
  # `set.host_filtered` before any request input is applied). Such a predicate decides tenant identity even on a domain that
  # declares no tenant_field (a host scope org_key = 't1', a site pin), so the
  # field compares exactly (<> as NOT of the exact equality), judged by its
  # owning relation's declared type, which reproduces PostgreSQL. The caller's
  # own filters are not host scope.
  def host_names(selecto) do
    set = Map.get(selecto, :set) || %{}
    domain = Map.get(selecto, :domain) || %{}
    context = Map.get(selecto, :tenant) || %{}

    filters =
      List.wrap(get(domain, :required_filters)) ++
        List.wrap(Map.get(set, :required_filters)) ++
        List.wrap(get(context, :required_filters)) ++
        List.wrap(Map.get(set, :host_filtered)) ++ Selecto.Tenant.engine_filters(selecto)

    (Enum.flat_map(filters, &comparison_fields/1) ++ computed_body_fields(selecto, filters))
    |> Enum.uniq()
  end

  # A computed column that a host predicate names, with any operator
  # ({"is_t1", true} included), is host scope over its expression
  # (ADDENDUM 7a): the =, <>, IN and NOT IN leaves of a computed predicate's
  # body, and of every CASE WHEN condition of a computed value, decide which
  # rows the host admits just as if the host had written them. Their fields
  # join the host names, so each leaf compares exactly by its own declared
  # type. Computed columns the expression reads are followed (cycles are
  # refused at validation; the visited set only bounds the walk). A joined
  # schema's computed expression is qualified to its join at configure
  # (Selecto.Schema.Column), so "a.is_s1" widens "a.site". Caller filters on
  # a computed column add nothing.
  defp computed_body_fields(selecto, filters, collect \\ &comparison_fields/1) do
    columns =
      case Map.get(selecto, :config) do
        %{columns: columns} when is_map(columns) -> columns
        _ -> %{}
      end

    if columns == %{} do
      []
    else
      filters
      |> Enum.flat_map(&referenced_fields/1)
      |> expand_computed(columns, MapSet.new(), [], collect)
    end
  end

  defp expand_computed([], _columns, _visited, acc, _collect), do: acc

  defp expand_computed([name | rest], columns, visited, acc, collect) do
    if MapSet.member?(visited, name) do
      expand_computed(rest, columns, visited, acc, collect)
    else
      visited = MapSet.put(visited, name)

      case computed_body(columns, name) do
        nil ->
          expand_computed(rest, columns, visited, acc, collect)

        {:predicate, body} ->
          expand_computed(
            referenced_fields(body) ++ rest,
            columns,
            visited,
            acc ++ collect.(body),
            collect
          )

        {:value, conditions, fields} ->
          expand_computed(
            Enum.flat_map(conditions, &referenced_fields/1) ++ fields ++ rest,
            columns,
            visited,
            acc ++ Enum.flat_map(conditions, collect),
            collect
          )
      end
    end
  end

  defp computed_body(columns, name) do
    conf =
      Map.get(columns, name) ||
        try do
          Map.get(columns, String.to_existing_atom(name))
        rescue
          ArgumentError -> nil
        end

    case conf do
      %{select: {:computed_predicate, expression}} ->
        {:predicate, Selecto.Domain.Contract.ComputedPredicates.to_filter(expression)}

      %{select: {:computed_value, expression}} ->
        expression =
          case Selecto.Domain.Contract.ComputedValues.normalize(expression) do
            {:ok, normalized} -> normalized
            _ -> expression
          end

        {conditions, fields} = value_parts(expression)
        {:value, conditions, fields}

      _ ->
        nil
    end
  end

  # A computed value's comparison conditions (CASE WHEN filters, at any
  # depth) and the fields it reads (other computed columns among them).
  # The comparisons the WHEN conditions hold decide which value a row takes,
  # so under a host predicate they are host scope too (ADDENDUM 7a).
  defp value_parts([tag | branches]) when tag in [:case, "case"] do
    Enum.reduce(branches, {[], []}, fn
      [else_tag, value], {conditions, fields} when else_tag in [:else, "else"] ->
        {c, f} = value_parts(value)
        {conditions ++ c, fields ++ f}

      [condition, value], {conditions, fields} ->
        {c, f} = value_parts(value)

        {conditions ++
           [Selecto.Domain.Contract.ComputedPredicates.to_filter(condition)] ++ c, fields ++ f}

      _other, acc ->
        acc
    end)
  end

  defp value_parts([tag, path])
       when tag in [:field, "field"] and (is_binary(path) or is_atom(path)),
       do: {[], [to_string(path)]}

  defp value_parts([tag | _]) when tag in [:literal, "literal"], do: {[], []}

  defp value_parts([tag, path, _segments]) when tag in [:json_text, "json_text"],
    do: {[], [to_string(path)]}

  defp value_parts([op | arguments]) when is_atom(op) or is_binary(op) do
    Enum.reduce(arguments, {[], []}, fn argument, {conditions, fields} ->
      {c, f} = value_parts(argument)
      {conditions ++ c, fields ++ f}
    end)
  end

  defp value_parts(_expression), do: {[], []}

  # Every field a filter tree names, whatever the operator.
  defp referenced_fields({conj, filters}) when conj in [:and, :or] and is_list(filters),
    do: Enum.flat_map(filters, &referenced_fields/1)

  defp referenced_fields({:not, filter}), do: referenced_fields(filter)

  defp referenced_fields({field}) when is_binary(field) or (is_atom(field) and not is_nil(field)),
    do: [to_string(field)]

  defp referenced_fields({field, value})
       when is_binary(field) or (is_atom(field) and not is_nil(field) and field not in [:exists]),
       do: [to_string(field) | ref_field(value)]

  defp referenced_fields({field, _op, _value})
       when is_binary(field) or (is_atom(field) and not is_nil(field) and field not in [:exists]),
       do: [to_string(field)]

  defp referenced_fields(_filter), do: []

  defp ref_field({:ref, field}) when is_binary(field) or is_atom(field), do: [to_string(field)]

  defp ref_field({_op, {:ref, field}}) when is_binary(field) or is_atom(field),
    do: [to_string(field)]

  defp ref_field(_value), do: []

  @doc false
  # The fields an equality-family comparison (=, <>, !=, IN, NOT IN) names
  # anywhere in a Selecto filter tree.
  def comparison_fields({conj, filters}) when conj in [:and, :or] and is_list(filters),
    do: Enum.flat_map(filters, &comparison_fields/1)

  def comparison_fields({:not, filter}), do: comparison_fields(filter)

  def comparison_fields({field, value})
      when is_binary(field) or (is_atom(field) and not is_nil(field)) do
    if equality_value?(value), do: [to_string(field)], else: []
  end

  def comparison_fields({field, op, value})
      when (is_binary(field) or is_atom(field)) and op in [:in, "in", :not_in, "not_in"] and
             is_list(value),
      do: [to_string(field)]

  def comparison_fields(_filter), do: []

  @equality_ops [
    :eq,
    :=,
    "=",
    "eq",
    :ne,
    :!=,
    "!=",
    "<>",
    "ne",
    "neq",
    :neq,
    :in,
    "in",
    :not_in,
    "not_in"
  ]

  defp equality_value?({op, _value}) when op in @equality_ops, do: true
  defp equality_value?({:ref, _field}), do: true

  defp equality_value?(value) when is_binary(value) or is_number(value) or is_list(value),
    do: true

  defp equality_value?(_value), do: false

  @doc false
  # The mode of a column named `name` that a host predicate names, by its
  # declared types (an undeclared name is text).
  def host_mode(selecto, name) when is_binary(name), do: name in host_names(selecto)

  def host_mode(_selecto, _name), do: false

  @doc false
  # The strongest of several modes: converting beats bytes beats plain.
  def strongest(modes) do
    cond do
      Enum.any?(modes, &(&1 == true)) -> true
      Enum.any?(modes, &(&1 == :server)) -> :server
      Enum.any?(modes, &(&1 == :bytes)) -> :bytes
      true -> false
    end
  end

  @doc false
  # `left = right`, exact when `exact?`. A column side is converted to utf8mb4
  # before its bytes are compared: CAST(col AS BINARY) alone would compare the
  # column's own charset bytes, so a utf16, ucs2, utf32 or latin1 tenant column
  # would never equal the utf8mb4 bound value. A bound value (`{:param, _}` or
  # `?`) is already utf8mb4.
  # `:server` (an undeclared column) lets the server decide: a column whose
  # collation is 'binary' (numeric, temporal, binary types) compares plainly,
  # a text column by its utf8mb4 bytes.
  def eq(left, right, :server),
    do: [
      "(",
      left,
      " = ",
      right,
      " AND (",
      binary_collation(left, right),
      " OR ",
      bytes(left, true),
      " = ",
      bytes(right, true),
      "))"
    ]

  def eq(left, right, mode) when mode in [true, :bytes],
    do: ["(", left, " = ", right, " AND ", bytes(left, mode), " = ", bytes(right, mode), ")"]

  def eq(left, right, _exact?), do: [left, " = ", right]

  # A bound value takes the column's comparison; a column pair is plain only
  # when both sides have a 'binary' collation.
  defp binary_collation(left, right) when right == "?" or is_tuple(right),
    do: ["COLLATION(", left, ") = 'binary'"]

  defp binary_collation(left, right),
    do: ["(COLLATION(", left, ") = 'binary' AND COLLATION(", right, ") = 'binary')"]

  @doc false
  # `left IN (values)` for parameter markers or rendered values, exact when
  # `exact?`: `left IN (v, ...) AND <bytes(left)> IN (<bytes(v)>, ...)`.
  def in_list(left, values, :server) do
    plain = Enum.intersperse(values, ", ")
    cast = values |> Enum.map(&bytes(&1, true)) |> Enum.intersperse(", ")

    [
      "(",
      left,
      " IN (",
      plain,
      ") AND (COLLATION(",
      left,
      ") = 'binary' OR ",
      bytes(left, true),
      " IN (",
      cast,
      ")))"
    ]
  end

  def in_list(left, values, mode) when mode in [true, :bytes] do
    plain = Enum.intersperse(values, ", ")
    cast = values |> Enum.map(&bytes(&1, mode)) |> Enum.intersperse(", ")
    ["(", left, " IN (", plain, ") AND ", bytes(left, mode), " IN (", cast, "))"]
  end

  def in_list(left, values, _exact?), do: [left, " IN (", Enum.intersperse(values, ", "), ")"]

  @doc false
  # `left IN <subquery>` (fragments include their parentheses), exact when
  # `exact?`: `left IN <plain> AND <bytes(left)> IN <bytes_subquery>`, where
  # `bytes_subquery` selects the utf8mb4 bytes of the subquery's single
  # column (see bytes_subquery/2). Both fragments bind their parameter
  # markers in SQL-text order.
  def in_subquery(left, plain, bytes_subquery, :server),
    do: [
      "(",
      left,
      " IN ",
      plain,
      " AND (COLLATION(",
      left,
      ") = 'binary' OR ",
      bytes(left, true),
      " IN ",
      bytes_subquery,
      "))"
    ]

  def in_subquery(left, plain, bytes_subquery, mode) when mode in [true, :bytes],
    do: ["(", left, " IN ", plain, " AND ", bytes(left, mode), " IN ", bytes_subquery, ")"]

  def in_subquery(left, plain, _bytes_subquery, _exact?), do: [left, " IN ", plain]

  @doc false
  # A subquery fragment selecting the utf8mb4 bytes of `column` of the derived
  # table built from `subquery` (iodata with its own parentheses).
  def bytes_subquery(subquery, column, mode \\ true),
    do: [
      "(SELECT ",
      bytes(["`selecto_exact`.`", column, "`"], mode),
      " FROM ",
      subquery,
      " AS `selecto_exact`)"
    ]

  @doc false
  # The utf8mb4 bytes of a column expression or a bound value.
  # With `:bytes` a column's stored bytes are taken as they are.
  def bytes(expression, mode \\ true)
  def bytes({:param, _value} = param, _mode), do: ["CAST(", param, " AS BINARY)"]
  def bytes("?", _mode), do: "CAST(? AS BINARY)"
  def bytes(expression, :bytes), do: ["CAST(", expression, " AS BINARY)"]

  # Column against column of the same relation's type (retarget tuples): the
  # utf8mb4 bytes of a text column, an empty string for a 'binary'-collation
  # one, whose plain tuple element already decides.
  def bytes(expression, :server),
    do: [
      "IF(COLLATION(",
      expression,
      ") = 'binary', '', CAST(CONVERT(",
      expression,
      " USING utf8mb4) AS BINARY))"
    ]

  def bytes(expression, _mode), do: ["CAST(CONVERT(", expression, " USING utf8mb4) AS BINARY)"]

  @doc false
  # The mode a column named `name` takes by its declared types alone (true
  # when undeclared).
  def text_column?(domain, name) when is_map(domain) and (is_binary(name) or is_atom(name)),
    do: name_mode(domain, to_string(name))

  def text_column?(_domain, _name), do: true

  @doc false
  # Whether a scope-key pair that decides tenant identity (direct scope keys,
  # the tenant pair, root -> bridge and bridge -> target scope keys) takes the
  # exact form: on an exact-compare adapter whenever EITHER side may hold
  # text, judged by each column's own declared type in its own relation. A
  # relation or column that is not declared counts as text. Two columns both
  # declared non-text (integers, say) keep the plain comparison. Comparing an
  # INT tenant with a VARCHAR scope plainly is numeric on MySQL, so '07',
  # '7 ' and '7e0' would all equal 7.
  def pair?(selecto, {left_relation, left_field}, {right_relation, right_field}) do
    enabled?(selecto) and
      strongest([
        type_mode(declared_type(left_relation, left_field)),
        type_mode(declared_type(right_relation, right_field))
      ])
  end

  @doc false
  # The mode of one column of `relation` compared with a bound value in a
  # domain-authored host predicate (an association `where` policy): by the
  # column's own declared type under the three-way classification, guarded
  # (:server) when the relation or column is undeclared, and at least the
  # mode a tenant/site column of that name takes. false on other adapters.
  def field_mode(selecto, relation, field) when is_atom(field) or is_binary(field) do
    enabled?(selecto) and
      strongest([type_mode(declared_type(relation, field)), column?(selecto, field)])
  end

  @doc false
  # The domain relation (the root source or a schema) stored in `table`, or nil.
  def relation_for_table(%{domain: domain}, table), do: relation_for_table(domain, table)

  def relation_for_table(domain, table) when is_map(domain) and not is_nil(table) do
    table = to_string(table)

    relations =
      [get(domain, :source)] ++
        case get(domain, :schemas) do
          schemas when is_map(schemas) -> Map.values(schemas)
          _ -> []
        end

    Enum.find(relations, fn relation ->
      is_map(relation) and to_string(get(relation, :source_table) || "") == table
    end)
  end

  def relation_for_table(_domain, _table), do: nil

  defp declared_type(relation, field) when is_map(relation) and not is_nil(field) do
    case column_spec(relation, to_string(field)) do
      nil -> nil
      spec -> column_type(spec)
    end
  end

  defp declared_type(_relation, _field), do: nil

  defp tenant_names(domain) do
    root = Selecto.Tenant.domain_tenant_columns(domain)

    schemas =
      case get(domain, :schemas) do
        schemas when is_map(schemas) ->
          schemas
          |> Map.values()
          |> Enum.flat_map(fn schema ->
            [get(schema, :tenant_field), write_tenant_field(schema)]
          end)

        _ ->
          []
      end

    (root ++ [write_tenant_field(domain)] ++ schemas)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp write_tenant_field(relation) when is_map(relation) do
    tenant = relation |> get(:writes) |> get(:scope) |> get(:tenant)
    get(tenant, :field) || get(tenant, :tenant_field)
  end

  defp write_tenant_field(_relation), do: nil

  # The mode of a name across its declarations in the domain; an undeclared
  # name is text.
  defp name_mode(domain, name) do
    relations =
      [get(domain, :source)] ++
        case get(domain, :schemas) do
          schemas when is_map(schemas) -> Map.values(schemas)
          _ -> []
        end

    types =
      relations
      |> Enum.flat_map(fn relation ->
        case column_spec(relation, name) do
          nil -> []
          spec -> [column_type(spec)]
        end
      end)

    if types == [], do: :server, else: strongest(Enum.map(types, &type_mode/1))
  end

  defp column_spec(relation, name) when is_map(relation) do
    case get(relation, :columns) do
      columns when is_map(columns) ->
        Enum.find_value(columns, fn {field, spec} -> if to_string(field) == name, do: spec end)

      _ ->
        nil
    end
  end

  defp column_spec(_relation, _name), do: nil

  defp column_type(spec) when is_map(spec), do: get(spec, :type)
  defp column_type(spec) when is_atom(spec) or is_binary(spec), do: spec
  defp column_type(_spec), do: nil

  @doc false
  # The mode of a declared column type: text, undeclared (nil) and
  # unrecognised types convert (true), UUID types compare stored bytes
  # (:bytes), and integer, decimal, binary, boolean and temporal types
  # compare exactly already (false).
  def type_mode(nil), do: :server

  def type_mode(type) do
    case type_class(type) do
      :text -> true
      :non_text -> false
      :other -> :server
    end
  end

  @doc false
  def text_type?(type), do: type_mode(type) != false

  defp type_class({:array, _type}), do: :non_text
  defp type_class({:map, _type}), do: :non_text

  defp type_class({:parameterized, {module, _params}}), do: module_class(module)
  defp type_class({:parameterized, module, _params}), do: module_class(module)

  defp type_class(type) when is_atom(type) and not is_nil(type) do
    case Atom.to_string(type) do
      "Elixir." <> _ -> module_class(type)
      name -> type_class(name)
    end
  end

  defp type_class(type) when is_binary(type) do
    name = normalize_type_name(type)

    cond do
      name in @text_types ->
        :text

      name in @non_text_types ->
        :non_text

      true ->
        :other
    end
  end

  defp type_class(_type), do: :other

  defp module_class(Ecto.Enum), do: :text
  defp module_class(_module), do: :other

  defp normalize_type_name(type) do
    type
    |> String.downcase()
    |> String.replace(~r/\s+(character\s+set|charset|collate)\s+.*$/, "")
    |> String.replace(~r/\s*\(.*\)\s*$/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil
end
