defmodule Selecto.Query.Result do
  @moduledoc "Normalized rows and governed column ids with explicit missing values."
  @derive Jason.Encoder
  defstruct rows: [], columns: [], metadata: %{}, next_cursor: nil
  @type t :: %__MODULE__{}

  def to_raw(%__MODULE__{rows: rows, columns: columns}), do: {rows, columns, columns}

  def to_maps(%__MODULE__{rows: rows, columns: columns}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  def validate(%__MODULE__{} = result, plan) do
    columns = Enum.map(plan.projection, & &1["id"])

    valid =
      result.columns == columns and is_list(result.rows) and
        length(result.rows) <= plan.page["limit"] and
        Enum.all?(result.rows, &(is_list(&1) and length(&1) == length(columns))) and
        aggregate_result?(result, plan)

    if valid and :erlang.external_size(result.rows) <= plan.bounds["max_bytes"],
      do: :ok,
      else:
        {:error,
         Selecto.Error.validation_error("Adapter result violates query contract or bounds")}
  end

  def validate(_, _), do: {:error, Selecto.Error.validation_error("Invalid adapter result")}

  defp aggregate_result?(_result, %{aggregates: []}), do: true

  defp aggregate_result?(%{rows: [row], next_cursor: nil}, plan) do
    Enum.all?(Enum.zip(plan.aggregates, row), fn {aggregate, value} ->
      case aggregate["op"] do
        "count" -> is_integer(value) and value >= 0 and value <= plan.bounds["max_input_rows"]
        _ -> is_nil(value) or Selecto.Query.Plan.typed?("integer", value)
      end
    end)
  end

  defp aggregate_result?(_result, _plan), do: false
end
