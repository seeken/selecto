defmodule Selecto.Advanced.JsonOperations do
  @moduledoc """
  Portable JSON operation specifications.

  Core validates database-independent JSON intent. The configured adapter
  decides which operations it supports and renders the native SQL.

  ## Examples

      # JSON path extraction
      selecto
      |> Selecto.json_select([
          {:json_extract, "metadata", "$.category", as: "category"},
          {:json_extract, "metadata", "$.specs.weight", as: "weight"}
        ])
      
      # JSON aggregation
      selecto
      |> Selecto.json_select([
          {:json_agg, "product_name", as: "products"},
          {:json_object_agg, "product_id", "price", as: "price_map"}
        ])
      |> Selecto.group_by(["category"])
      
      # JSON filtering
      selecto
      |> Selecto.json_filter([
          {:json_contains, "metadata", %{"category" => "electronics"}},
          {:json_path_exists, "metadata", "$.specs.warranty"}
        ])
  """

  defmodule Spec do
    @moduledoc """
    Specification for JSON operations in SELECT, WHERE, and other clauses.
    """
    defstruct [
      # Unique identifier for the JSON operation
      :id,
      # JSON operation type (:extract, :agg, :contains, etc.)
      :operation,
      # Source column name
      :column,
      # JSON path (for extraction operations)  
      :path,
      # Value for comparison/manipulation operations
      :value,
      # Key field for object aggregation
      :key_field,
      # Value field for object aggregation
      :value_field,
      # Optional alias for SELECT operations
      :alias,
      # Additional operation options such as a filter comparison
      :options,
      # Boolean indicating if operation has been validated
      :validated,
      # Fields explicitly supplied by the caller (distinguishes absent from nil)
      provided: MapSet.new()
    ]

    # Extraction operations
    @type operation_type ::
            :json_extract
            | :json_extract_text
            # Testing operations  
            | :json_contains
            | :json_contained
            | :json_exists
            | :json_path_exists
            # Aggregation operations
            | :json_agg
            | :json_object_agg
            # Construction operations
            | :json_build_object
            | :json_build_array
            # Manipulation operations
            | :json_set
            | :json_remove
            # Type operations
            | :json_typeof
            | :json_array_length

    @type t :: %__MODULE__{
            id: String.t(),
            operation: operation_type(),
            column: String.t() | atom() | nil,
            path: String.t() | nil,
            value: term() | nil,
            key_field: String.t() | atom() | nil,
            value_field: String.t() | atom() | nil,
            alias: String.t() | nil,
            options: map(),
            provided: MapSet.t(atom()),
            validated: boolean()
          }
  end

  defmodule ValidationError do
    @moduledoc """
    Error raised when JSON operation specification is invalid.
    """
    defexception [:type, :message, :details]

    @type t :: %__MODULE__{
            type:
              :invalid_operation
              | :invalid_path
              | :invalid_column
              | :invalid_arguments
              | :invalid_clause,
            message: String.t(),
            details: map()
          }
  end

  @doc """
  Create a JSON extraction operation specification.
  """
  def create_json_operation(operation, column, opts \\ []) do
    opts = normalize_options(operation, column, opts)

    spec = %Spec{
      id: generate_json_operation_id(operation, column),
      operation: operation,
      column: column,
      path: Keyword.get(opts, :path),
      value: Keyword.get(opts, :value),
      key_field: Keyword.get(opts, :key_field),
      value_field: Keyword.get(opts, :value_field),
      alias: Keyword.get(opts, :as),
      options: extract_options(opts),
      provided: opts |> Keyword.keys() |> MapSet.new() |> maybe_mark_column(column),
      validated: false
    }

    case validate_json_operation(spec) do
      {:ok, validated_spec} -> validated_spec
      {:error, validation_error} -> raise validation_error
    end
  end

  @operation_contracts %{
    json_extract: %{
      required: [:column, :path],
      fields: [:column, :path, :comparison],
      clauses: [:select, :filter, :order]
    },
    json_extract_text: %{
      required: [:column, :path],
      fields: [:column, :path, :comparison],
      clauses: [:select, :filter, :order]
    },
    json_contains: %{
      required: [:column, :value],
      fields: [:column, :value],
      clauses: [:filter]
    },
    json_contained: %{
      required: [:column, :value],
      fields: [:column, :value],
      clauses: [:filter]
    },
    json_exists: %{
      required: [:column, :path],
      fields: [:column, :path],
      clauses: [:filter]
    },
    json_path_exists: %{
      required: [:column, :path],
      fields: [:column, :path],
      clauses: [:filter]
    },
    json_agg: %{required: [:column], fields: [:column], clauses: [:select]},
    json_object_agg: %{
      required: [:key_field, :value_field],
      fields: [:column, :key_field, :value_field],
      clauses: [:select]
    },
    json_build_object: %{required: [:value], fields: [:value], clauses: [:select]},
    json_build_array: %{required: [:value], fields: [:value], clauses: [:select]},
    json_set: %{
      required: [:column, :path, :value],
      fields: [:column, :path, :value],
      clauses: [:select]
    },
    json_remove: %{
      required: [:column, :path],
      fields: [:column, :path],
      clauses: [:select]
    },
    json_typeof: %{required: [:column], fields: [:column], clauses: [:select, :order]},
    json_array_length: %{required: [:column], fields: [:column], clauses: [:select, :order]}
  }

  @doc """
  Validate a JSON operation specification.
  """
  def validate_json_operation(%Spec{} = spec) do
    with :ok <- validate_operation_type(spec.operation),
         :ok <- validate_required_params(spec),
         :ok <- validate_json_path(spec),
         :ok <- validate_operation_compatibility(spec) do
      validated_spec = %{spec | validated: true}
      {:ok, validated_spec}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validate that an operation is meaningful in the requested query clause.
  """
  def validate_operation_clause(%Spec{} = spec, clause)
      when clause in [:select, :filter, :order] do
    cond do
      clause not in allowed_clauses(spec.operation) ->
        {:error,
         %ValidationError{
           type: :invalid_clause,
           message: "#{spec.operation} is not valid in a #{clause} clause",
           details: %{operation: spec.operation, clause: clause}
         }}

      clause != :select and not is_nil(spec.alias) ->
        {:error,
         %ValidationError{
           type: :invalid_clause,
           message: "JSON aliases are only valid in select clauses",
           details: %{operation: spec.operation, clause: clause, alias: spec.alias}
         }}

      clause != :filter and not is_nil(Map.get(spec.options || %{}, :comparison)) ->
        {:error,
         %ValidationError{
           type: :invalid_clause,
           message: "JSON comparisons are only valid in filter clauses",
           details: %{operation: spec.operation, clause: clause}
         }}

      clause == :filter and spec.operation in [:json_extract, :json_extract_text] and
          not valid_comparison?(Map.get(spec.options || %{}, :comparison)) ->
        {:error,
         %ValidationError{
           type: :invalid_arguments,
           message: "JSON extraction filters require a comparison tuple",
           details: %{operation: spec.operation, comparison: Map.get(spec.options, :comparison)}
         }}

      true ->
        :ok
    end
  end

  # Validate that the operation type is supported
  defp validate_operation_type(operation) do
    if Map.has_key?(@operation_contracts, operation) do
      :ok
    else
      {:error,
       %ValidationError{
         type: :invalid_operation,
         message: "Unsupported JSON operation: #{operation}",
         details: %{operation: operation}
       }}
    end
  end

  defp validate_required_params(%Spec{} = spec) do
    required_fields = get_in(@operation_contracts, [spec.operation, :required]) || []

    case Enum.find(required_fields, &(not valid_required_field?(spec, &1))) do
      nil ->
        validate_argument_shapes(spec)

      field ->
        {:error,
         %ValidationError{
           type: if(field == :column, do: :invalid_column, else: :invalid_arguments),
           message: "#{spec.operation} requires #{field}",
           details: %{operation: spec.operation, field: field}
         }}
    end
  end

  defp valid_required_field?(spec, :value), do: explicitly_provided?(spec, :value)

  defp valid_required_field?(spec, field) when field in [:column, :key_field, :value_field] do
    valid_field_reference?(Map.get(spec, field))
  end

  defp valid_required_field?(spec, :path), do: is_binary(spec.path) and spec.path != ""

  defp valid_field_reference?(field) when is_atom(field) and not is_nil(field), do: true
  defp valid_field_reference?(field) when is_binary(field), do: field != ""
  defp valid_field_reference?(_field), do: false

  defp explicitly_provided?(%Spec{provided: %MapSet{} = provided} = spec, field),
    do: MapSet.member?(provided, field) or not is_nil(Map.get(spec, field))

  defp explicitly_provided?(spec, field), do: not is_nil(Map.get(spec, field))

  defp validate_argument_shapes(%Spec{} = spec) do
    with :ok <- validate_supplied_fields(spec) do
      validate_operation_shape(spec)
    end
  end

  defp validate_operation_shape(%Spec{operation: :json_build_object, value: pairs}) do
    if is_list(pairs) and Enum.all?(pairs, &match?({_, _}, &1)) do
      :ok
    else
      invalid_arguments(:json_build_object, "value must be a list of {key, value} pairs", pairs)
    end
  end

  defp validate_operation_shape(%Spec{operation: :json_build_array, value: values}) do
    if is_list(values) do
      :ok
    else
      invalid_arguments(:json_build_array, "value must be a list", values)
    end
  end

  defp validate_operation_shape(_spec), do: :ok

  defp validate_supplied_fields(%Spec{} = spec) do
    allowed = MapSet.new([:as | allowed_payload_fields(spec.operation)])
    supplied = spec.provided || MapSet.new()
    unexpected = supplied |> MapSet.difference(allowed) |> MapSet.to_list() |> Enum.sort()

    case unexpected do
      [] ->
        :ok

      _ ->
        {:error,
         %ValidationError{
           type: :invalid_arguments,
           message: "#{spec.operation} received unsupported arguments",
           details: %{operation: spec.operation, unexpected: unexpected}
         }}
    end
  end

  defp allowed_payload_fields(operation),
    do: get_in(@operation_contracts, [operation, :fields]) || []

  defp invalid_arguments(operation, expectation, value) do
    {:error,
     %ValidationError{
       type: :invalid_arguments,
       message: "#{operation} #{expectation}",
       details: %{operation: operation, value: value}
     }}
  end

  # Validate JSON path syntax (basic validation)
  defp validate_json_path(%Spec{path: nil}), do: :ok

  defp validate_json_path(%Spec{path: path}) when is_binary(path) do
    # Basic JSONPath validation - should start with $ or be array index
    cond do
      String.starts_with?(path, "$") ->
        :ok

      # Array index like [0]
      String.match?(path, ~r/^\\[\\d+\\]$/) ->
        :ok

      # Simple key
      String.match?(path, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) ->
        :ok

      true ->
        {:error,
         %ValidationError{
           type: :invalid_path,
           message: "Invalid JSON path format: #{path}",
           details: %{path: path, expected: "JSONPath starting with $ or simple key/index"}
         }}
    end
  end

  defp validate_json_path(%Spec{path: path}) do
    {:error,
     %ValidationError{
       type: :invalid_path,
       message: "JSON path must be a string",
       details: %{path: path}
     }}
  end

  defp validate_operation_compatibility(%Spec{} = spec) do
    comparison = Map.get(spec.options || %{}, :comparison)

    cond do
      not is_nil(spec.path) and spec.operation in [:json_typeof, :json_array_length] ->
        invalid_arguments(
          spec.operation,
          "does not accept a path; extract the path first or operate on the whole column",
          spec.path
        )

      not is_nil(comparison) and spec.operation not in [:json_extract, :json_extract_text] ->
        invalid_arguments(spec.operation, "does not accept a comparison", comparison)

      not is_nil(comparison) and not valid_comparison?(comparison) ->
        invalid_arguments(
          spec.operation,
          "comparison must be {operator, value} with a supported operator",
          comparison
        )

      true ->
        :ok
    end
  end

  defp valid_comparison?({operator, _value})
       when operator in [:=, :==, :!=, :<>, :>, :>=, :<, :<=],
       do: true

  defp valid_comparison?(_comparison), do: false

  defp normalize_options(:json_object_agg, column, opts) do
    Keyword.put_new(opts, :key_field, column)
  end

  defp normalize_options(_operation, _column, opts), do: opts

  defp maybe_mark_column(provided, nil), do: provided
  defp maybe_mark_column(provided, _column), do: MapSet.put(provided, :column)

  # Extract additional options from keyword list
  defp extract_options(opts) do
    opts
    |> Keyword.drop([:path, :value, :key_field, :value_field, :as])
    |> Enum.into(%{})
  end

  # Generate unique ID for JSON operation
  defp generate_json_operation_id(operation, column) do
    unique = :erlang.unique_integer([:positive])
    "json_#{operation}_#{column}_#{unique}"
  end

  @doc """
  Determine if an operation is suitable for SELECT clauses.
  """
  def select_operation?(operation) do
    :select in allowed_clauses(operation)
  end

  @doc """
  Determine if an operation is suitable for WHERE clauses.
  """
  def filter_operation?(operation) do
    :filter in allowed_clauses(operation)
  end

  @doc """
  Determine if an operation is suitable for ORDER BY clauses.
  """
  def order_operation?(operation) do
    :order in allowed_clauses(operation)
  end

  defp allowed_clauses(operation) do
    get_in(@operation_contracts, [operation, :clauses]) || []
  end
end
