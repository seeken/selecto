defmodule Selecto.Domain.JoinRules do
  @moduledoc false

  # The join-entry rules the domain contract (Selecto.Domain.validate/1) and
  # the runtime join configuration (Selecto.Schema.Join) share, for
  # `joins.<path>.type` and `joins.<path>.alias` (docs: engine_direct_outer_joins).
  #
  #   * `type` is one of the shared join types `left` (the default),
  #     `inner`, `right`, `full` and `star_dimension`, or one of Selecto's
  #     native spellings, each the shared form under another name
  #     (normalize/1): `dimension` (a star dimension whose `dimension` key is
  #     its display field), `snowflake_dimension` (a star dimension; its
  #     normalization is nested `joins`), `self_join` (an association to the
  #     same table), `full_outer_join` (`full`), `tagging` (an association
  #     join that adds a tag-list column and a tag facet) and `hierarchical`
  #     (`hierarchy_type: :adjacency_list` only). Anything else refuses:
  #     unknown types never fall back to LEFT, and the removed families
  #     (`cross_join`, `lateral_join`, `conditional_join`, normalization
  #     lists, `materialized_path` and `closure_table` hierarchies) name what
  #     replaces them.
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

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/

  @shared_types ~w(left inner right full star_dimension)
  @native_types ~w(dimension snowflake_dimension self_join full_outer_join tagging hierarchical)

  @removed_types %{
    "cross_join" =>
      "cross_join was removed; declare an association join (a cartesian product is not a join " <>
        "Selecto renders)",
    "lateral_join" =>
      "the raw-SQL lateral_join join type was removed; use query_members.laterals or the " <>
        "association join_strategy lateral_lookup",
    "conditional_join" =>
      "conditional_join was removed; declare the comparisons as the association's conditions"
  }

  # Keys of the removed native forms, refused wherever they still appear.
  @self_join_keys ~w(self_key target_key condition_type)
  @full_outer_keys ~w(left_key right_key condition_type)

  @doc false
  # The shared and native join type names Selecto renders.
  def types, do: @shared_types ++ @native_types

  @doc false
  # `{:ok, config}` with `type` normalized to an atom of the shared or native
  # vocabulary and each native alias rewritten to the shared form it names,
  # or `{:error, message}`.
  #
  #   * absent / nil / left -> :left; inner, right, full, star_dimension
  #   * dimension -> :star_dimension with `display_field` from `dimension`
  #   * snowflake_dimension -> :star_dimension (`normalization_joins` refuses)
  #   * self_join -> :left; full_outer_join -> :full (their own key forms refuse)
  #   * tagging -> :tagging; hierarchical -> :hierarchical (adjacency_list only)
  def normalize(config) when is_map(config) do
    case type_name(value(config, :type)) do
      {:ok, nil} ->
        {:ok, config}

      {:ok, name} when name in @shared_types ->
        {:ok, put_type(config, String.to_existing_atom(name))}

      {:ok, "dimension"} ->
        case value(config, :dimension) do
          nil ->
            {:error, "dimension joins require the dimension key (their display field)"}

          dimension ->
            {:ok,
             config
             |> drop(:dimension)
             |> Map.put_new(:display_field, dimension)
             |> put_type(:star_dimension)}
        end

      {:ok, "snowflake_dimension"} ->
        if value(config, :normalization_joins) not in [nil, []],
          do:
            {:error,
             "snowflake normalization_joins were removed; declare the normalized tables as " <>
               "nested joins of the dimension"},
          else: {:ok, config |> drop(:normalization_joins) |> put_type(:star_dimension)}

      {:ok, "self_join"} ->
        refuse_keys(config, @self_join_keys, "self_join", :left)

      {:ok, "full_outer_join"} ->
        refuse_keys(config, @full_outer_keys, "full_outer_join", :full)

      {:ok, "tagging"} ->
        {:ok, put_type(config, :tagging)}

      {:ok, "hierarchical"} ->
        case type_name(value(config, :hierarchy_type)) do
          {:ok, name} when name in [nil, "adjacency_list"] ->
            {:ok, config |> put_type(:hierarchical) |> Map.put(:hierarchy_type, :adjacency_list)}

          {:ok, name} when name in ["materialized_path", "closure_table"] ->
            {:error,
             "#{name} hierarchies were removed; express the tree with a recursive query member " <>
               "(query_members.ctes kind recursive)"}

          _ ->
            {:error, "unknown hierarchy_type #{inspect(value(config, :hierarchy_type))}"}
        end

      {:ok, name} ->
        case Map.fetch(@removed_types, name) do
          {:ok, message} -> {:error, message}
          :error -> {:error, unknown_type_message(value(config, :type))}
        end

      :error ->
        {:error, unknown_type_message(value(config, :type))}
    end
  end

  def normalize(_config), do: {:error, "join configuration must be a map"}

  @doc false
  # `{:ok, type}` for a non-association (custom) join's keyword type, or
  # `{:error, message}`.
  def custom_type(config) do
    case type_name(value(config, :type)) do
      {:ok, nil} -> {:ok, :left}
      {:ok, name} when name in ~w(left inner right full) -> {:ok, String.to_existing_atom(name)}
      _ -> {:error, unknown_type_message(value(config, :type))}
    end
  end

  defp unknown_type_message(type),
    do:
      "unsupported join type #{inspect(type)}; expected one of " <>
        Enum.join(@shared_types ++ @native_types, ", ")

  defp refuse_keys(config, keys, kind, type) do
    case Enum.filter(keys, &present?(config, String.to_atom(&1))) do
      [] ->
        {:ok, put_type(config, type)}

      found ->
        {:error,
         "#{kind} joins are association joins; #{Enum.join(found, ", ")} " <>
           "#{if length(found) == 1, do: "is", else: "are"} no longer read (use the " <>
           "association's owner_key / related_key and the join type)"}
    end
  end

  defp type_name(nil), do: {:ok, nil}

  defp type_name(type) when is_atom(type),
    do: {:ok, type |> Atom.to_string() |> String.downcase()}

  defp type_name(type) when is_binary(type), do: {:ok, String.downcase(type)}
  defp type_name(_type), do: :error

  defp put_type(config, type), do: config |> drop(:type) |> Map.put(:type, type)

  defp drop(config, key), do: config |> Map.delete(key) |> Map.delete(Atom.to_string(key))

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
  # The correlation an authored alias names (the alias in lower case), or nil.
  def authored_alias(config) when is_map(config) do
    case value(config, :alias) do
      nil -> nil
      alias_name when is_atom(alias_name) -> alias_name |> Atom.to_string() |> String.downcase()
      alias_name when is_binary(alias_name) -> String.downcase(alias_name)
      _other -> nil
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
        case Map.fetch(config_map(config), :alias) do
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

  defp present?(map, key), do: not is_nil(value(map, key))

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_map, _key), do: nil
end
