defmodule Selecto.Analytics.TransformRegistry do
  @moduledoc "Portable analytical transforms and their unit/behavior constraints."

  alias Selecto.Analytics.Unit

  @order [
    :percent_of_total,
    :percent_change,
    :percentage_point_change,
    :index_to_first,
    :cumulative,
    :moving_average,
    :exponential_moving_average,
    :min_max,
    :z_score
  ]
  @definitions %{
    percent_of_total: %{label: "Percent of total", result: :percentage},
    percent_change: %{label: "Percent change", result: :percentage, requires_ordered_axis: true},
    percentage_point_change: %{
      label: "Percentage-point change",
      result: :percentage_input_scale,
      input_kinds: [:percentage],
      requires_ordered_axis: true
    },
    index_to_first: %{label: "Index to first value", result: :ratio, requires_ordered_axis: true},
    cumulative: %{
      label: "Cumulative total",
      result: :preserve,
      input_behaviors: [:flow],
      requires_ordered_axis: true
    },
    moving_average: %{
      label: "Moving average",
      result: :preserve,
      requires_ordered_axis: true,
      parameters: %{window: %{type: :integer, minimum: 2, maximum: 365}}
    },
    exponential_moving_average: %{
      label: "Exponential moving average",
      result: :preserve,
      requires_ordered_axis: true,
      parameters: %{alpha: %{type: :decimal, exclusive_minimum: 0, maximum: 1}}
    },
    min_max: %{label: "Normalize to 0–100", result: :ratio, requires_ordered_axis: true},
    z_score: %{label: "Standard score", result: :scalar, requires_ordered_axis: true}
  }

  @spec definition(atom() | String.t()) :: map() | nil
  def definition(id) do
    with {:ok, id} <- id(id),
         spec when not is_nil(spec) <- Map.get(@definitions, id),
         do: Map.put(spec, :id, id),
         else: (_ -> nil)
  end

  @spec catalog(map() | nil, atom() | String.t() | nil) :: [map()]
  def catalog(nil, _behavior), do: []

  def catalog(unit, behavior) do
    Enum.flat_map(@order, fn id ->
      if allows?(id, unit, behavior), do: [definition(id)], else: []
    end)
  end

  @spec allows?(atom() | String.t(), map() | nil, atom() | String.t() | nil) :: boolean()
  def allows?(id, unit, behavior) do
    with %{} = spec <- definition(id),
         {:ok, unit} <- Unit.normalize_unit(unit),
         {:ok, behavior} <- normalize_behavior(behavior) do
      behavior_allowed?(spec, behavior) and
        (not Map.has_key?(spec, :input_kinds) or unit.kind in spec.input_kinds)
    else
      _ -> false
    end
  end

  @spec result_unit(atom() | String.t(), map() | nil, atom() | String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def result_unit(id, input_unit, behavior) do
    if allows?(id, input_unit, behavior) do
      {:ok, input} = Unit.normalize_unit(input_unit)
      spec = definition(id)

      case spec.result do
        :preserve -> {:ok, input}
        :percentage -> {:ok, %{kind: :percentage, scale: :whole}}
        :percentage_input_scale -> {:ok, %{kind: :percentage, scale: input.scale}}
        :ratio -> {:ok, %{kind: :ratio}}
        :scalar -> {:ok, %{kind: :scalar}}
      end
    else
      {:error, "analytical transform is not available for this unit and behavior"}
    end
  end

  defp id(value) when is_atom(value), do: if(value in @order, do: {:ok, value}, else: :error)

  defp id(value) when is_binary(value) do
    case Enum.find(@order, &(Atom.to_string(&1) == value)) do
      nil -> :error
      id -> {:ok, id}
    end
  end

  defp id(_), do: :error

  defp normalize_behavior(nil), do: {:ok, nil}
  defp normalize_behavior(value), do: Unit.normalize_behavior(value)

  defp behavior_allowed?(spec, behavior),
    do: not Map.has_key?(spec, :input_behaviors) or behavior in spec.input_behaviors
end
