defmodule Selecto.Builder.RawCte do
  @moduledoc false

  # The names a raw CTE's text (`{:raw_cte, sql, params}`, the host's own text,
  # R68) defines: one or more plain definitions
  #
  #     name [(columns)] AS [NOT] [MATERIALIZED] ( body ) [, ...]
  #
  # with comments allowed before, between and after them, read the way
  # `dialect` lexes them (:postgresql, :mysql, :mariadb, :sqlite, :duckdb, or
  # :any, which refuses whatever one of them reads differently). A name is
  # unquoted (`[A-Za-z_][A-Za-z0-9_$]*`), "double quoted", `backtick quoted` or,
  # on SQLite, [bracketed]. A body's parentheses are balanced past string
  # literals, quoted identifiers, comments and (PostgreSQL) dollar-quoted
  # strings. `{:param, value}` markers in iodata text read as a neutral literal.
  #
  # Refused (`:error`, which Selecto.Executor refuses as `raw_cte_unparsed`):
  # anything this does not recognise to the end, a backslash in a string
  # literal (MySQL and MariaDB treat it as an escape, PostgreSQL and SQLite do
  # not), non-ASCII names, SEARCH/CYCLE clauses, a RECURSIVE prefix, a trailing
  # comma; on MySQL and MariaDB also `#` comments, `--` not followed by
  # whitespace, `/*!` and `/*M!` executable comments and "double quotes"
  # (ANSI_QUOTES is not known); outside PostgreSQL, dollar quotes and nested
  # block comments; on SQLite, Tcl-style `$name(...)` parameters (also with
  # `@`, `:` or `#`), which it reads up to the `)`.

  @dialects [:postgresql, :mysql, :mariadb, :sqlite, :duckdb, :any]

  @spec names(iodata(), atom()) :: {:ok, [String.t()]} | :error
  def names(sql, dialect \\ :any) do
    with {:ok, entries} <- entries(sql, dialect), do: {:ok, Enum.map(entries, &elem(&1, 0))}
  end

  @doc false
  # Each name with whether the text quotes it: an unquoted name is folded by
  # the database (PostgreSQL to lower case), a quoted one kept as written.
  @spec entries(iodata(), atom()) :: {:ok, [{String.t(), boolean()}]} | :error
  def entries(sql, dialect \\ :any) do
    dialect = if dialect in @dialects, do: dialect, else: :any

    with {:ok, text} <- text(sql),
         {:ok, rest} <- skip(text, dialect),
         {:ok, entries} <- definitions(rest, [], dialect) do
      {:ok, Enum.reverse(entries)}
    end
  end

  # The text as a binary, each {:param, value} as a neutral literal; anything
  # else that is not iodata is unreadable.
  defp text(sql) do
    {:ok, sql |> flatten([]) |> Enum.reverse() |> IO.iodata_to_binary()}
  catch
    :unreadable -> :error
  end

  defp flatten(binary, acc) when is_binary(binary), do: [binary | acc]
  defp flatten(byte, acc) when is_integer(byte) and byte in 0..255, do: [byte | acc]
  defp flatten({:param, _value}, acc), do: [" 0 " | acc]
  defp flatten(list, acc) when is_list(list), do: Enum.reduce(list, acc, &flatten/2)
  defp flatten(_other, _acc), do: throw(:unreadable)

  defp definitions(text, entries, d) do
    quoted? = match?(<<q, _::binary>> when q in [?", ?`, ?[], text)

    with {:ok, name, rest} <- name(text, d),
         {:ok, rest} <- skip(rest, d),
         {:ok, rest} <- columns(rest, d),
         {:ok, rest} <- keyword(rest, "as", d),
         {:ok, rest} <- optional(rest, "not", d),
         {:ok, rest} <- optional(rest, "materialized", d),
         {:ok, rest} <- body(rest, d),
         {:ok, rest} <- skip(rest, d) do
      case rest do
        "" ->
          {:ok, [{name, quoted?} | entries]}

        "," <> more ->
          with {:ok, more} <- skip(more, d),
               do: definitions(more, [{name, quoted?} | entries], d)

        _other ->
          :error
      end
    end
  end

  defguardp mysql?(d) when d in [:mysql, :mariadb, :any]
  defguardp space?(c) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v]
  # Bytes 0x80 and up are identifier characters (PostgreSQL reads them so).
  defguardp word?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$] or c >= 0x80

  # Whitespace and comments.
  defp skip(<<c, rest::binary>>, d) when space?(c), do: skip(rest, d)
  defp skip("#" <> _rest, d) when mysql?(d), do: :error

  defp skip("--" <> rest, d) do
    with true <- comment_dashes?(rest, d),
         {:ok, rest} <- line_end(rest, d) do
      skip(rest, d)
    else
      _ -> :error
    end
  end

  defp skip("/*" <> rest, d) do
    with {:ok, rest} <- block(rest, d), do: skip(rest, d)
  end

  defp skip(text, _d), do: {:ok, text}

  # MySQL and MariaDB read `--` as a comment only before whitespace.
  defp comment_dashes?(_rest, d) when not mysql?(d), do: true
  defp comment_dashes?(<<c, _::binary>>, _d) when space?(c), do: true
  defp comment_dashes?(_rest, _d), do: false

  # A `--` comment ends at a line feed; on PostgreSQL and DuckDB also at a
  # carriage return. Where dialects disagree (:any), a carriage return in one is
  # refused.
  defp line_end(text, d) do
    {line, rest} =
      case :binary.split(text, "\n") do
        [line, rest] -> {line, rest}
        [line] -> {line, ""}
      end

    case {:binary.split(line, "\r"), d} do
      {[_line], _d} ->
        {:ok, rest}

      {[_comment, after_cr], d} when d in [:postgresql, :duckdb] ->
        {:ok, after_cr <> "\n" <> rest}

      {[_comment, _after_cr], :any} ->
        :error

      {[_comment, _after_cr], _d} ->
        {:ok, rest}
    end
  end

  defp block("!" <> _rest, d) when mysql?(d), do: :error
  defp block("M!" <> _rest, d) when mysql?(d), do: :error
  defp block(rest, d), do: block_end(rest, 1, d)

  # Block comments nest only in PostgreSQL; elsewhere a nested opener is refused.
  defp block_end("*/" <> rest, 1, _d), do: {:ok, rest}
  defp block_end("*/" <> rest, depth, d), do: block_end(rest, depth - 1, d)
  defp block_end("/*" <> rest, depth, :postgresql), do: block_end(rest, depth + 1, :postgresql)
  defp block_end("/*" <> _rest, _depth, _d), do: :error
  defp block_end(<<_c, rest::binary>>, depth, d), do: block_end(rest, depth, d)
  defp block_end("", _depth, _d), do: :error

  defp name(<<?", _::binary>>, d) when d in [:mysql, :mariadb, :any], do: :error
  defp name(<<?", rest::binary>>, _d), do: quoted(rest, ?", "")
  defp name(<<?`, rest::binary>>, _d), do: quoted(rest, ?`, "")
  defp name(<<?[, rest::binary>>, d) when d in [:sqlite, :any], do: quoted(rest, ?], "")

  defp name(<<c, _::binary>> = text, _d) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} = word(text, "")
    # Unquoted non-ASCII names are refused: dialects disagree on them.
    if word =~ ~r/\A[\x00-\x7f]*\z/, do: {:ok, word, rest}, else: :error
  end

  defp name(_text, _d), do: :error

  defp quoted(<<q, q, rest::binary>>, q, acc), do: quoted(rest, q, <<acc::binary, q>>)
  defp quoted(<<q, rest::binary>>, q, acc), do: if(acc == "", do: :error, else: {:ok, acc, rest})
  defp quoted(<<c, rest::binary>>, q, acc), do: quoted(rest, q, <<acc::binary, c>>)
  defp quoted("", _q, _acc), do: :error

  defp word(<<c, rest::binary>>, acc) when word?(c), do: word(rest, <<acc::binary, c>>)
  defp word(rest, acc), do: {acc, rest}

  defp columns("(" <> rest, d) do
    with {:ok, rest} <- balanced(rest, 1, d), do: skip(rest, d)
  end

  defp columns(text, _d), do: {:ok, text}

  defp keyword(text, keyword, d) do
    case word(text, "") do
      {word, rest} when word != "" ->
        if String.downcase(word) == keyword, do: skip(rest, d), else: :error

      _ ->
        :error
    end
  end

  defp optional(text, keyword, d) do
    case word(text, "") do
      {word, rest} when word != "" ->
        if String.downcase(word) == keyword, do: skip(rest, d), else: {:ok, text}

      _ ->
        {:ok, text}
    end
  end

  defp body("(" <> rest, d), do: balanced(rest, 1, d)
  defp body(_text, _d), do: :error

  # Past a body's closing parenthesis.
  defp balanced(")" <> rest, 1, _d), do: {:ok, rest}
  defp balanced(")" <> rest, depth, d), do: balanced(rest, depth - 1, d)
  defp balanced("(" <> rest, depth, d), do: balanced(rest, depth + 1, d)
  defp balanced("#" <> _rest, _depth, d) when mysql?(d), do: :error

  defp balanced("--" <> rest, depth, d) do
    with true <- comment_dashes?(rest, d),
         {:ok, rest} <- line_end(rest, d) do
      balanced(rest, depth, d)
    else
      _ -> :error
    end
  end

  defp balanced("/*" <> rest, depth, d) do
    with {:ok, rest} <- block(rest, d), do: balanced(rest, depth, d)
  end

  defp balanced("'" <> rest, depth, d) do
    with {:ok, rest} <- string(rest), do: balanced(rest, depth, d)
  end

  defp balanced(<<?", _::binary>>, _depth, d) when d in [:mysql, :mariadb, :any], do: :error

  defp balanced(<<q, rest::binary>>, depth, d) when q in [?", ?`] do
    with {:ok, _name, rest} <- quoted(rest, q, ""), do: balanced(rest, depth, d)
  end

  defp balanced("[" <> rest, depth, d) when d in [:sqlite, :any] do
    with {:ok, _name, rest} <- quoted(rest, ?], ""), do: balanced(rest, depth, d)
  end

  # SQLite reads `$name(...)` (also with `@`, `:` or `#`) as one parameter,
  # anything up to its `)` included: refused there.
  defp balanced(<<p, rest::binary>>, depth, d)
       when d in [:sqlite, :any] and p in [?@, ?:, ?#] do
    if tcl_call?(rest, 0), do: :error, else: balanced(rest, depth, d)
  end

  # A `$` that does not follow an identifier character may open a dollar quote:
  # PostgreSQL reads it; elsewhere it is refused. `$1` is a parameter.
  defp balanced("$" <> rest, depth, d) do
    case if(d in [:sqlite, :any] and tcl_call?(rest, 0), do: :call, else: dollar_tag(rest, "")) do
      :call ->
        :error

      {:ok, tag, rest} when d == :postgresql ->
        case :binary.split(rest, "$" <> tag <> "$") do
          [_string, rest] -> balanced(rest, depth, d)
          [_unterminated] -> :error
        end

      {:ok, _tag, _rest} ->
        :error

      :none ->
        balanced(rest, depth, d)
    end
  end

  # An identifier or number, `$` included: a `$` inside it never opens a quote.
  defp balanced(<<c, _::binary>> = text, depth, d) when word?(c) do
    {_word, rest} = word(text, "")
    balanced(rest, depth, d)
  end

  defp balanced(<<_c, rest::binary>>, depth, d), do: balanced(rest, depth, d)
  defp balanced("", _depth, _d), do: :error

  defp string("''" <> rest), do: string(rest)
  defp string("'" <> rest), do: {:ok, rest}
  defp string("\\" <> _rest), do: :error
  defp string(<<_c, rest::binary>>), do: string(rest)
  defp string(""), do: :error

  # Whether the text after a SQLite `$`, `@`, `:` or `#` is a Tcl-style
  # `name(...)` parameter: identifier characters (and `::`), then `(`.
  defp tcl_call?("::" <> rest, n), do: tcl_call?(rest, n)
  defp tcl_call?("(" <> _rest, n), do: n > 0

  defp tcl_call?(<<c, rest::binary>>, n) when word?(c), do: tcl_call?(rest, n + 1)
  defp tcl_call?(_rest, _n), do: false

  # `$tag$` or `$$` opens a dollar-quoted string; `$1` is a parameter.
  defp dollar_tag("$" <> rest, tag), do: {:ok, tag, rest}

  defp dollar_tag(<<c, rest::binary>>, tag)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80 or (c in ?0..?9 and tag != ""),
       do: dollar_tag(rest, <<tag::binary, c>>)

  defp dollar_tag(_rest, _tag), do: :none
end
