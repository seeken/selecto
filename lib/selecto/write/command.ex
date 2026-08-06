defmodule Selecto.Write.Command do
  @moduledoc """
  A database-neutral mutation command.

  Identifiers, predicates, assignments, and values remain logical Selecto
  terms. Adapters are responsible for compiling the command into their native
  representation without weakening its predicate or cardinality contract.
  """

  alias Selecto.Write.Error

  @operations [:insert, :update, :delete, :upsert, :insert_from_query]

  @type expected_cardinality ::
          {:exactly, pos_integer()}
          | {:at_most, non_neg_integer()}
          | {:at_least, non_neg_integer()}
          | {:between, non_neg_integer(), non_neg_integer()}
          | :many

  @type assignment :: %{required(:field) => atom() | String.t(), required(:value) => term()}

  @type t :: %__MODULE__{
          operation: atom(),
          relation: atom() | String.t(),
          assignments: [assignment()],
          predicate: term() | nil,
          expected_cardinality: expected_cardinality(),
          returning: :none | :all | [atom() | String.t()],
          required_capabilities: [atom()],
          metadata: map()
        }

  @enforce_keys [:operation, :relation]
  defstruct operation: nil,
            relation: nil,
            assignments: [],
            predicate: nil,
            expected_cardinality: {:exactly, 1},
            returning: :none,
            required_capabilities: [],
            metadata: %{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    command = struct(__MODULE__, attrs)

    case validate(command) do
      :ok -> {:ok, command}
      {:error, _} = error -> error
    end
  end

  def new(other) do
    {:error,
     Error.new(:invalid_command, "write command must be a map or keyword list",
       details: %{actual: other}
     )}
  end

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = command) do
    with :ok <- validate_operation(command.operation),
         :ok <- validate_identifier(command.relation, :relation),
         :ok <- validate_assignments(command.assignments),
         :ok <- validate_predicate(command.predicate),
         :ok <- validate_cardinality(command.expected_cardinality),
         :ok <- validate_returning(command.returning),
         :ok <- validate_capabilities(command.required_capabilities),
         :ok <- validate_metadata(command.metadata) do
      :ok
    end
  end

  defp validate_operation(operation) when operation in @operations, do: :ok

  defp validate_operation(operation) do
    {:error,
     Error.new(:invalid_command, "unsupported portable write operation",
       details: %{operation: operation, supported: @operations}
     )}
  end

  defp validate_identifier(value, _label) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_identifier(value, _label) when is_binary(value) do
    if String.trim(value) == "" do
      {:error,
       Error.new(:invalid_command, "identifier must not be blank", details: %{value: value})}
    else
      :ok
    end
  end

  defp validate_identifier(value, label) do
    {:error,
     Error.new(:invalid_command, "#{label} must be a non-empty atom or string",
       details: %{label: label, value: value}
     )}
  end

  defp validate_assignments(assignments) when is_list(assignments) do
    assignments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {assignment, index}, :ok ->
      case validate_assignment(assignment) do
        :ok ->
          {:cont, :ok}

        {:error, %Error{} = error} ->
          {:halt, {:error, %{error | details: Map.put(error.details, :assignment_index, index)}}}
      end
    end)
  end

  defp validate_assignments(assignments) do
    {:error,
     Error.new(:invalid_command, "assignments must be a list",
       details: %{assignments: assignments}
     )}
  end

  defp validate_assignment(%{field: field, value: value}) do
    with :ok <- validate_identifier(field, :assignment_field),
         :ok <- validate_value(value) do
      :ok
    end
  end

  defp validate_assignment(assignment) do
    {:error,
     Error.new(:invalid_command, "each assignment must include :field and :value",
       details: %{assignment: assignment}
     )}
  end

  # Value expressions are portable data. Raw SQL fragments are deliberately not
  # part of this representation.
  defp validate_value({:unsafe_sql, _}),
    do: {:error, Error.new(:invalid_command, "raw SQL is not allowed in portable write values")}

  defp validate_value({:unsafe_fragment, _}),
    do: {:error, Error.new(:invalid_command, "raw SQL is not allowed in portable write values")}

  defp validate_value(_value), do: :ok

  defp validate_predicate(nil), do: :ok

  defp validate_predicate({:unsafe_sql, _}),
    do:
      {:error, Error.new(:invalid_command, "raw SQL is not allowed in portable write predicates")}

  defp validate_predicate({:unsafe_fragment, _}),
    do:
      {:error, Error.new(:invalid_command, "raw SQL is not allowed in portable write predicates")}

  defp validate_predicate(_predicate), do: :ok

  defp validate_cardinality({:exactly, value}) when is_integer(value) and value > 0, do: :ok
  defp validate_cardinality({:at_most, value}) when is_integer(value) and value >= 0, do: :ok
  defp validate_cardinality({:at_least, value}) when is_integer(value) and value >= 0, do: :ok

  defp validate_cardinality({:between, minimum, maximum})
       when is_integer(minimum) and is_integer(maximum) and minimum >= 0 and maximum >= minimum,
       do: :ok

  defp validate_cardinality(:many), do: :ok

  defp validate_cardinality(value) do
    {:error,
     Error.new(:invalid_command, "invalid expected cardinality",
       details: %{expected_cardinality: value}
     )}
  end

  defp validate_returning(value) when value in [:none, :all], do: :ok

  defp validate_returning(fields) when is_list(fields) do
    if Enum.all?(fields, &(is_atom(&1) or (is_binary(&1) and String.trim(&1) != ""))) do
      :ok
    else
      {:error, Error.new(:invalid_command, "returning fields must be non-empty atoms or strings")}
    end
  end

  defp validate_returning(value) do
    {:error,
     Error.new(:invalid_command, "invalid returning specification", details: %{returning: value})}
  end

  defp validate_capabilities(capabilities) when is_list(capabilities) do
    if Enum.all?(capabilities, &is_atom/1) do
      :ok
    else
      {:error,
       Error.new(:invalid_command, "required capabilities must be atoms",
         details: %{capabilities: capabilities}
       )}
    end
  end

  defp validate_capabilities(capabilities) do
    {:error,
     Error.new(:invalid_command, "required capabilities must be a list",
       details: %{capabilities: capabilities}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata) do
    if contains_unsafe_sql?(metadata) do
      {:error, Error.new(:invalid_command, "raw SQL is not allowed in portable write metadata")}
    else
      :ok
    end
  end

  defp validate_metadata(metadata) do
    {:error,
     Error.new(:invalid_command, "command metadata must be a map", details: %{metadata: metadata})}
  end

  defp contains_unsafe_sql?({:unsafe_sql, _}), do: true
  defp contains_unsafe_sql?({:unsafe_fragment, _}), do: true

  defp contains_unsafe_sql?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> contains_unsafe_sql?(key) or contains_unsafe_sql?(value) end)
  end

  defp contains_unsafe_sql?(list) when is_list(list), do: Enum.any?(list, &contains_unsafe_sql?/1)

  defp contains_unsafe_sql?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_unsafe_sql?/1)
  end

  defp contains_unsafe_sql?(_value), do: false
end
