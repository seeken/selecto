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
