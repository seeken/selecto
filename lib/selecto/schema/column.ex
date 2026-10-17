defmodule Selecto.Schema.Column do
  @moduledoc """
  Builds normalized column definitions for domain fields and join fields.

  Column configuration merges schema metadata with domain overrides, including:

  - generated `colid` values
  - human-readable display names
  - filter type overrides
  - option provider metadata
  - custom columns declared in the domain
  """

  alias Selecto.Presentation

  # Configure columns - move to column
  def configure_columns(join, fields, source, domain) do
    columns =
      fields
      |> Enum.map(&configure(&1, join, source, domain))

    custom_columns = get_custom_columns(join, source, domain)

    (columns ++ custom_columns) |> Map.new()
  end

  ### how to do custom columns?
  def get_custom_columns(join, _source, domain) do
    Map.get(domain, :custom_columns, %{})
    |> Enum.reduce([], fn {f, v}, acc ->
      [
        {
          f,
          v
          |> Map.merge(%{
            colid: f,
            requires_join: join
          })
          |> Map.put_new(:type, :custom_column)
          |> Presentation.normalize_column()
        }
        | acc
      ]
    end)
  end

  defp add_filter_type(col, %{filter_type: ft}) do
    Map.put(col, :filter_type, ft)
  end

  defp add_filter_type(col, _config) do
    col
  end

  defp add_option_provider(col, %{option_provider: provider}) do
    Map.merge(col, %{
      type: :select_options,
      option_provider: provider,
      multiple: Map.get(col, :multiple, false),
      searchable: Map.get(col, :searchable, true)
    })
  end

  defp add_option_provider(col, _config) do
    col
  end

  def configure(field, join, source, domain) do
    # Normalize atom and string field identifiers.
    field_str = if is_atom(field), do: Atom.to_string(field), else: field
    # Try to get atom version if field is string (for map lookup)
    field_atom =
      if is_atom(field) do
        field
      else
        try do
          String.to_existing_atom(field)
        rescue
          ArgumentError -> nil
        end
      end

    # Try both string and atom keys for column config lookup
    columns_map = Map.get(domain, :columns, %{})

    config =
      if field_atom do
        Map.get(columns_map, field_atom, Map.get(columns_map, field_str, %{}))
      else
        Map.get(columns_map, field_str, %{})
      end

    colid =
      Map.get(
        config,
        :id,
        case join do
          :selecto_root ->
            field_str

          _ ->
            # Normalize atom and string join identifiers.
            join_str = if is_atom(join), do: Atom.to_string(join), else: join
            "#{join_str}.#{field_str}"
        end
      )

    name = resolve_assigned_name(config, field)

    # Add appropriate prefix based on join type
    display_name =
      case join do
        :selecto_root ->
          # For root table, use the domain name from the configuration
          "#{Map.get(domain, :name, "Domain")}: #{name}"

        _ ->
          # For joined tables, use the join name
          join_info = get_join_info(domain, join)

          join_context =
            if is_map(join_info) and map_size(join_info) > 0 do
              join_info
            else
              domain
            end

          join_name = resolve_assigned_name(join_context, join)
          "#{join_name}: #{name}"
      end

    # Get column type from source, handling both atom and string field keys
    source_col =
      if field_atom do
        Map.get(source.columns, field_atom, Map.get(source.columns, field_str))
      else
        Map.get(source.columns, field_str)
      end

    base_col = %{
      colid: colid,
      field: field,
      name: display_name,
      label: Map.get(config, :label, Map.get(source_col, :label)),
      type: source_col.type,
      requires_join: join,
      format: Map.get(config, :format),
      default_grouping:
        Map.get(config, :default_grouping, Map.get(source_col, :default_grouping)),
      default_aggregate:
        Map.get(config, :default_aggregate, Map.get(source_col, :default_aggregate)),
      icon: Map.get(config, :icon, Map.get(source_col, :icon)),
      icon_family: Map.get(config, :icon_family, Map.get(source_col, :icon_family)),
      presentation: merge_presentation(config, source_col),
      presentation_type:
        Map.get(config, :presentation_type, Map.get(source_col, :presentation_type)),
      datetime_storage:
        Map.get(config, :datetime_storage, Map.get(source_col, :datetime_storage)),
      epoch_storage: Map.get(config, :epoch_storage, Map.get(source_col, :epoch_storage))
    }

    base_col =
      case Map.get(source_col, :computed) do
        computed when is_map(computed) ->
          case Map.get(computed, :kind, Map.get(computed, "kind")) do
            kind when kind in [:predicate, "predicate"] ->
              expression = Map.get(computed, :expression, Map.get(computed, "expression"))

              Map.put(
                base_col,
                :select,
                {:computed_predicate, qualify_predicate(expression, join_prefix(join))}
              )

            kind when kind in [:expression, "expression"] ->
              expression = Map.get(computed, :expression, Map.get(computed, "expression"))

              Map.put(
                base_col,
                :select,
                {:computed_value, qualify_value(expression, join_prefix(join))}
              )

            _ ->
              base_col
          end

        _ ->
          base_col
      end

    base_col = Map.put(base_col, :internal, Map.get(source_col, :internal, false))

    {
      colid,
      base_col
      |> add_filter_type(config)
      |> add_option_provider(config)
      |> Presentation.normalize_column()
    }
  end

  defp merge_presentation(config, source_col) do
    source_presentation = Map.get(source_col, :presentation, %{})
    config_presentation = Map.get(config, :presentation, %{})

    case {source_presentation, config_presentation} do
      {%{} = source_presentation, %{} = config_presentation} ->
        Map.merge(source_presentation, config_presentation)

      {%{} = source_presentation, _} ->
        source_presentation

      {_, %{} = config_presentation} ->
        config_presentation

      _ ->
        nil
    end
  end

  # stolen from phoenix :D
  def humanize(atom) when is_atom(atom),
    do: humanize(Atom.to_string(atom))

  def humanize(bin) when is_binary(bin) do
    bin |> String.replace("_", " ") |> String.capitalize()
  end

  defp get_join_info(domain, join) do
    joins = Map.get(domain, :joins, %{})

    case Map.get(joins, join) do
      nil when is_binary(join) ->
        atom_join =
          try do
            String.to_existing_atom(join)
          rescue
            ArgumentError -> nil
          end

        if atom_join, do: Map.get(joins, atom_join, %{}), else: %{}

      nil when is_atom(join) ->
        Map.get(joins, Atom.to_string(join), %{})

      join_info ->
        join_info
    end
  end

  defp resolve_assigned_name(config, fallback) when is_map(config) do
    case Map.get(config, :name, Map.get(config, "name")) do
      name when is_binary(name) and name != "" -> name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _ -> humanize(fallback)
    end
  end

  # A computed column of a joined schema names its own relation's fields
  # (`site`, `is_s1`); its column is registered as "<join>.<field>", so its
  # expression is qualified to the join the same way. Already-qualified
  # paths are kept. The root's expressions are unchanged.
  defp join_prefix(:selecto_root), do: nil
  defp join_prefix(nil), do: nil
  defp join_prefix(join) when is_atom(join), do: Atom.to_string(join) <> "."
  defp join_prefix(join) when is_binary(join), do: join <> "."

  defp qualify_field(field, nil), do: field

  defp qualify_field(field, prefix)
       when is_atom(field) and not is_nil(field) and not is_boolean(field),
       do: qualify_field(Atom.to_string(field), prefix)

  defp qualify_field(field, prefix) when is_binary(field) do
    if String.contains?(field, "."), do: field, else: prefix <> field
  end

  defp qualify_field(field, _prefix), do: field

  @doc false
  # The computed predicate AST with every field reference qualified by `prefix`.
  def qualify_predicate(expression, nil), do: expression

  def qualify_predicate([op, operands], prefix)
      when op in [:and, :or, "and", "or"] and is_list(operands),
      do: [op, Enum.map(operands, &qualify_predicate(&1, prefix))]

  def qualify_predicate([op, operand], prefix) when op in [:not, "not"],
    do: [op, qualify_predicate(operand, prefix)]

  def qualify_predicate([op, field], prefix)
      when op in [:is_null, "is_null", :not_null, "not_null"],
      do: [op, qualify_field(field, prefix)]

  def qualify_predicate([op, field | values], prefix) when is_atom(op) or is_binary(op),
    do: [op, qualify_field(field, prefix) | Enum.map(values, &qualify_operand(&1, prefix))]

  def qualify_predicate(expression, _prefix), do: expression

  defp qualify_operand([tag, field], prefix) when tag in [:field, "field"],
    do: [tag, qualify_field(field, prefix)]

  defp qualify_operand(value, _prefix), do: value

  @doc false
  # The computed value AST with every field path qualified by `prefix`
  # (CASE conditions are predicates).
  def qualify_value(expression, nil), do: expression

  def qualify_value([tag, path], prefix) when tag in [:field, "field"],
    do: [tag, qualify_field(path, prefix)]

  def qualify_value([tag | _] = literal, _prefix) when tag in [:literal, "literal"], do: literal

  def qualify_value([tag, path, segments], prefix) when tag in [:json_text, "json_text"],
    do: [tag, qualify_field(path, prefix), segments]

  def qualify_value([tag, value, type], prefix) when tag in [:cast, "cast"],
    do: [tag, qualify_value(value, prefix), type]

  def qualify_value([tag | branches], prefix) when tag in [:case, "case"] do
    [
      tag
      | Enum.map(branches, fn
          [else_tag, value] when else_tag in [:else, "else"] ->
            [else_tag, qualify_value(value, prefix)]

          [condition, value] ->
            [qualify_predicate(condition, prefix), qualify_value(value, prefix)]

          other ->
            other
        end)
    ]
  end

  def qualify_value([op | arguments], prefix) when is_atom(op) or is_binary(op),
    do: [op | Enum.map(arguments, &qualify_value(&1, prefix))]

  def qualify_value(expression, _prefix), do: expression
end
