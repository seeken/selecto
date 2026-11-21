defmodule Selecto.Domain.JoinRules do
  @moduledoc false

  # The join-entry rules the domain contract (Selecto.Domain.validate/1) and
  # the runtime join configuration (Selecto.Schema.Join) share, for
  # `joins.<path>.type` `right` / `full` and `joins.<path>.alias`
  # (docs: engine_direct_outer_joins).
  #
  #   * `right` and `full` take a direct association only: never one with
  #     `through`, `join_through` or a `join_strategy`.
  #   * `alias` is an identifier naming the join's SQL correlation. SQL
  #     reads an unquoted identifier without case, and Selecto writes join
  #     correlations unquoted, so the correlation is the alias in lower case
  #     (`BuyerRow` correlates as `buyerrow`) and an alias that would need
  #     quoting (an SQL reserved word) is refused. It does not start with
  #     `_selecto` (Selecto's generated correlations) and is not
  #     `selecto_root`; aliases are unique across the domain's join entries,
  #     nested ones included, ignoring case, and never equal to another join
  #     entry's name, which is that join's correlation.
  #   * The native enhanced join types (`self_join`, `lateral_join`,
  #     `cross_join`, `full_outer_join`, `conditional_join`) keep their own
  #     `alias` key (Selecto.EnhancedJoins); these rules do not read it.

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/
  @enhanced_types ~w(self_join lateral_join cross_join full_outer_join conditional_join)

  @doc false
  # `:right` or `:full` when the join entry declares that type (atom or
  # string, any case), otherwise nil.
  def outer_type(config) when is_map(config) do
    case value(config, :type) do
      type when type in [:right, :full] ->
        type

      type when is_binary(type) ->
        case String.downcase(type) do
          "right" -> :right
          "full" -> :full
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def outer_type(_config), do: nil

  @doc false
  # nil, or why an outer join entry cannot use `association`.
  def outer_join_problem(association, config) do
    case outer_type(config) do
      nil ->
        nil

      type ->
        cond do
          not is_map(association) ->
            nil

          present?(association, :through) or present?(association, :join_through) ->
            "#{type} joins require a direct association, not one through a bridge"

          present?(association, :join_strategy) ->
            "#{type} joins require a direct association, not one with a join_strategy"

          true ->
            nil
        end
    end
  end

  @doc false
  # The correlation an authored alias names (the alias in lower case), or
  # nil: no alias, or an enhanced join's own `alias`.
  def authored_alias(config) when is_map(config) do
    if enhanced?(config) do
      nil
    else
      case value(config, :alias) do
        nil -> nil
        alias_name when is_atom(alias_name) -> alias_name |> Atom.to_string() |> String.downcase()
        alias_name when is_binary(alias_name) -> String.downcase(alias_name)
        _other -> nil
      end
    end
  end

  def authored_alias(_config), do: nil

  @doc false
  # `[{path, code, message}]` for the join tree `joins`: invalid, reserved,
  # duplicate (ignoring case) and colliding aliases.
  def alias_problems(joins) when is_map(joins) do
    entries = entries(joins, [])

    names =
      Enum.map(entries, fn {path, _config} -> String.downcase(to_string(List.last(path))) end)

    {problems, _seen} =
      Enum.reduce(entries, {[], %{}}, fn {path, config}, {problems, seen} ->
        case if(enhanced?(config), do: :error, else: Map.fetch(config_map(config), :alias)) do
          :error ->
            {problems, seen}

          {:ok, raw} ->
            check_alias(path, raw, names, problems, seen)
        end
      end)

    Enum.reverse(problems)
  end

  def alias_problems(_joins), do: []

  defp check_alias(path, raw, names, problems, seen) do
    alias_name = if is_atom(raw) and not is_nil(raw), do: Atom.to_string(raw), else: raw
    own = String.downcase(to_string(List.last(path)))

    cond do
      not (is_binary(alias_name) and Regex.match?(@identifier, alias_name)) ->
        {[{path, :invalid_join_alias, "join alias must be an SQL identifier"} | problems], seen}

      reserved?(alias_name) ->
        {[
           {path, :invalid_join_alias, "join alias #{alias_name} is reserved by Selecto"}
           | problems
         ], seen}

      Selecto.Builder.Sql.Helpers.needs_quoting?(String.downcase(alias_name)) ->
        {[
           {path, :invalid_join_alias, "join alias #{alias_name} is an SQL reserved word"}
           | problems
         ], seen}

      Map.has_key?(seen, String.downcase(alias_name)) ->
        other = Map.fetch!(seen, String.downcase(alias_name))

        {[
           {path, :duplicate_join_alias,
            "join alias #{alias_name} is also declared by join #{Enum.join(other, ".")}"}
           | problems
         ], seen}

      String.downcase(alias_name) != own and String.downcase(alias_name) in names ->
        {[
           {path, :duplicate_join_alias,
            "join alias #{alias_name} collides with another join's correlation name"}
           | problems
         ], seen}

      true ->
        {problems, Map.put(seen, String.downcase(alias_name), Enum.map(path, &to_string/1))}
    end
  end

  defp reserved?(alias_name) do
    lower = String.downcase(alias_name)
    lower == "selecto_root" or String.starts_with?(lower, "_selecto")
  end

  # Every join entry of the tree as {path, config}, parents first, in a
  # stable order.
  defp entries(joins, prefix) when is_map(joins) do
    joins
    |> Enum.sort_by(fn {key, _config} -> to_string(key) end)
    |> Enum.flat_map(fn {key, config} ->
      path = prefix ++ [key]

      nested =
        case value(config, :joins) do
          nested when is_map(nested) -> entries(nested, path)
          _ -> []
        end

      [{path, config} | nested]
    end)
  end

  defp entries(_joins, _prefix), do: []

  # The entry with an `alias` key under :alias whether authored as an atom or
  # a string key.
  defp config_map(config) when is_map(config) do
    cond do
      Map.has_key?(config, :alias) -> %{alias: Map.get(config, :alias)}
      Map.has_key?(config, "alias") -> %{alias: Map.get(config, "alias")}
      true -> %{}
    end
  end

  defp config_map(_config), do: %{}

  defp enhanced?(config) do
    case value(config, :type) do
      type when is_atom(type) and not is_nil(type) -> Atom.to_string(type) in @enhanced_types
      type when is_binary(type) -> type in @enhanced_types
      _ -> false
    end
  end

  defp present?(map, key), do: not is_nil(value(map, key))

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_map, _key), do: nil
end
