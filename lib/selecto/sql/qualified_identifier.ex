defmodule Selecto.SQL.QualifiedIdentifier do
  @moduledoc """
  Validates and quotes SQL identifiers at DDL boundaries.

  Qualified identifiers are split on `.` and every component must use the
  portable identifier subset `letter | underscore` followed by letters,
  digits, underscores, or dollar signs. Adapter-specific length and quoting
  policy may be supplied as the second argument.

  This module deliberately does not accept pre-quoted identifiers or arbitrary
  SQL fragments. Callers that need a single identifier, such as an index name
  or column name, must use the `*_part/1` functions.
  """

  @identifier_pattern ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @type validation_error :: %{
          required(:code) => :invalid_sql_identifier,
          required(:identifier) => term(),
          required(:reason) =>
            :empty
            | :invalid_type
            | :invalid_utf8
            | :empty_part
            | :invalid_characters
            | :part_too_long
            | :qualified_identifier_not_allowed,
          optional(:part) => String.t(),
          optional(:part_index) => non_neg_integer(),
          optional(:max_bytes) => pos_integer()
        }

  @doc "Validates a possibly qualified atom or string identifier."
  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(identifier, adapter_or_policy \\ nil),
    do: validate_identifier(identifier, true, policy(adapter_or_policy))

  @doc "Validates one unqualified atom or string identifier."
  @spec validate_part(term()) :: :ok | {:error, validation_error()}
  def validate_part(identifier, adapter_or_policy \\ nil),
    do: validate_identifier(identifier, false, policy(adapter_or_policy))

  @doc "Validates and always quotes a possibly qualified identifier."
  @spec quote(term()) :: {:ok, String.t()} | {:error, validation_error()}
  def quote(identifier, adapter_or_policy \\ nil) do
    policy = policy(adapter_or_policy)

    with :ok <- validate_identifier(identifier, true, policy) do
      {:ok, identifier |> identifier_string() |> quote_parts(policy)}
    end
  end

  @doc "Validates and always quotes one unqualified identifier."
  @spec quote_part(term()) :: {:ok, String.t()} | {:error, validation_error()}
  def quote_part(identifier, adapter_or_policy \\ nil) do
    policy = policy(adapter_or_policy)

    with :ok <- validate_identifier(identifier, false, policy) do
      {:ok, identifier |> identifier_string() |> quote_component(policy)}
    end
  end

  @doc "Like `quote/1`, but raises `ArgumentError` for an invalid identifier."
  @spec quote!(term()) :: String.t()
  def quote!(identifier, adapter_or_policy \\ nil) do
    case __MODULE__.quote(identifier, adapter_or_policy) do
      {:ok, quoted} -> quoted
      {:error, error} -> raise ArgumentError, error_message(error)
    end
  end

  @doc "Like `quote_part/1`, but raises `ArgumentError` for an invalid identifier."
  @spec quote_part!(term()) :: String.t()
  def quote_part!(identifier, adapter_or_policy \\ nil) do
    case quote_part(identifier, adapter_or_policy) do
      {:ok, quoted} -> quoted
      {:error, error} -> raise ArgumentError, error_message(error)
    end
  end

  @doc "Formats a structured validation error for a human-facing diagnostic."
  @spec error_message(validation_error()) :: String.t()
  def error_message(%{identifier: identifier, reason: reason} = error) do
    location =
      case error do
        %{part: part, part_index: index} -> " component #{index} #{inspect(part)}"
        _ -> ""
      end

    detail =
      case reason do
        :empty -> "must not be empty"
        :invalid_type -> "must be a non-empty atom or string"
        :invalid_utf8 -> "must be valid UTF-8"
        :empty_part -> "contains an empty component"
        :invalid_characters -> "contains characters outside the portable SQL identifier subset"
        :part_too_long -> "exceeds the #{error.max_bytes}-byte component limit"
        :qualified_identifier_not_allowed -> "must not be qualified"
      end

    "invalid SQL identifier #{inspect(identifier)}#{location}: #{detail}"
  end

  defp validate_identifier(identifier, qualified?, policy)
       when is_atom(identifier) and not is_nil(identifier) do
    identifier |> Atom.to_string() |> validate_identifier(qualified?, policy)
  end

  defp validate_identifier(identifier, qualified?, policy) when is_binary(identifier) do
    cond do
      identifier == "" ->
        invalid(identifier, :empty)

      not String.valid?(identifier) ->
        invalid(identifier, :invalid_utf8)

      not qualified? and String.contains?(identifier, ".") ->
        invalid(identifier, :qualified_identifier_not_allowed)

      true ->
        identifier
        |> String.split(".", trim: false)
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {part, index}, :ok ->
          case validate_component(identifier, part, index, policy) do
            :ok -> {:cont, :ok}
            {:error, _error} = error -> {:halt, error}
          end
        end)
    end
  end

  defp validate_identifier(identifier, _qualified?, _policy),
    do: invalid(identifier, :invalid_type)

  defp validate_component(identifier, "", index, _policy),
    do: invalid(identifier, :empty_part, part: "", part_index: index)

  defp validate_component(identifier, part, index, policy) do
    max_bytes = Map.get(policy, :max_bytes)

    cond do
      is_integer(max_bytes) and max_bytes > 0 and byte_size(part) > max_bytes ->
        invalid(identifier, :part_too_long,
          part: part,
          part_index: index,
          max_bytes: max_bytes
        )

      not Regex.match?(@identifier_pattern, part) ->
        invalid(identifier, :invalid_characters, part: part, part_index: index)

      true ->
        :ok
    end
  end

  defp invalid(identifier, reason, attrs \\ []) do
    {:error,
     attrs
     |> Enum.into(%{})
     |> Map.merge(%{code: :invalid_sql_identifier, identifier: identifier, reason: reason})}
  end

  defp identifier_string(identifier) when is_atom(identifier), do: Atom.to_string(identifier)
  defp identifier_string(identifier), do: identifier

  defp quote_parts(identifier, policy) do
    identifier
    |> String.split(".")
    |> Enum.map_join(".", &quote_component(&1, policy))
  end

  defp quote_component(part, %{quote_identifier: quote}) when is_function(quote, 1),
    do: quote.(part)

  defp quote_component(part, _policy), do: ~s("#{part}")

  defp policy(nil), do: %{}
  defp policy(policy) when is_list(policy), do: Map.new(policy)
  defp policy(policy) when is_map(policy), do: policy

  defp policy(adapter) when is_atom(adapter) do
    base =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :identifier_policy, 0),
        do: adapter.identifier_policy(),
        else: %{}

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :quote_identifier, 1) do
      Map.put(base, :quote_identifier, &adapter.quote_identifier/1)
    else
      base
    end
  end

  defp policy(_other), do: %{}
end
