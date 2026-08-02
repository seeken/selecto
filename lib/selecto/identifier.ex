defmodule Selecto.Identifier do
  @moduledoc """
  Bounded conversion of runtime identifiers to atoms.

  Selecto domain maps traditionally use atom keys, while adapters and generators
  may discover identifiers at runtime. This module preserves that contract without
  allowing an unbounded stream of identifiers to exhaust the VM atom table.

  Existing atoms do not consume the dynamic identifier budget. New atoms are
  serialized and capped for the lifetime of the VM.
  """

  @counter_key {__MODULE__, :dynamic_identifier_counter}
  @max_dynamic_identifiers 10_000
  @max_identifier_bytes 255

  @spec to_atom!(atom() | String.t()) :: atom()
  def to_atom!(value) when is_atom(value) and not is_nil(value), do: value

  def to_atom!(value) when is_binary(value) do
    validate_identifier!(value)

    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> intern_new_atom!(value)
    end
  end

  def to_atom!(value) do
    raise ArgumentError, "cannot convert #{inspect(value)} to an atom identifier"
  end

  @spec to_atom(atom() | String.t()) :: {:ok, atom()} | {:error, String.t()}
  def to_atom(value) do
    {:ok, to_atom!(value)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc "Returns the fixed upper bound for runtime-created identifier atoms."
  @spec max_dynamic_identifiers() :: pos_integer()
  def max_dynamic_identifiers, do: @max_dynamic_identifiers

  defp validate_identifier!(value) do
    cond do
      value == "" ->
        raise ArgumentError, "identifier cannot be empty"

      byte_size(value) > @max_identifier_bytes ->
        raise ArgumentError,
              "identifier exceeds the #{@max_identifier_bytes}-byte runtime limit"

      not String.valid?(value) ->
        raise ArgumentError, "identifier must be valid UTF-8"

      true ->
        :ok
    end
  end

  defp intern_new_atom!(value) do
    :global.trans({__MODULE__, :atom_interning}, fn ->
      try do
        String.to_existing_atom(value)
      rescue
        ArgumentError -> create_bounded_atom!(value)
      end
    end)
  end

  defp create_bounded_atom!(value) do
    counter = ensure_counter!()
    count = :atomics.add_get(counter, 1, 1)

    if count <= @max_dynamic_identifiers do
      String.to_atom(value)
    else
      :atomics.sub_get(counter, 1, 1)

      raise ArgumentError,
            "runtime identifier atom limit of #{@max_dynamic_identifiers} has been reached"
    end
  end

  defp ensure_counter! do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        counter = :atomics.new(1, signed: false)
        :persistent_term.put(@counter_key, counter)
        counter

      counter ->
        counter
    end
  end
end
