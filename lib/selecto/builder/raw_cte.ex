defmodule Selecto.Builder.RawCte do
  @moduledoc false

  # The names a raw CTE's text (`{:raw_cte, sql, params}`, the host's own text,
  # R68) defines: one or more plain definitions
  #
  #     name [(columns)] AS [NOT] [MATERIALIZED] ( body ) [, ...]
  #
  # with comments (`-- ...`, `/* ... */`) allowed before, between and after
  # them. A name is unquoted (`[A-Za-z_][A-Za-z0-9_$]*`), "double quoted",
  # `backtick quoted` or [bracketed], each with its doubled-quote escape. A
  # body's parentheses are balanced past string literals, quoted identifiers,
  # dollar-quoted strings and comments. A string literal holding a backslash is
  # not read (MySQL and MariaDB treat it as an escape, PostgreSQL and SQLite do
  # not), nor is anything else this does not recognise: `:error`, which
  # Selecto.Executor refuses as `raw_cte_unparsed`.

  @spec names(iodata()) :: {:ok, [String.t()]} | :error
  def names(sql) do
    with {:ok, entries} <- entries(sql), do: {:ok, Enum.map(entries, &elem(&1, 0))}
  end

  @doc false
  # Each name with whether the text quotes it: an unquoted name is folded by
  # the database (PostgreSQL to lower case), a quoted one kept as written.
  @spec entries(iodata()) :: {:ok, [{String.t(), boolean()}]} | :error
  def entries(sql) do
    with {:ok, rest} <- sql |> IO.iodata_to_binary() |> skip(),
         {:ok, entries} <- definitions(rest, []) do
      {:ok, Enum.reverse(entries)}
    end
  end

  defp definitions(text, names) do
    quoted? = match?(<<q, _::binary>> when q in [?", ?`, ?[], text)

    with {:ok, name, rest} <- name(text),
         {:ok, rest} <- skip(rest),
         {:ok, rest} <- columns(rest),
         {:ok, rest} <- keyword(rest, "as"),
         {:ok, rest} <- optional(rest, "not"),
         {:ok, rest} <- optional(rest, "materialized"),
         {:ok, rest} <- body(rest),
         {:ok, rest} <- skip(rest) do
      case rest do
        "" ->
          {:ok, [{name, quoted?} | names]}

        "," <> more ->
          with {:ok, more} <- skip(more), do: definitions(more, [{name, quoted?} | names])

        _other ->
          :error
      end
    end
  end

  # Whitespace and comments.
  defp skip(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v], do: skip(rest)
  defp skip("--" <> rest), do: rest |> line_end() |> skip()

  defp skip("/*" <> rest) do
    case block_end(rest, 1) do
      {:ok, rest} -> skip(rest)
      :error -> :error
    end
  end

  defp skip(text) when is_binary(text), do: {:ok, text}
  defp skip(other), do: other

  defp line_end(text) do
    case :binary.split(text, "\n") do
      [_comment, rest] -> rest
      [_comment] -> ""
    end
  end

  # Block comments nest in PostgreSQL; counting them is safe everywhere.
  defp block_end("*/" <> rest, 1), do: {:ok, rest}
  defp block_end("*/" <> rest, depth), do: block_end(rest, depth - 1)
  defp block_end("/*" <> rest, depth), do: block_end(rest, depth + 1)
  defp block_end(<<_c, rest::binary>>, depth), do: block_end(rest, depth)
  defp block_end("", _depth), do: :error

  defp name(<<?", rest::binary>>), do: quoted(rest, ?", "")
  defp name(<<?`, rest::binary>>), do: quoted(rest, ?`, "")
  defp name(<<?[, rest::binary>>), do: quoted(rest, ?], "")

  defp name(<<c, _::binary>> = text) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} = word(text, "")
    {:ok, word, rest}
  end

  defp name(_text), do: :error

  defp quoted(<<q, q, rest::binary>>, q, acc), do: quoted(rest, q, <<acc::binary, q>>)
  defp quoted(<<q, rest::binary>>, q, acc), do: if(acc == "", do: :error, else: {:ok, acc, rest})
  defp quoted(<<c, rest::binary>>, q, acc), do: quoted(rest, q, <<acc::binary, c>>)
  defp quoted("", _q, _acc), do: :error

  defp word(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$],
       do: word(rest, <<acc::binary, c>>)

  defp word(rest, acc), do: {acc, rest}

  defp columns("(" <> rest) do
    with {:ok, rest} <- balanced(rest, 1), do: skip(rest)
  end

  defp columns(text), do: {:ok, text}

  defp keyword(text, keyword) do
    case word(text, "") do
      {word, rest} when word != "" ->
        if String.downcase(word) == keyword, do: skip(rest), else: :error

      _ ->
        :error
    end
  end

  defp optional(text, keyword) do
    case word(text, "") do
      {word, rest} when word != "" ->
        if String.downcase(word) == keyword, do: skip(rest), else: {:ok, text}

      _ ->
        {:ok, text}
    end
  end

  defp body("(" <> rest), do: balanced(rest, 1)
  defp body(_text), do: :error

  # Past a body's closing parenthesis.
  defp balanced(")" <> rest, 1), do: {:ok, rest}
  defp balanced(")" <> rest, depth), do: balanced(rest, depth - 1)
  defp balanced("(" <> rest, depth), do: balanced(rest, depth + 1)
  defp balanced("--" <> rest, depth), do: rest |> line_end() |> balanced(depth)

  defp balanced("/*" <> rest, depth) do
    with {:ok, rest} <- block_end(rest, 1), do: balanced(rest, depth)
  end

  defp balanced("'" <> rest, depth) do
    with {:ok, rest} <- string(rest), do: balanced(rest, depth)
  end

  defp balanced(<<q, rest::binary>>, depth) when q in [?", ?`] do
    with {:ok, _name, rest} <- quoted(rest, q, ""), do: balanced(rest, depth)
  end

  defp balanced("$" <> rest, depth) do
    case dollar_tag(rest, "") do
      {:ok, tag, rest} ->
        case :binary.split(rest, "$" <> tag <> "$") do
          [_string, rest] -> balanced(rest, depth)
          [_unterminated] -> :error
        end

      :none ->
        balanced(rest, depth)
    end
  end

  defp balanced(<<_c, rest::binary>>, depth), do: balanced(rest, depth)
  defp balanced("", _depth), do: :error

  defp string("''" <> rest), do: string(rest)
  defp string("'" <> rest), do: {:ok, rest}
  defp string("\\" <> _rest), do: :error
  defp string(<<_c, rest::binary>>), do: string(rest)
  defp string(""), do: :error

  # `$tag$` or `$$` opens a dollar-quoted string; `$1` is a parameter.
  defp dollar_tag("$" <> rest, tag), do: {:ok, tag, rest}

  defp dollar_tag(<<c, rest::binary>>, tag)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or (c in ?0..?9 and tag != ""),
       do: dollar_tag(rest, <<tag::binary, c>>)

  defp dollar_tag(_rest, _tag), do: :none
end
