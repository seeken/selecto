defmodule Selecto.Builder.Sql.Helpers do
  @moduledoc """
  Helper functions shared by SQL builder modules.

  Responsibilities include:

  - adapter-aware identifier quoting
  - identifier safety validation
  - selector and join string construction
  - support helpers for parameterized join aliases
  """

  ### SQL safety helpers - prevent injection via string validation

  @doc """
  Get the quote character exposed by the configured database adapter.
  """
  def get_quote_char(selecto) do
    adapter = Map.get(selecto, :adapter, Selecto.AdapterSupport.default_adapter())

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) ->
        case adapter.quote_identifier("selecto_probe") do
          <<quote::binary-size(1), _rest::binary>> -> quote
          _ -> "\""
        end

      true ->
        "\""
    end
  end

  @doc """
  Check if an identifier needs quoting.
  Only quote if it's a reserved word, contains special characters, or has mixed case.
  """
  def needs_quoting?(str) when is_binary(str) do
    # A plain identifier (only lowercase ASCII letters, digits and
    # underscores) needs quoting when it is a reserved word or starts with a
    # digit. Anything else (uppercase, so mixed case; special characters,
    # including any non-ASCII byte) needs quoting. Byte matching, no regex or
    # Unicode case mapping: this runs for every identifier of every query.
    if plain_identifier?(str) do
      reserved_word?(str) or leading_digit?(str)
    else
      true
    end
  end

  def needs_quoting?(_), do: false

  # Common SQL reserved words that appear as column names.
  @reserved_words ~w(
    user order group select from where having limit offset join left right
    inner outer cross union all distinct as on using natural full exists
    case when then else end null is not and or in between like
    primary key foreign references table column index create alter drop
    insert update delete values set into default unique check constraint
    view trigger function procedure return declare begin commit rollback
    transaction isolation level read write only deferrable serializable
    repeatable committed uncommitted work savepoint release cursor fetch
    close cast row array text integer boolean date time timestamp interval
    numeric decimal real double precision varchar char bit varying zone
  )

  for word <- @reserved_words do
    defp reserved_word?(unquote(word)), do: true
  end

  defp reserved_word?(_str), do: false

  defp leading_digit?(<<digit, _rest::binary>>) when digit in ?0..?9, do: true
  defp leading_digit?(_str), do: false

  defp plain_identifier?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?0..?9 or char == ?_,
       do: plain_identifier?(rest)

  defp plain_identifier?(<<>>), do: true
  defp plain_identifier?(_str), do: false

  # The characters a table, column or alias name may contain.
  # Reserved words of every supported dialect (PostgreSQL, MySQL 8.4, MariaDB
  # 11.4, SQLite, DuckDB), lower case: a list name that is one, in any case, is
  # quoted (plain_name?/1).
  @dialect_reserved ~w(
    abort accessible action add after all alter always analyse analyze and anti any array as
    asc asensitive asof asymmetric attach authorization autoincrement before begin between
    bigint binary bit blob boolean both by call cascade case cast change char character
    check coalesce collate collation column commit concurrently condition conflict
    constraint continue convert create cross cube cume_dist current current_catalog
    current_date current_role current_schema current_time current_timestamp current_user
    cursor database databases day_hour day_microsecond day_minute day_second dec decimal
    declare default deferrable deferred delayed delete delete_domain_id dense_rank desc
    describe detach deterministic distinct distinctrow div do do_domain_ids double drop dual
    each else elseif empty enclosed end escape escaped except exclude exclusive exists exit
    explain extract fail false fetch filter first first_value float float4 float8 following
    for force foreign freeze from full fulltext function general generated get glob grant
    greatest group grouping groups having high_priority hour_microsecond hour_minute
    hour_second if ignore ignore_domain_ids ignore_server_ids ilike immediate in index
    indexed infile initially inner inout insensitive insert instead int int1 int2 int3 int4
    int8 integer intersect interval into io_after_gtids io_before_gtids is isnull iterate
    join json json_array json_arrayagg json_exists json_object json_objectagg json_query
    json_scalar json_serialize json_table json_value key keys kill lag last last_value
    lateral lead leading least leave left like limit linear lines load localtime
    localtimestamp lock long longblob longtext loop low_priority manual map master_bind
    master_heartbeat_period master_ssl_verify_server_cert match materialized maxvalue
    mediumblob mediumint mediumtext merge_action middleint minute_microsecond minute_second
    mod modifies national natural nchar no no_write_to_binlog none normalize not nothing
    notnull nth_value ntile null nullif nulls numeric of offset on only optimize
    optimizer_costs option optionally or order others out outer outfile over overlaps
    overlay page_checksum parallel parse_vcol_expr partition percent_rank pivot pivot_longer
    pivot_wider placing plan position positional pragma preceding precision primary
    procedure purge qualify query raise range rank read read_write reads real recursive
    ref_system_id references regexp reindex release rename repeat replace require resignal
    restrict return returning revoke right rlike rollback row row_number rownum rows
    savepoint schema schemas second_microsecond select semi sensitive separator session_user
    set setof show signal similar slow smallint some spatial specific sql sql_big_result
    sql_calc_found_rows sql_small_result sqlexception sqlstate sqlwarning ssl starting
    stats_auto_recalc stats_persistent stats_sample_pages stored straight_join struct
    substring summarize symmetric system system_user table tablesample temp temporary
    terminated then ties time timestamp tinyblob tinyint tinytext to trailing transaction
    treat trigger trim true try_cast unbounded undo union unique unlock unpivot unsigned
    update usage use user using utc_date utc_time utc_timestamp vacuum values varbinary
    varchar varcharacter variadic varying vector verbose view virtual when where while
    window with without write xmlattributes xmlconcat xmlelement xmlexists xmlforest
    xmlnamespaces xmlparse xmlpi xmlroot xmlserialize xmltable xor year_month zerofill
  )

  @doc false
  # Whether a list name can stand unquoted on every adapter: letters, digits and
  # underscores, not starting with a digit, not a reserved word, in any case.
  # Unquoted, PostgreSQL folds it to lower case, as it folds a host's own SQL
  # naming it unquoted.
  def plain_name?(name) when is_binary(name) do
    lower = String.downcase(name)

    Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and not needs_quoting?(lower) and
      lower not in @dialect_reserved
  end

  def plain_name?(_name), do: false

  @doc false
  # A CTE or VALUES list's name as `adapter` writes it in its definition:
  # unquoted when plain_name?/1, quoted otherwise. Never raises: an embedded
  # quote is doubled.
  def list_identifier(adapter, name) do
    name = to_string(name)

    cond do
      plain_name?(name) ->
        name

      Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) ->
        adapter.quote_identifier(name)

      true ->
        "\"" <> String.replace(name, "\"", "\"\"") <> "\""
    end
  end

  @doc false
  # A relation a root or a join names: a CTE or VALUES list visible to the
  # query is written as its definition is (list_identifier/2, or as a raw
  # CTE's text quotes it); anything else as quote_identifier/2 writes it.
  def relation_identifier(selecto, name) do
    name = to_string(name)

    case list_kind(selecto, name) do
      :list -> if plain_name?(name), do: name, else: quote_identifier(selecto, name)
      _other -> quote_identifier(selecto, name)
    end
  end

  @doc false
  # How a list of `name` visible to `selecto` is defined: :list (a Selecto
  # CTE or VALUES list, or a raw CTE's unquoted name), :quoted_raw (a raw CTE
  # quoting it), or nil when no list of that name is visible.
  def list_kind(selecto, name) do
    set = Map.get(selecto, :set) || %{}
    dialect = Selecto.Executor.dialect(selecto)

    own =
      Enum.flat_map(List.wrap(Map.get(set, :ctes)), fn
        {tag, sql, _params} when tag in [:raw_cte, :raw_recursive_cte] ->
          case Selecto.Builder.RawCte.entries(sql, dialect) do
            {:ok, entries} ->
              for {n, quoted?} <- entries, do: {n, if(quoted?, do: :quoted_raw, else: :list)}

            :error ->
              []
          end

        %{name: n} when not is_nil(n) ->
          [{to_string(n), :list}]

        _other ->
          []
      end) ++
        for(
          %{} = values <- List.wrap(Map.get(set, :values_clauses)),
          n = Map.get(values, :alias),
          not is_nil(n),
          do: {to_string(n), :list}
        ) ++ List.wrap(Map.get(set, :visible_lists))

    Enum.find_value(own, fn {n, kind} -> if n == name, do: kind end)
  end

  @doc false
  # Whether quote_identifier/2 accepts `str` (it raises otherwise).
  def valid_identifier?(str) when is_binary(str), do: identifier_chars?(str)
  def valid_identifier?(_str), do: false

  defp identifier_chars?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in [?_, ?\s, ?:, ?&, ?-],
       do: identifier_chars?(rest)

  defp identifier_chars?(<<>>), do: true
  defp identifier_chars?(_str), do: false

  @doc """
  Maybe quote an identifier - only adds quotes if necessary.
  """
  def maybe_quote_identifier(str) when is_binary(str) do
    if needs_quoting?(str) do
      escaped = String.replace(str, "\"", "\"\"")
      ~s["#{escaped}"]
    else
      str
    end
  end

  def maybe_quote_identifier(str) when is_atom(str) do
    maybe_quote_identifier(Atom.to_string(str))
  end

  def maybe_quote_identifier(other), do: to_string(other)

  @doc """
  Always quote an identifier through the active adapter.
  """
  def force_quote_identifier(selecto, str) when is_integer(str),
    do: force_quote_identifier(selecto, to_string(str))

  def force_quote_identifier(selecto, str) when is_float(str),
    do: force_quote_identifier(selecto, to_string(str))

  def force_quote_identifier(selecto, str) when is_atom(str) do
    force_quote_identifier(selecto, Atom.to_string(str))
  end

  def force_quote_identifier(selecto, str) when is_binary(str) do
    adapter = Map.get(selecto, :adapter, Selecto.AdapterSupport.default_adapter())

    if Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) do
      adapter.quote_identifier(str)
    else
      maybe_quote_identifier(str)
    end
  end

  def force_quote_identifier(selecto, other),
    do: force_quote_identifier(selecto, to_string(other))

  def check_string(nil), do: nil
  def check_string(str) when is_integer(str), do: check_string(to_string(str))
  def check_string(str) when is_float(str), do: check_string(to_string(str))
  def check_string(str) when is_atom(str), do: check_string(Atom.to_string(str))

  def check_string(string) when is_binary(string) do
    if string |> String.match?(~r/[^a-zA-Z0-9_]/) do
      raise RuntimeError, message: "Invalid String #{string}"
    end

    string
  end

  def check_string(other) do
    if match?(%Selecto{}, other) do
      raise ArgumentError,
            "Cannot use Selecto struct as string in check_string. Got: #{inspect(other, limit: 3)}"
    end

    try do
      check_string(to_string(other))
    rescue
      Protocol.UndefinedError ->
        raise ArgumentError,
              "Cannot convert #{inspect(other, limit: 3)} to string in check_string"
    end
  end

  def single_wrap(val) do
    val = String.replace(val, ~r/'/, "''")
    ~s"'#{val}'"
  end

  def double_wrap(nil), do: ""
  def double_wrap(str) when is_integer(str), do: double_wrap(to_string(str))
  def double_wrap(str) when is_float(str), do: double_wrap(to_string(str))

  def double_wrap(str) when is_atom(str) do
    Atom.to_string(str) |> double_wrap()
  end

  def double_wrap(str) when is_binary(str) do
    unless identifier_chars?(str) do
      raise RuntimeError, message: "Invalid Table/Column/Alias Name #{str}"
    end

    # Only quote if necessary
    maybe_quote_identifier(str)
  end

  def double_wrap(other) do
    # Don't try to wrap complex structs
    if match?(%Selecto{}, other) do
      raise ArgumentError,
            "Cannot use Selecto struct as identifier in double_wrap. Got: #{inspect(other, limit: 3)}"
    end

    # Fallback for any other type - convert to string
    try do
      double_wrap(to_string(other))
    rescue
      Protocol.UndefinedError ->
        raise ArgumentError, "Cannot convert #{inspect(other, limit: 3)} to string in double_wrap"
    end
  end

  @doc """
  Wrap an identifier with the appropriate quotes for the database adapter.
  This is the adapter-aware version of double_wrap.
  """
  def quote_identifier(_selecto, nil), do: ""

  def quote_identifier(selecto, str) when is_integer(str),
    do: quote_identifier(selecto, to_string(str))

  def quote_identifier(selecto, str) when is_float(str),
    do: quote_identifier(selecto, to_string(str))

  def quote_identifier(selecto, str) when is_atom(str) do
    quote_identifier(selecto, Atom.to_string(str))
  end

  def quote_identifier(selecto, str) when is_binary(str) do
    unless identifier_chars?(str) do
      raise RuntimeError, message: "Invalid Table/Column/Alias Name #{str}"
    end

    # Only quote if necessary
    if needs_quoting?(str) do
      adapter = Map.get(selecto, :adapter, Selecto.AdapterSupport.default_adapter())

      if Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) do
        adapter.quote_identifier(str)
      else
        quote = get_quote_char(selecto)
        escaped = String.replace(str, quote, quote <> quote)
        "#{quote}#{escaped}#{quote}"
      end
    else
      str
    end
  end

  def quote_identifier(selecto, other) do
    # Don't try to wrap complex structs
    if match?(%Selecto{}, other) do
      raise ArgumentError,
            "Cannot use Selecto struct as identifier in quote_identifier. Got: #{inspect(other, limit: 3)}"
    end

    # Fallback for any other type - convert to string
    try do
      quote_identifier(selecto, to_string(other))
    rescue
      Protocol.UndefinedError ->
        raise ArgumentError,
              "Cannot convert #{inspect(other, limit: 3)} to string in quote_identifier"
    end
  end

  def build_selector_string(selecto, join, field) do
    case {join, field} do
      {nil, _} ->
        quote_identifier(selecto, field)

      {_, nil} ->
        join_str = if is_atom(join), do: Atom.to_string(join), else: join
        quote_identifier(selecto, join_str)

      _ ->
        join_str = if is_atom(join), do: Atom.to_string(join), else: join
        "#{quote_identifier(selecto, join_str)}.#{quote_identifier(selecto, field)}"
    end
  end

  def build_join_string(selecto, join) do
    quote_identifier(selecto, join)
  end

  @doc """
  Build selector string for parameterized joins with signature support.
  """
  def build_parameterized_selector_string(selecto, join, field, parameter_signature \\ nil) do
    case parameter_signature do
      nil -> "#{quote_identifier(selecto, join)}.#{quote_identifier(selecto, field)}"
      "" -> "#{quote_identifier(selecto, join)}.#{quote_identifier(selecto, field)}"
      sig -> "#{quote_identifier(selecto, "#{join}_#{sig}")}.#{quote_identifier(selecto, field)}"
    end
  end

  @doc """
  Build join alias string for parameterized joins.
  """
  def build_parameterized_join_string(selecto, join, parameter_signature \\ nil) do
    case parameter_signature do
      nil -> quote_identifier(selecto, join)
      "" -> quote_identifier(selecto, join)
      sig -> quote_identifier(selecto, "#{join}_#{sig}")
    end
  end
end
