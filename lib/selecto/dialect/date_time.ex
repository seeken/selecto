defmodule Selecto.Dialect.DateTime.Operation do
  @moduledoc "Finite portable date/time operation presented to an adapter dialect."

  @parts ~w(
    millennium century decade year quarter month week day dow isodow doy
    hour minute second milliseconds microseconds epoch timezone
    timezone_hour timezone_minute weekday_sunday_one
  )a

  @enforce_keys [:operation, :clause]
  defstruct [:operation, :clause, :expression, :second_expression, :part, options: %{}]

  @type t :: %__MODULE__{
          operation:
            :current_timestamp
            | :truncate
            | :age
            | :extract_part
            | :format
            | :elapsed_days
            | :temporal_cutoff,
          clause: :select | :filter,
          expression: iodata() | nil,
          second_expression: iodata() | nil,
          part: atom() | nil,
          options: map()
        }

  @spec normalize_part(term()) :: {:ok, atom()} | {:error, term()}
  def normalize_part({:literal, part}), do: normalize_part(part)

  def normalize_part(part) when is_atom(part) do
    if part in @parts, do: {:ok, part}, else: {:error, {:unsupported_datetime_part, part}}
  end

  def normalize_part(part) when is_binary(part) do
    normalized = part |> String.trim() |> String.downcase()

    case Enum.find(@parts, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, {:unsupported_datetime_part, part}}
      value -> {:ok, value}
    end
  end

  def normalize_part(part), do: {:error, {:invalid_datetime_part, part}}
end
