defmodule SelectoUpdato.Error do
  @moduledoc """
  Structured, adapter-neutral errors for SelectoUpdato operations.
  """

  defstruct [:type, :message, :field, details: %{}]

  @type error_type :: atom()

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          field: atom() | nil,
          details: map()
        }

  @doc """
  Create a new error.
  """
  @spec new(error_type(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) do
    %__MODULE__{
      type: type,
      message: message,
      field: Keyword.get(opts, :field),
      details: Keyword.get(opts, :details, %{})
    }
  end

  @doc """
  Get the error type.
  """
  @spec type(t()) :: error_type()
  def type(%__MODULE__{type: type}), do: type

  @doc """
  Get the error message.
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message

  @doc """
  Get validation errors as a map.
  """
  @spec errors(t()) :: map()
  def errors(%__MODULE__{type: :validation, details: %{errors: errors}}) when is_map(errors),
    do: errors

  def errors(%__MODULE__{}), do: %{}

  @doc """
  Check if the error is of a specific type.
  """
  @spec is_type?(t(), error_type()) :: boolean()
  def is_type?(%__MODULE__{type: type}, expected_type), do: type == expected_type

  @doc """
  Convert error to a simple map (for JSON encoding, etc.).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      type: error.type,
      message: error.message,
      errors: errors(error),
      details: error.details
    }
    |> Map.reject(fn {_k, v} -> v == nil or v == %{} end)
  end
end

defimpl String.Chars, for: SelectoUpdato.Error do
  def to_string(%SelectoUpdato.Error{type: type, message: message}) do
    "[#{type}] #{message}"
  end
end
