defmodule Selecto.Dialect.Window.FrameBoundary do
  @moduledoc "Validated interval boundary for a portable window-frame request."

  @units ~w(microsecond millisecond second minute hour day week month year)a

  @enforce_keys [:amount, :unit, :direction]
  defstruct [:amount, :unit, :direction]

  @type t :: %__MODULE__{
          amount: String.t(),
          unit: atom(),
          direction: :preceding | :following
        }

  @spec new(term(), :preceding | :following) :: {:ok, t()} | {:error, term()}
  def new(interval, direction)
      when is_binary(interval) and direction in [:preceding, :following] do
    case Regex.run(
           ~r/^([0-9]+(?:\.[0-9]+)?)\s+(microseconds?|milliseconds?|seconds?|minutes?|hours?|days?|weeks?|months?|years?)$/i,
           String.trim(interval),
           capture: :all_but_first
         ) do
      [amount, unit] ->
        normalized_unit = unit |> String.downcase() |> String.trim_trailing("s")
        atom_unit = Enum.find(@units, &(Atom.to_string(&1) == normalized_unit))
        {:ok, %__MODULE__{amount: amount, unit: atom_unit, direction: direction}}

      _ ->
        {:error, {:invalid_window_frame_interval, interval}}
    end
  end

  def new(interval, direction),
    do: {:error, {:invalid_window_frame_interval, interval, direction}}
end
