defmodule Selecto.Domain.Description do
  @moduledoc """
  The field description rule (certification specification 3.1, field
  descriptions).

  A `description` on a column (root `source.columns` or a related relation's
  `columns`) or on a `components.filter_choices` entry is plain text for the
  people choosing or reading the field: a string of 1 to 1000 Unicode code
  points that is not only whitespace. A line feed is allowed; every other
  control character (U+0000-U+0009, U+000B-U+001F, U+007F) is not.
  """

  @max_length 1000

  @doc "Returns true when `value` satisfies the description rule."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and
      length(String.codepoints(value)) <= @max_length and
      not Regex.match?(~r/[\x{0}-\x{9}\x{B}-\x{1F}\x{7F}]/u, value)
  end

  def valid?(_value), do: false

  @doc "The maximum length of a description, in code points."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length
end
