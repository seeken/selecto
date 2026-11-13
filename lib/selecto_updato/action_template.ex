defmodule SelectoUpdato.ActionTemplate do
  @moduledoc """
  Validates and resolves action execution templates.

  The template expression surface is deliberately small. For now, execution
  templates may contain literal values, nested maps/lists, input references, and
  trusted context references:

      {:input, :field}
      {:input, :field, [:trim, :blank_to_nil]}
      {:input, :score, [{:add, 1}, {:multiply, 2}]}
      {:input, :due_on, [{:date_add, 7, :day}]}
      {:context, :tenant_id}
      {:fallback, [{:input, :note, [:trim, :blank_to_nil]}, "No note"]}
      ["input", "field", ["trim"]]
      ["input", "score", [["add", 1], ["multiply", 2]]]
      ["input", "due_on", [["date_add", 7, "day"]]]
      ["context", "tenant_id"]
      ["fallback", [["input", "note"], "No note"]]

  Keeping this centralized makes future expression growth explicit instead of
  letting action execution metadata grow ad hoc syntax in the planner.
  """

  @simple_input_transforms ~w(blank_to_nil downcase trim upcase)
  @numeric_input_transforms ~w(add subtract multiply divide)
  @date_input_transforms ~w(date_add date_subtract)
  @supported_input_transforms @simple_input_transforms ++
                                @numeric_input_transforms ++ @date_input_transforms

  @type result :: {:ok, term()} | {:error, map()}

  @doc """
  Returns the action input transforms currently supported by template input
  placeholders.
  """
  @spec supported_input_transforms() :: [String.t()]
  def supported_input_transforms, do: @supported_input_transforms

  @doc """
  Validates template expression shape without requiring submitted inputs.
  """
  @spec validate(term(), list()) :: :ok | {:error, map()}
  def validate(template, path \\ [])

  def validate(["input", _input_id], _path), do: :ok
  def validate([:input, _input_id], _path), do: :ok
  def validate({:input, _input_id}, _path), do: :ok

  def validate(["input", _input_id, transforms], path),
    do: validate_input_transforms(transforms, path)

  def validate([:input, _input_id, transforms], path),
    do: validate_input_transforms(transforms, path)

  def validate({:input, _input_id, transforms}, path),
    do: validate_input_transforms(transforms, path)

  def validate(["input" | _rest], path), do: invalid_input_placeholder(path)
  def validate([:input | _rest], path), do: invalid_input_placeholder(path)

  def validate(["context", _context_id], _path), do: :ok
  def validate([:context, _context_id], _path), do: :ok
  def validate({:context, _context_id}, _path), do: :ok

  def validate(["context", _context_id, transforms], path),
    do: validate_input_transforms(transforms, path)

  def validate([:context, _context_id, transforms], path),
    do: validate_input_transforms(transforms, path)

  def validate({:context, _context_id, transforms}, path),
    do: validate_input_transforms(transforms, path)

  def validate(["context" | _rest], path), do: invalid_context_placeholder(path)
  def validate([:context | _rest], path), do: invalid_context_placeholder(path)

  def validate(["fallback", candidates], path), do: validate_fallback_candidates(candidates, path)
  def validate([:fallback, candidates], path), do: validate_fallback_candidates(candidates, path)
  def validate({:fallback, candidates}, path), do: validate_fallback_candidates(candidates, path)

  def validate(["fallback" | _rest], path), do: invalid_fallback_expression(path)
  def validate([:fallback | _rest], path), do: invalid_fallback_expression(path)
  def validate({:fallback, _left, _right}, path), do: invalid_fallback_expression(path)

  def validate(%{} = template, path) do
    template
    |> sorted_entries()
    |> Enum.reduce_while(:ok, fn {field, value}, :ok ->
      case validate(value, path ++ [field_name(field)]) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def validate(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def validate(_value, _path), do: :ok

  @doc """
  Resolves input placeholders against normalized action inputs and trusted
  context placeholders against host-provided context.

  The template is validated before resolution so unsupported expression syntax
  fails consistently before any value-level transform checks run.
  """
  @spec resolve(term(), map(), list()) :: result()
  def resolve(template, inputs, path \\ []) do
    resolve(template, inputs, %{}, path)
  end

  @spec resolve(term(), map(), map() | keyword(), list()) :: result()
  def resolve(template, inputs, trusted_context, path) do
    with :ok <- validate(template, path) do
      do_resolve(template, inputs, context_map(trusted_context), path)
    end
  end

  defp do_resolve(["input", input_id], inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path)

  defp do_resolve([:input, input_id], inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path)

  defp do_resolve({:input, input_id}, inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path)

  defp do_resolve(["input", input_id, transforms], inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path, transforms)

  defp do_resolve([:input, input_id, transforms], inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path, transforms)

  defp do_resolve({:input, input_id, transforms}, inputs, _trusted_context, path),
    do: resolve_input_reference(input_id, inputs, path, transforms)

  defp do_resolve(["context", context_id], _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path)

  defp do_resolve([:context, context_id], _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path)

  defp do_resolve({:context, context_id}, _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path)

  defp do_resolve(["context", context_id, transforms], _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path, transforms)

  defp do_resolve([:context, context_id, transforms], _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path, transforms)

  defp do_resolve({:context, context_id, transforms}, _inputs, trusted_context, path),
    do: resolve_context_reference(context_id, trusted_context, path, transforms)

  defp do_resolve(["fallback", candidates], inputs, trusted_context, path),
    do: resolve_fallback(candidates, inputs, trusted_context, path)

  defp do_resolve([:fallback, candidates], inputs, trusted_context, path),
    do: resolve_fallback(candidates, inputs, trusted_context, path)

  defp do_resolve({:fallback, candidates}, inputs, trusted_context, path),
    do: resolve_fallback(candidates, inputs, trusted_context, path)

  defp do_resolve(%{} = template, inputs, trusted_context, path) do
    template
    |> sorted_entries()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, acc} ->
      case do_resolve(value, inputs, trusted_context, path ++ [field_name(field)]) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, field, resolved)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp do_resolve(values, inputs, trusted_context, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case do_resolve(value, inputs, trusted_context, path ++ [index]) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp do_resolve(value, _inputs, _trusted_context, _path), do: {:ok, value}

  defp resolve_input_reference(input_id, inputs, path, transforms) do
    with {:ok, value} <- resolve_input_reference(input_id, inputs, path) do
      apply_input_transforms(value, transforms, path)
    end
  end

  defp resolve_input_reference(input_id, inputs, path) do
    input_id = id(input_id)

    case fetch_value(inputs, input_id) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         error(
           :missing_action_input_reference,
           path,
           "Action execution references missing input #{inspect(input_id)}.",
           input: input_id
         )}
    end
  end

  defp resolve_context_reference(context_id, trusted_context, path, transforms) do
    with {:ok, value} <- resolve_context_reference(context_id, trusted_context, path) do
      apply_input_transforms(value, transforms, path)
    end
  end

  defp resolve_context_reference(context_id, trusted_context, path) do
    context_id = id(context_id)

    case fetch_value(trusted_context, context_id) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         error(
           :missing_action_context_reference,
           path,
           "Action execution references missing trusted context #{inspect(context_id)}.",
           context: context_id
         )}
    end
  end

  defp validate_fallback_candidates(candidates, path) when is_list(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {candidate, index}, :ok ->
      case validate(candidate, path ++ ["fallback", index]) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_fallback_candidates(_candidates, path), do: invalid_fallback_expression(path)

  defp resolve_fallback(candidates, inputs, trusted_context, path) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {candidate, index}, _acc ->
      case do_resolve(candidate, inputs, trusted_context, path ++ ["fallback", index]) do
        {:ok, nil} ->
          {:cont, {:ok, nil}}

        {:ok, value} ->
          {:halt, {:ok, value}}

        {:error, %{code: :missing_action_input_reference}} ->
          {:cont, {:ok, nil}}

        {:error, %{code: :missing_action_context_reference}} ->
          {:cont, {:ok, nil}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp validate_input_transforms(transforms, path) do
    transforms
    |> transform_steps()
    |> Enum.reduce_while(:ok, fn transform, :ok ->
      case parse_transform(transform, path) do
        {:ok, _transform} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_input_transforms(value, transforms, path) do
    transforms
    |> transform_steps()
    |> Enum.reduce_while({:ok, value}, fn transform, {:ok, value} ->
      case apply_input_transform(value, transform, path) do
        {:ok, value} -> {:cont, {:ok, value}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_input_transform(value, transform, path) do
    with {:ok, parsed} <- parse_transform(transform, path) do
      apply_parsed_transform(value, parsed, path)
    end
  end

  defp apply_parsed_transform(value, {:simple, transform}, path) do
    case transform do
      "trim" ->
        string_transform(value, transform, path, &String.trim/1)

      "downcase" ->
        string_transform(value, transform, path, &String.downcase/1)

      "upcase" ->
        string_transform(value, transform, path, &String.upcase/1)

      "blank_to_nil" ->
        if value == "", do: {:ok, nil}, else: {:ok, value}
    end
  end

  defp apply_parsed_transform(value, {:numeric, transform, operand}, path) do
    with {:ok, value} <- number_value(value, transform, path) do
      case transform do
        "add" ->
          {:ok, value + operand}

        "subtract" ->
          {:ok, value - operand}

        "multiply" ->
          {:ok, value * operand}

        "divide" when operand == 0 ->
          invalid_transform_argument(
            transform,
            path,
            "Action input transform divide cannot use zero."
          )

        "divide" ->
          {:ok, value / operand}
      end
    end
  end

  defp apply_parsed_transform(value, {:date_shift, transform, amount, unit}, path) do
    date_shift(value, transform, amount, unit, path)
  end

  defp string_transform(value, _transform, _path, fun) when is_binary(value),
    do: {:ok, fun.(value)}

  defp string_transform(value, transform, path, _fun) do
    transform = id(transform)

    {:error,
     error(
       :invalid_action_input_transform_value,
       path,
       "Action input transform #{inspect(transform)} requires a string value.",
       transform: transform,
       value: value
     )}
  end

  defp transform_steps(nil), do: []

  defp transform_steps(transforms) do
    if parameterized_transform?(transforms), do: [transforms], else: List.wrap(transforms)
  end

  defp parameterized_transform?({op, _arg}), do: id(op) in @numeric_input_transforms
  defp parameterized_transform?({op, _amount, _unit}), do: id(op) in @date_input_transforms

  defp parameterized_transform?([op, _arg]) when is_atom(op) or is_binary(op),
    do: id(op) in @numeric_input_transforms

  defp parameterized_transform?([op, _amount, _unit]) when is_atom(op) or is_binary(op),
    do: id(op) in @date_input_transforms

  defp parameterized_transform?(_transform), do: false

  defp parse_transform(transform, path) when is_atom(transform) or is_binary(transform) do
    transform = id(transform)

    if transform in @simple_input_transforms do
      {:ok, {:simple, transform}}
    else
      unsupported_transform(transform, path)
    end
  end

  defp parse_transform({op, operand}, path) do
    parse_numeric_transform(id(op), operand, path)
  end

  defp parse_transform([op, operand], path) when is_atom(op) or is_binary(op) do
    parse_numeric_transform(id(op), operand, path)
  end

  defp parse_transform({op, amount, unit}, path) do
    parse_date_transform(id(op), amount, unit, path)
  end

  defp parse_transform([op, amount, unit], path) when is_atom(op) or is_binary(op) do
    parse_date_transform(id(op), amount, unit, path)
  end

  defp parse_transform(transform, path) do
    invalid_transform_argument(
      inspect(transform),
      path,
      "Action input transform #{inspect(transform)} is not shaped as a supported transform."
    )
  end

  defp parse_numeric_transform(transform, operand, path)
       when transform in @numeric_input_transforms do
    case number_argument(operand) do
      {:ok, operand} ->
        {:ok, {:numeric, transform, operand}}

      :error ->
        invalid_transform_argument(
          transform,
          path,
          "Action input transform #{inspect(transform)} requires a numeric argument.",
          argument: operand
        )
    end
  end

  defp parse_numeric_transform(transform, _operand, path),
    do: unsupported_transform(transform, path)

  defp parse_date_transform(transform, amount, unit, path)
       when transform in @date_input_transforms do
    with {:ok, amount} <- integer_argument(amount),
         {:ok, unit} <- date_unit(unit) do
      {:ok, {:date_shift, transform, amount, unit}}
    else
      :invalid_amount ->
        invalid_transform_argument(
          transform,
          path,
          "Action input transform #{inspect(transform)} requires an integer amount.",
          amount: amount
        )

      :invalid_unit ->
        invalid_transform_argument(
          transform,
          path,
          "Action input transform #{inspect(transform)} requires a supported date unit.",
          unit: id(unit),
          allowed_units: ["day", "week", "hour", "minute", "second"]
        )
    end
  end

  defp parse_date_transform(transform, _amount, _unit, path),
    do: unsupported_transform(transform, path)

  defp unsupported_transform(transform, path) do
    {:error,
     error(
       :unsupported_action_input_transform,
       path,
       "Action input transform #{inspect(transform)} is not supported.",
       transform: transform,
       allowed: @supported_input_transforms
     )}
  end

  defp invalid_transform_argument(transform, path, message, attrs \\ []) do
    attrs
    |> Keyword.put(:transform, transform)
    |> then(&error(:invalid_action_input_transform, path, message, &1))
    |> then(&{:error, &1})
  end

  defp number_argument(value) when is_number(value), do: {:ok, value}

  defp number_argument(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(value) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp number_argument(_value), do: :error

  defp number_value(value, _transform, _path) when is_number(value), do: {:ok, value}

  defp number_value(value, transform, path) when is_binary(value) do
    case number_argument(value) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        invalid_numeric_value(value, transform, path)
    end
  end

  defp number_value(value, transform, path), do: invalid_numeric_value(value, transform, path)

  defp invalid_numeric_value(value, transform, path) do
    {:error,
     error(
       :invalid_action_input_transform_value,
       path,
       "Action input transform #{inspect(transform)} requires a numeric value.",
       transform: transform,
       value: value
     )}
  end

  defp integer_argument(value) when is_integer(value), do: {:ok, value}

  defp integer_argument(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :invalid_amount
    end
  end

  defp integer_argument(_value), do: :invalid_amount

  defp date_unit(unit) do
    case id(unit) do
      unit when unit in ["day", "days"] -> {:ok, :day}
      unit when unit in ["week", "weeks"] -> {:ok, :week}
      unit when unit in ["hour", "hours"] -> {:ok, :hour}
      unit when unit in ["minute", "minutes"] -> {:ok, :minute}
      unit when unit in ["second", "seconds"] -> {:ok, :second}
      _unit -> :invalid_unit
    end
  end

  defp date_shift(value, transform, amount, unit, path) do
    amount = if transform == "date_subtract", do: -amount, else: amount

    case shift_date_value(value, amount, unit) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error,
         error(
           :invalid_action_input_transform_value,
           path,
           "Action input transform #{inspect(transform)} requires a date or datetime value.",
           transform: transform,
           value: value,
           reason: reason
         )}
    end
  end

  defp shift_date_value(%DateTime{} = value, amount, unit) do
    {:ok, DateTime.add(value, duration_seconds(amount, unit), :second)}
  end

  defp shift_date_value(%NaiveDateTime{} = value, amount, unit) do
    {:ok, NaiveDateTime.add(value, duration_seconds(amount, unit), :second)}
  end

  defp shift_date_value(%Date{} = value, amount, unit) when unit in [:day, :week] do
    {:ok, Date.add(value, date_days(amount, unit))}
  end

  defp shift_date_value(%Date{}, _amount, unit), do: {:error, {:unsupported_date_unit, unit}}

  defp shift_date_value(value, amount, unit) when is_binary(value) do
    value = String.trim(value)

    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        shifted = DateTime.add(datetime, duration_seconds(amount, unit), :second)
        {:ok, DateTime.to_iso8601(shifted)}

      match?({:ok, _datetime}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, datetime} = NaiveDateTime.from_iso8601(value)
        shifted = NaiveDateTime.add(datetime, duration_seconds(amount, unit), :second)
        {:ok, NaiveDateTime.to_iso8601(shifted)}

      match?({:ok, _date}, Date.from_iso8601(value)) and unit in [:day, :week] ->
        {:ok, date} = Date.from_iso8601(value)
        shifted = Date.add(date, date_days(amount, unit))
        {:ok, Date.to_iso8601(shifted)}

      match?({:ok, _date}, Date.from_iso8601(value)) ->
        {:error, {:unsupported_date_unit, unit}}

      true ->
        {:error, :invalid_date}
    end
  end

  defp shift_date_value(_value, _amount, _unit), do: {:error, :invalid_date}

  defp date_days(amount, :day), do: amount
  defp date_days(amount, :week), do: amount * 7

  defp duration_seconds(amount, :second), do: amount
  defp duration_seconds(amount, :minute), do: amount * 60
  defp duration_seconds(amount, :hour), do: amount * 60 * 60
  defp duration_seconds(amount, :day), do: amount * 24 * 60 * 60
  defp duration_seconds(amount, :week), do: amount * 7 * 24 * 60 * 60

  defp invalid_input_placeholder(path) do
    {:error,
     error(
       :invalid_action_template,
       path,
       "Action input placeholders must be shaped as [:input, field] or [:input, field, transforms]."
     )}
  end

  defp invalid_context_placeholder(path) do
    {:error,
     error(
       :invalid_action_template,
       path,
       "Action context placeholders must be shaped as [:context, field] or [:context, field, transforms]."
     )}
  end

  defp invalid_fallback_expression(path) do
    {:error,
     error(
       :invalid_action_template,
       path,
       "Action fallback expressions must be shaped as [:fallback, candidates], where candidates is a list."
     )}
  end

  defp fetch_value(%{} = map, wanted_key) do
    wanted_key = id(wanted_key)

    Enum.find_value(map, :error, fn {key, value} ->
      if id(key) == wanted_key, do: {:ok, value}
    end)
  end

  defp fetch_value(_map, _wanted_key), do: :error

  defp context_map(%{} = context), do: context

  defp context_map(context) when is_list(context) do
    if Keyword.keyword?(context) do
      context
      |> Enum.map(fn {key, value} -> {id(key), value} end)
      |> Map.new()
    else
      %{}
    end
  end

  defp context_map(_context), do: %{}

  defp sorted_entries(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> id(key) end)
  end

  defp id(nil), do: ""
  defp id(value) when is_atom(value), do: Atom.to_string(value)
  defp id(value) when is_binary(value), do: value
  defp id(value), do: to_string(value)

  defp field_name(value) when is_atom(value), do: Atom.to_string(value)
  defp field_name(value) when is_binary(value), do: value
  defp field_name(value), do: to_string(value)

  defp error(code, path, message, attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.merge(%{code: code, path: path, message: message})
  end
end
