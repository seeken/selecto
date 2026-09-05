defmodule Selecto.Document.Path do
  @moduledoc "Parsed document paths; raw dotted paths and backend operators are rejected."
  alias Selecto.Document.Missing

  @max_segments 32
  @max_key_bytes 128

  @spec parse(term(), keyword()) :: {:ok, list()} | {:error, atom()}
  def parse(path, opts \\ [])

  def parse(path, opts) when is_list(path) and length(path) in 1..@max_segments do
    allow_each = Keyword.get(opts, :allow_each, false)

    if Enum.all?(path, fn
         %{"each" => true} = step -> allow_each and map_size(step) == 1
         key -> safe_key?(key)
       end) do
      {:ok, path}
    else
      {:error, :unsafe_document_path}
    end
  end

  def parse(_, _), do: {:error, :invalid_document_path}

  @doc "Restrictive portable V1 key alphabet; identifiers never create atoms."
  def safe_key?(key) when is_binary(key) and byte_size(key) in 1..@max_key_bytes,
    do: String.valid?(key) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/, key)

  def safe_key?(_), do: false

  @spec fetch(term(), list()) :: term() | Missing.t()
  def fetch(document, []), do: document

  def fetch(document, [key | rest]) when is_map(document) and not is_struct(document) do
    case Map.fetch(document, key) do
      {:ok, value} -> fetch(value, rest)
      :error -> %Missing{}
    end
  end

  def fetch(_, _), do: %Missing{}
end
