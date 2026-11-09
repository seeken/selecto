defmodule Selecto.SQL.Params do
  @moduledoc false
  # Utilities for turning an iodata tree with {:param, value} markers into
  # final SQL using the configured adapter's placeholder strategy.
  #
  # Extended in Phase 1 to support CTE markers for advanced join patterns.

  # import Selecto.Types - removed to avoid circular dependency

  @type fragment :: iodata() | {:param, any()} | {:cte, String.t(), iodata()}

  @spec finalize(iodata() | [fragment], Keyword.t()) :: {String.t(), [any()]}
  def finalize(fragments, opts \\ []) do
    adapter = Keyword.fetch!(opts, :adapter)
    placeholder_fun = placeholder_fun(adapter)

    {iodata, params, _idx} =
      traverse(List.wrap(fragments), {[], [], 0}, placeholder_fun)

    {IO.iodata_to_binary(:lists.reverse(iodata)), :lists.reverse(params)}
  end

  @doc """
  Handle CTE markers in iodata structures for advanced join patterns.

  CTE markers are processed before main query finalization to properly
  coordinate parameter numbering between CTEs and main query.

  Returns: {processed_ctes, main_sql, final_params}
  """
  @spec finalize_with_ctes(iodata() | [fragment], Keyword.t()) ::
          {[{String.t(), String.t()}], String.t(), [any()]}
  def finalize_with_ctes(iodata_with_ctes, opts \\ []) do
    adapter = Keyword.fetch!(opts, :adapter)
    placeholder_fun = placeholder_fun(adapter)
    {cte_sections, main_iodata, extracted_params} = extract_ctes(List.wrap(iodata_with_ctes))

    # Process CTEs first to establish parameter numbering baseline
    {processed_ctes, cte_params} =
      Enum.map_reduce(cte_sections, [], fn {cte_name, cte_iodata}, acc_params ->
        {cte_sql, cte_specific_params} = finalize(cte_iodata, adapter: adapter)

        {{cte_name, cte_sql}, acc_params ++ cte_specific_params}
      end)

    # Process main query with parameter offset to avoid conflicts
    param_offset = length(cte_params)

    {main_sql, main_specific_params} =
      finalize_with_offset(main_iodata, param_offset, placeholder_fun)

    # Combine all parameters in correct order
    final_params = cte_params ++ main_specific_params ++ extracted_params
    {processed_ctes, main_sql, final_params}
  end

  @doc false
  def rebind_finalized(sql, [], adapter) when is_binary(sql) and is_atom(adapter), do: sql

  def rebind_finalized(sql, params, adapter)
      when is_binary(sql) and is_list(params) and is_atom(adapter) do
    placeholder = placeholder_fun(adapter)

    placeholders =
      params
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} -> placeholder.(index, value) |> IO.iodata_to_binary() end)

    # Only the code is rebound: a placeholder-like sequence in a string, a
    # quoted name, a comment or a dollar quote stays text.
    pieces = pieces(sql, Selecto.AdapterSupport.adapter_name(adapter))

    # A placeholder that names no index (`?`) repeats; numbered ones (`$1`)
    # are rebound by number, however often each appears.
    if IO.iodata_to_binary(placeholder.(1, hd(params))) ==
         IO.iodata_to_binary(placeholder.(2, hd(params))) do
      rebind_repeated(pieces, params, hd(placeholders))
    else
      rebind_numbered(pieces, params, placeholders)
    end
  end

  # The text as {:code, text} and {:text, text} pieces, in order: strings,
  # quoted names, comments and dollar quotes as the dialect reads them are
  # text. Unterminated, the rest is text.
  defp pieces(sql, dialect), do: scan(sql, dialect, "", [])

  defguardp word_byte?(c)
            when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$] or c >= 0x80

  defguardp my?(d) when d in [:mysql, :mariadb]

  defp scan("", _d, code, out), do: Enum.reverse(code_piece(out, code))

  defp scan("'" <> rest, d, code, out) do
    escapes? = my?(d) or (d == :postgresql and escape_prefix?(code))
    {text, rest} = quoted_end(rest, ?', escapes?, "'")
    scan(rest, d, "", [{:text, text} | code_piece(out, code)])
  end

  defp scan("\"" <> rest, d, code, out) do
    {text, rest} = quoted_end(rest, ?", my?(d), "\"")
    scan(rest, d, "", [{:text, text} | code_piece(out, code)])
  end

  defp scan("`" <> rest, d, code, out) do
    {text, rest} = quoted_end(rest, ?`, false, "`")
    scan(rest, d, "", [{:text, text} | code_piece(out, code)])
  end

  defp scan("[" <> rest, :sqlite, code, out) do
    {text, rest} = until(rest, "]", "[")
    scan(rest, :sqlite, "", [{:text, text} | code_piece(out, code)])
  end

  defp scan("--" <> rest, d, code, out) do
    if my?(d) and not match?(<<c, _::binary>> when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v], rest) and
         rest != "" do
      scan(rest, d, code <> "--", out)
    else
      {text, rest} = line(rest, d in [:postgresql, :duckdb], "--")
      scan(rest, d, "", [{:text, text} | code_piece(out, code)])
    end
  end

  defp scan("#" <> rest, d, code, out) when my?(d) do
    {text, rest} = line(rest, false, "#")
    scan(rest, d, "", [{:text, text} | code_piece(out, code)])
  end

  defp scan("/*" <> rest, d, code, out) do
    if my?(d) and (match?("!" <> _, rest) or match?("M!" <> _, rest)) do
      scan(rest, d, code <> "/*", out)
    else
      {text, rest} = block(rest, d == :postgresql, 1, "/*")
      scan(rest, d, "", [{:text, text} | code_piece(out, code)])
    end
  end

  defp scan("$" <> rest, d, code, out) when d in [:postgresql, :duckdb] do
    with false <- after_word?(code),
         {:ok, tag, after_tag} <- dollar_tag(rest, "") do
      delimiter = "$" <> tag <> "$"

      {text, rest} =
        case :binary.split(after_tag, delimiter) do
          [body, rest] -> {delimiter <> body <> delimiter, rest}
          [body] -> {delimiter <> body, ""}
        end

      scan(rest, d, "", [{:text, text} | code_piece(out, code)])
    else
      _code -> scan(rest, d, code <> "$", out)
    end
  end

  defp scan(<<c, rest::binary>>, d, code, out), do: scan(rest, d, <<code::binary, c>>, out)

  defp code_piece(out, ""), do: out
  defp code_piece(out, code), do: [{:code, code} | out]

  defp after_word?(""), do: false
  defp after_word?(code), do: word_byte?(:binary.last(code))

  # `E'...'` (not inside a longer word) reads backslash escapes.
  defp escape_prefix?(code) do
    case byte_size(code) do
      0 -> false
      1 -> code in ["E", "e"]
      n -> :binary.part(code, n - 1, 1) in ["E", "e"] and not word_byte?(:binary.at(code, n - 2))
    end
  end

  defp quoted_end(<<q, q, rest::binary>>, q, escapes?, acc),
    do: quoted_end(rest, q, escapes?, <<acc::binary, q, q>>)

  defp quoted_end(<<q, rest::binary>>, q, _escapes?, acc), do: {<<acc::binary, q>>, rest}

  defp quoted_end(<<?\\, c, rest::binary>>, q, true, acc),
    do: quoted_end(rest, q, true, <<acc::binary, ?\\, c>>)

  defp quoted_end(<<c, rest::binary>>, q, escapes?, acc),
    do: quoted_end(rest, q, escapes?, <<acc::binary, c>>)

  defp quoted_end("", _q, _escapes?, acc), do: {acc, ""}

  defp until(text, stop, acc) do
    case :binary.split(text, stop) do
      [body, rest] -> {acc <> body <> stop, rest}
      [body] -> {acc <> body, ""}
    end
  end

  defp line(<<?\n, rest::binary>>, _cr?, acc), do: {<<acc::binary, ?\n>>, rest}
  defp line(<<?\r, rest::binary>>, true, acc), do: {<<acc::binary, ?\r>>, rest}
  defp line(<<c, rest::binary>>, cr?, acc), do: line(rest, cr?, <<acc::binary, c>>)
  defp line("", _cr?, acc), do: {acc, ""}

  defp block("*/" <> rest, _nests?, 1, acc), do: {acc <> "*/", rest}
  defp block("*/" <> rest, nests?, depth, acc), do: block(rest, nests?, depth - 1, acc <> "*/")
  defp block("/*" <> rest, true, depth, acc), do: block(rest, true, depth + 1, acc <> "/*")

  defp block(<<c, rest::binary>>, nests?, depth, acc),
    do: block(rest, nests?, depth, <<acc::binary, c>>)

  defp block("", _nests?, _depth, acc), do: {acc, ""}

  defp dollar_tag("$" <> rest, tag), do: {:ok, tag, rest}

  defp dollar_tag(<<c, rest::binary>>, tag)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80 or (c in ?0..?9 and tag != ""),
       do: dollar_tag(rest, <<tag::binary, c>>)

  defp dollar_tag(_rest, _tag), do: :none

  # Process iodata with parameter offset for coordinated numbering
  defp finalize_with_offset(fragments, offset, placeholder_fun) do
    {iodata, params, _idx} =
      traverse_with_offset(List.wrap(fragments), {[], [], offset}, placeholder_fun)

    {IO.iodata_to_binary(:lists.reverse(iodata)), :lists.reverse(params)}
  end

  # Extract CTE markers from iodata structure
  defp extract_ctes(iodata) do
    extract_ctes_recursive(iodata, {[], [], []})
  end

  defp extract_ctes_recursive([], {ctes, main_iodata, params}) do
    {Enum.reverse(ctes), Enum.reverse(main_iodata), Enum.reverse(params)}
  end

  defp extract_ctes_recursive([{:cte, name, cte_iodata} | rest], {ctes, main_iodata, params}) do
    extract_ctes_recursive(rest, {[{name, cte_iodata} | ctes], main_iodata, params})
  end

  defp extract_ctes_recursive([{:param, value} | rest], {ctes, main_iodata, params}) do
    extract_ctes_recursive(rest, {ctes, main_iodata, [value | params]})
  end

  defp extract_ctes_recursive([head | rest], {ctes, main_iodata, params}) when is_list(head) do
    {inner_ctes, inner_main, inner_params} = extract_ctes_recursive(head, {[], [], []})
    combined_ctes = inner_ctes ++ ctes
    combined_main = [inner_main | main_iodata]
    combined_params = Enum.reverse(inner_params) ++ params
    extract_ctes_recursive(rest, {combined_ctes, combined_main, combined_params})
  end

  defp extract_ctes_recursive([head | rest], {ctes, main_iodata, params}) do
    extract_ctes_recursive(rest, {ctes, [head | main_iodata], params})
  end

  # Traverse with parameter offset support
  defp traverse_with_offset([h | t], {acc_io, acc_params, idx}, placeholder_fun) do
    case h do
      {:param, v} ->
        placeholder = placeholder_fun.(idx + 1, v)

        traverse_with_offset(
          t,
          {[placeholder | acc_io], [v | acc_params], idx + 1},
          placeholder_fun
        )

      list when is_list(list) ->
        {inner_io, inner_params, inner_idx} =
          traverse_with_offset(list, {[], [], idx}, placeholder_fun)

        traverse_with_offset(
          t,
          {[Enum.reverse(inner_io) | acc_io], inner_params ++ acc_params, inner_idx},
          placeholder_fun
        )

      bin when is_binary(bin) ->
        traverse_with_offset(t, {[bin | acc_io], acc_params, idx}, placeholder_fun)

      other ->
        traverse_with_offset(t, {[to_string(other) | acc_io], acc_params, idx}, placeholder_fun)
    end
  end

  defp traverse_with_offset([], state, _placeholder_fun), do: state

  defp traverse([h | t], {acc_io, acc_params, idx}, placeholder_fun) do
    case h do
      {:param, v} ->
        placeholder = placeholder_fun.(idx + 1, v)
        traverse(t, {[placeholder | acc_io], [v | acc_params], idx + 1}, placeholder_fun)

      list when is_list(list) ->
        {inner_io, inner_params, inner_idx} = traverse(list, {[], [], idx}, placeholder_fun)

        traverse(
          t,
          {[Enum.reverse(inner_io) | acc_io], inner_params ++ acc_params, inner_idx},
          placeholder_fun
        )

      bin when is_binary(bin) ->
        traverse(t, {[bin | acc_io], acc_params, idx}, placeholder_fun)

      other ->
        # Allow numbers/atoms to be coerced; they should rarely appear directly.
        traverse(t, {[to_string(other) | acc_io], acc_params, idx}, placeholder_fun)
    end
  end

  defp traverse([], state, _placeholder_fun), do: state

  defp rebind_repeated(pieces, params, placeholder) do
    parts =
      Enum.flat_map(pieces, fn
        {:text, text} ->
          [text]

        {:code, code} ->
          code |> String.split(placeholder, trim: false) |> Enum.intersperse(:placeholder)
      end)

    if Enum.count(parts, &(&1 == :placeholder)) == length(params) do
      {rebound, []} =
        Enum.map_reduce(parts, params, fn
          :placeholder, [value | rest] -> {{:param, value}, rest}
          text, rest -> {text, rest}
        end)

      rebound
    else
      raise ArgumentError,
            "adapter placeholder count does not match the finalized parameter count"
    end
  end

  defp rebind_numbered(pieces, params, placeholders) do
    values = placeholders |> Enum.zip(params) |> Map.new()

    pattern =
      placeholders
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")
      |> then(&Regex.compile!("((?<![A-Za-z0-9_$\\x80-\\xff])(?:#{&1})(?![0-9]))"))

    parts =
      Enum.flat_map(pieces, fn
        {:text, text} -> [{:text, text}]
        {:code, code} -> Regex.split(pattern, code, include_captures: true, trim: false)
      end)

    rebound =
      Enum.map(parts, fn
        {:text, text} ->
          text

        part ->
          case Map.fetch(values, part) do
            {:ok, value} -> {:param, value}
            :error -> part
          end
      end)

    # Every parameter is bound at least once; a placeholder may repeat.
    if Enum.all?(placeholders, &(&1 in parts)) do
      rebound
    else
      raise ArgumentError,
            "adapter placeholder count does not match the finalized parameter count"
    end
  end

  defp placeholder_fun(adapter) when is_atom(adapter) do
    if Selecto.AdapterSupport.callback_available?(adapter, :placeholder, 1) do
      if Selecto.AdapterSupport.callback_available?(adapter, :parameter_placeholder, 2) do
        &adapter.parameter_placeholder/2
      else
        fn index, _value -> adapter.placeholder(index) end
      end
    else
      raise ArgumentError,
            "adapter #{inspect(adapter)} must implement placeholder/1 before SQL finalization"
    end
  end

  defp placeholder_fun(adapter),
    do:
      raise(
        ArgumentError,
        "SQL finalization requires an explicit adapter, got: #{inspect(adapter)}"
      )
end
