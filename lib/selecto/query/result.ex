defmodule Selecto.Query.Result do
  @moduledoc "Normalized rows and governed column ids with explicit missing values."
  @derive Jason.Encoder
  defstruct rows: [], columns: [], metadata: %{}, next_cursor: nil
  @type t :: %__MODULE__{}

  def to_raw(%__MODULE__{rows: rows, columns: columns}), do: {rows, columns, columns}

  def to_maps(%__MODULE__{rows: rows, columns: columns}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  @doc "Inherited identity metadata for an owned object relation, including empty results."
  def relation_identity_metadata(%{relation: %{"kind" => "object"} = relation}),
    do: %{
      "kind" => "parent",
      "parent_relation" => relation["parent"],
      "parent_identity" => relation["parent_identity"]
    }

  def relation_identity_metadata(_), do: nil

  def validate(%__MODULE__{} = result, plan) do
    columns = Enum.map(plan.projection, & &1["id"])

    valid =
      result.columns == columns and is_list(result.rows) and
        length(result.rows) <= plan.page["limit"] and
        Enum.all?(result.rows, &(is_list(&1) and length(&1) == length(columns))) and
        aggregate_result?(result, plan) and object_result?(result, plan) and
        object_id_values?(result, plan)

    if valid and :erlang.external_size(result.rows) <= plan.bounds["max_bytes"],
      do: :ok,
      else:
        {:error,
         Selecto.Error.validation_error("Adapter result violates query contract or bounds")}
  end

  def validate(_, _), do: {:error, Selecto.Error.validation_error("Invalid adapter result")}

  defp object_result?(
         %{metadata: metadata, next_cursor: nil, rows: rows},
         %{relation: %{"kind" => "object"}} = plan
       ),
       do:
         is_map(metadata) and metadata["relation_identity"] == relation_identity_metadata(plan) and
           length(rows) <= 1

  defp object_result?(_result, %{relation: %{"kind" => "object"}}), do: false
  defp object_result?(_, _), do: true

  defp object_id_values?(result, plan) do
    Enum.all?(result.rows, fn row ->
      Enum.all?(Enum.zip(plan.projection, row), fn
        {%{"type" => "object_id"} = field, %Selecto.Document.Missing{}} ->
          field["missing"] == "preserve"

        {%{"type" => "object_id"} = field, nil} ->
          field["nullable"] == true

        {%{"type" => "object_id"}, value} ->
          Selecto.Document.ObjectId.valid?(value)

        _ ->
          true
      end)
    end)
  end

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
