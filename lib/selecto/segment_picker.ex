defmodule Selecto.SegmentPicker do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M

  def errors(library) do
    groups = M.map_value(library, :segment_picker_groups)
    segments = M.map_value(library, :segments) || %{}

    cond do
      is_nil(groups) ->
        []

      not is_map(groups) ->
        [error([], "segment_picker_groups must be a map")]

      true ->
        errors = Enum.flat_map(groups, fn {id, group} -> validate(id, group, segments) end)

        used =
          Enum.flat_map(groups, fn {_id, group} ->
            case M.map_value(group, :choices) do
              choices when is_list(choices) ->
                Enum.map(choices, &to_string(M.map_value(&1, :segment)))

              _ ->
                []
            end
          end)

        if length(used) == length(Enum.uniq(used)),
          do: errors,
          else: [error([], "a segment belongs to more than one picker group") | errors]
    end
  end

  defp validate(id, group, segments) when is_map(group) do
    choices = M.map_value(group, :choices)
    default = M.map_value(group, :default)
    views = M.map_value(group, :default_views)
    allowed = ~w(label description off_label choices default default_views)
    choice_ids = if is_list(choices), do: Enum.map(choices, &M.map_value(&1, :segment)), else: []

    valid_choices =
      is_list(choices) and length(choices) >= 2 and
        Enum.all?(choices, fn choice ->
          is_map(choice) and Enum.all?(Map.keys(choice), &(to_string(&1) in ~w(segment label))) and
            match?({:ok, _}, M.fetch_key(segments, M.map_value(choice, :segment))) and
            nonblank?(M.map_value(choice, :label))
        end)

    valid =
      Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*\z/, to_string(id)) and
        Enum.all?(Map.keys(group), &(to_string(&1) in allowed)) and
        nonblank?(M.map_value(group, :label)) and
        (not match?({:ok, _}, M.fetch_key(group, :description)) or
           is_binary(M.map_value(group, :description))) and
        (not match?({:ok, _}, M.fetch_key(group, :off_label)) or
           nonblank?(M.map_value(group, :off_label))) and valid_choices and
        length(Enum.uniq_by(choice_ids, &to_string/1)) == length(choice_ids) and
        (not match?({:ok, _}, M.fetch_key(group, :default)) or
           Enum.any?(choice_ids, &(to_string(&1) == to_string(default)))) and
        (is_nil(views) or
           (is_list(views) and views != [] and
              Enum.all?(views, &(to_string(&1) in ~w(detail aggregate graph)))))

    if valid, do: [], else: [error([id], "invalid segment picker group or default")]
  end

  defp validate(id, _, _), do: [error([id], "segment picker group must be a map")]
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp error(path, message),
    do: %{
      code: :invalid_query_library,
      path: [:query_library, :segment_picker_groups] ++ path,
      message: message
    }

  def resolve(library, segments, choices, view) when is_list(segments) and is_map(choices) do
    case errors(library) do
      [] -> :ok
      errors -> raise ArgumentError, Enum.map_join(errors, "; ", & &1.message)
    end

    groups = M.map_value(library, :segment_picker_groups) || %{}

    if Enum.any?(Map.keys(choices), &(not match?({:ok, _}, M.fetch_key(groups, &1)))),
      do: refuse!("unknown segment picker group")

    Enum.reduce(
      Enum.sort_by(groups, fn {id, _} -> to_string(id) end),
      %{segments: Enum.map(segments, &to_string/1), choices: %{}, defaults: %{}},
      fn {id, group}, acc ->
        allowed = Enum.map(M.map_value(group, :choices), &to_string(M.map_value(&1, :segment)))
        default = M.map_value(group, :default)
        views = M.map_value(group, :default_views)
        applies = is_nil(views) or to_string(view || :detail) in Enum.map(views, &to_string/1)

        {selected, segments} =
          case M.fetch_key(choices, id) do
            {:ok, choice} ->
              unless is_binary(choice) and (choice == "" or choice in allowed),
                do: refuse!("invalid segment-group choice")

              {if(choice == "", do: [], else: [choice]),
               Enum.reject(acc.segments, &(&1 in allowed)) ++
                 if(choice == "", do: [], else: [choice])}

            :error ->
              selected = Enum.filter(acc.segments, &(&1 in allowed))

              if selected == [] and not is_nil(default) and applies,
                do: {[to_string(default)], acc.segments ++ [to_string(default)]},
                else: {selected, acc.segments}
          end

        if length(selected) > 1, do: refuse!("segment picker group allows only one choice")
        effective = List.first(selected) || ""

        defaults =
          if effective != "" and to_string(default) == effective and applies,
            do: Map.put(acc.defaults, effective, true),
            else: acc.defaults

        %{
          segments: Enum.uniq(segments),
          choices: Map.put(acc.choices, to_string(id), effective),
          defaults: defaults
        }
      end
    )
  end

  def resolve(_, _, _, _), do: refuse!("segment_choices must be an object")

  defp refuse!(message),
    do:
      Selecto.Builder.ScopeRefusal.unsupported!(
        Selecto.Error.validation_error(message, %{code: :invalid_query_library}),
        :invalid_query_library
      )
end
