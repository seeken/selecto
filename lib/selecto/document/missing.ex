defmodule Selecto.Document.Missing do
  @moduledoc "An absent document field, distinct from present JSON null (`nil`)."
  defstruct __selecto_missing__: true

  @type t :: %__MODULE__{__selecto_missing__: true}

  @doc "Serializable tagged missing value. Treat this as result metadata, never source data."
  def to_map(%__MODULE__{}), do: %{"$selecto" => "missing"}

  def missing?(%__MODULE__{}), do: true
  def missing?(_), do: false
end

defimpl Jason.Encoder, for: Selecto.Document.Missing do
  def encode(value, opts),
    do: value |> Selecto.Document.Missing.to_map() |> Jason.Encode.map(opts)
end
