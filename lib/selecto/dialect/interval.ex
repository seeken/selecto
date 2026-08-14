defmodule Selecto.Dialect.Interval do
  @moduledoc "Typed, database-neutral interval value for dialect rendering."

  @enforce_keys [:amount, :unit]
  defstruct [:amount, :unit]

  @units ~w(microsecond millisecond second minute hour day week month quarter year)a

  @type unit ::
          :microsecond
          | :millisecond
          | :second
          | :minute
          | :hour
          | :day
          | :week
          | :month
          | :quarter
          | :year
  @type t :: %__MODULE__{amount: integer(), unit: unit()}

  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new({amount, unit}) when is_integer(amount), do: build(amount, unit)

  def new(spec) when is_binary(spec) do
    case Regex.run(~r/\A\s*([+-]?\d+)\s+([A-Za-z]+)\s*\z/, spec, capture: :all_but_first) do
      [amount, unit] -> build(String.to_integer(amount), unit)
      _ -> {:error, {:invalid_interval, spec}}
    end
  end

  def new(spec), do: {:error, {:invalid_interval, spec}}

  defp build(amount, unit) do
    unit = unit |> to_string() |> String.downcase() |> String.trim_trailing("s")

    case Enum.find(@units, &(Atom.to_string(&1) == unit)) do
      nil -> {:error, {:invalid_interval_unit, unit}}
      normalized -> {:ok, %__MODULE__{amount: amount, unit: normalized}}
    end
  end
end
