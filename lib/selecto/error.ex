defmodule Selecto.Error do
  @moduledoc """
  Standardized error structure for all Selecto operations.

  Provides consistent error handling across the Selecto ecosystem with
  structured error information including context, query details, and
  actionable error types.

  ## Error Types

  - `:connection_error` - Database connection failures
  - `:query_error` - SQL query execution failures
  - `:validation_error` - Input validation failures
  - `:configuration_error` - Invalid domain or Selecto configuration
  - `:no_results` - Query returned no results when one expected
  - `:multiple_results` - Query returned multiple results when one expected
  - `:timeout_error` - Query execution timeout

  ## Examples

      # Connection error
      {:error, %Selecto.Error{
        type: :connection_error,
        message: "Failed to connect to database",
        details: %{host: "localhost", port: 5432}
      }}

      # Query error with context
      {:error, %Selecto.Error{
        type: :query_error,
        message: "Column 'invalid_col' does not exist",
        query: "SELECT invalid_col FROM users",
        params: [],
        details: %{column: "invalid_col", table: "users"}
      }}
  """

  defstruct [:type, :message, :details, :query, :params]

  # Driver exceptions carry the server's message and fields such as the query,
  # statement or connection id; DBConnection's own exceptions can quote bound
  # parameters. Either kind can carry SQL text, parameters and server detail.
  @driver_exception_fields [:connection_id, :query, :statement, :postgres, :mysql, :mssql]
  @dbconnection_exceptions [
    DBConnection.ConnectionError,
    DBConnection.EncodeError,
    DBConnection.TransactionError
  ]

  @driver_error_types [:query_error, :connection_error, :timeout_error]

  @sqlstate_categories %{
    "23505" => :unique_violation,
    "23503" => :foreign_key_violation,
    "23502" => :not_null_violation,
    "23514" => :check_violation,
    "57014" => :query_canceled,
    "40001" => :serialization_failure,
    "40P01" => :deadlock_detected
  }

  @driver_categories [:database_error | Map.values(@sqlstate_categories)]
  @recoverable_categories [:unique_violation, :foreign_key_violation, :not_null_violation]

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map() | nil,
          query: String.t() | nil,
          params: [term()] | nil
        }

  @type error_type ::
          :connection_error
          | :query_error
          | :validation_error
          | :configuration_error
          | :no_results
          | :multiple_results
          | :timeout_error
          | :field_resolution_error
          | :transformation_error

  @doc """
  Creates a connection error.
  """
  @spec connection_error(String.t(), map()) :: t()
  def connection_error(message, details \\ %{}) do
    %__MODULE__{
      type: :connection_error,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a query execution error with SQL context.
  """
  @spec query_error(String.t(), String.t() | nil, [term()], map()) :: t()
  def query_error(message, query \\ nil, params \\ [], details \\ %{}) do
    %__MODULE__{
      type: :query_error,
      message: message,
      query: query,
      params: params,
      details: details
    }
  end

  @doc """
  Creates a validation error.
  """
  @spec validation_error(String.t(), map()) :: t()
  def validation_error(message, details \\ %{}) do
    %__MODULE__{
      type: :validation_error,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a configuration error.
  """
  @spec configuration_error(String.t(), map()) :: t()
  def configuration_error(message, details \\ %{}) do
    %__MODULE__{
      type: :configuration_error,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a no results error for execute_one/2.
  """
  @spec no_results_error(String.t()) :: t()
  def no_results_error(message \\ "Query returned no results") do
    %__MODULE__{
      type: :no_results,
      message: message
    }
  end

  @doc """
  Creates a multiple results error for execute_one/2.
  """
  @spec multiple_results_error(String.t()) :: t()
  def multiple_results_error(message \\ "Query returned multiple results when one expected") do
    %__MODULE__{
      type: :multiple_results,
      message: message
    }
  end

  @doc """
  Creates a timeout error.
  """
  @spec timeout_error(String.t(), map()) :: t()
  def timeout_error(message, details \\ %{}) do
    %__MODULE__{
      type: :timeout_error,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a query generation error.
  """
  @spec query_generation_error(String.t(), map()) :: t()
  def query_generation_error(message, details \\ %{}) do
    %__MODULE__{
      type: :query_error,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a field resolution error with context.
  """
  @spec field_resolution_error(String.t(), term(), map()) :: t()
  def field_resolution_error(message, field_ref, context \\ %{}) do
    %__MODULE__{
      type: :field_resolution_error,
      message: message,
      details: Map.merge(context, %{field_reference: field_ref})
    }
  end

  @doc """
  Creates a transformation error for output format processing.
  """
  @spec transformation_error(String.t(), map()) :: t()
  def transformation_error(message, details \\ %{}) do
    %__MODULE__{
      type: :transformation_error,
      message: message,
      details: details
    }
  end

  @doc """
  Converts various error types to standardized Selecto.Error.

  Driver exceptions and raw driver reasons become `from_driver/2` errors, and
  connection handles, connection options and exit reasons are not kept, so the
  result never carries SQL, parameters, server detail or credentials.
  """
  @spec from_reason(term()) :: t()
  def from_reason({:invalid_connection, _connection}) do
    connection_error("Invalid adapter connection", %{reason: :invalid_connection})
  end

  def from_reason({:invalid_connection_options, reason}) do
    connection_error("Invalid adapter connection options", %{
      reason: if(is_atom(reason), do: reason, else: :invalid_connection_options)
    })
  end

  def from_reason({:exit, reason}) do
    connection_error("Database connection failed", exit_details(reason))
  end

  def from_reason(%{__exception__: true, message: message} = exception) do
    if driver_exception?(exception),
      do: from_driver(exception),
      else: query_error(message, nil, [], %{exception: exception})
  end

  def from_reason(:no_results) do
    no_results_error()
  end

  def from_reason(:multiple_results) do
    multiple_results_error()
  end

  def from_reason(reason) when is_binary(reason) do
    query_error(reason)
  end

  def from_reason(reason) when is_atom(reason) do
    query_error("Execution failed", nil, [], %{reason: reason})
  end

  def from_reason(reason), do: from_driver(reason)

  @doc """
  Builds the caller-facing error for a failure the database or its driver
  reported. `reason` is the raw driver reason and `normalized` the adapter's
  `normalize_error/1` result, when there is one.

  Driver messages and fields can carry SQL text, bound parameters, server
  detail such as `Key (email)=(x) already exists.`, and table, column and
  constraint names, so none of them is kept. The error keeps its type, a
  fixed message, and `details` with a safe `category`, the driver's
  `sqlstate` when it reports one, `recoverable?`, and the `reason` kind (an
  atom or the driver exception's module name). An adapter error of any other
  type than `:query_error`, `:connection_error` or `:timeout_error` is the
  adapter's own and is returned unchanged.
  """
  @spec from_driver(term(), t() | nil) :: t()
  def from_driver(reason, normalized \\ nil)

  def from_driver(_reason, %__MODULE__{type: type} = normalized)
      when type not in @driver_error_types,
      do: normalized

  def from_driver(reason, normalized) do
    sqlstate = sqlstate(reason, normalized)
    type = driver_error_type(reason, normalized)
    category = driver_category(normalized, sqlstate)

    details =
      %{
        category: category,
        reason: reason_kind(reason),
        recoverable?: category in @recoverable_categories
      }
      |> then(fn details ->
        if sqlstate, do: Map.put(details, :sqlstate, sqlstate), else: details
      end)

    %__MODULE__{type: type, message: driver_message(type, category), details: details}
  end

  @doc false
  # A safe summary of a raw failure reason: an atom, a tagged tuple's tag, or
  # an exception's module name.
  @spec reason_kind(term()) :: atom() | String.t()
  def reason_kind(%__MODULE__{type: type}), do: type
  def reason_kind(%{__struct__: module}) when is_atom(module), do: inspect(module)
  def reason_kind({kind, _details}) when is_atom(kind), do: kind
  def reason_kind({kind, _left, _right}) when is_atom(kind), do: kind
  def reason_kind(reason) when is_atom(reason), do: reason
  def reason_kind(_reason), do: :adapter_rejected

  @doc false
  # Exit reasons can hold call arguments such as SQL and parameters; only an
  # atom reason or a tagged reason's tag is kept.
  @spec exit_details(term()) :: map()
  def exit_details(reason) when is_atom(reason), do: %{exit_reason: reason}
  def exit_details({kind, _details}) when is_atom(kind), do: %{exit_reason: kind}
  def exit_details(_reason), do: %{}

  defp driver_exception?(%{__struct__: module} = exception),
    do:
      module in @dbconnection_exceptions or
        Enum.any?(@driver_exception_fields, &Map.has_key?(exception, &1))

  defp driver_error_type(_reason, %__MODULE__{type: type}), do: type
  defp driver_error_type(%DBConnection.ConnectionError{}, _normalized), do: :connection_error
  defp driver_error_type(_reason, _normalized), do: :query_error

  defp driver_category(%__MODULE__{details: %{category: category}}, _sqlstate)
       when category in @driver_categories,
       do: category

  defp driver_category(_normalized, sqlstate),
    do: Map.get(@sqlstate_categories, sqlstate, :database_error)

  # The SQLSTATE an adapter reports in `details.sqlstate`, or one a driver
  # error map carries as `sqlstate` or `pg_code`.
  defp sqlstate(reason, normalized) do
    normalized_details =
      case normalized do
        %__MODULE__{details: details} when is_map(details) -> [details]
        _ -> []
      end

    driver_fields = if is_map(reason), do: Enum.filter(Map.values(reason), &is_map/1), else: []

    (normalized_details ++ driver_fields)
    |> Enum.flat_map(&[Map.get(&1, :sqlstate), Map.get(&1, :pg_code)])
    |> Enum.find(&(is_binary(&1) and &1 =~ ~r/\A[0-9A-Z]{5}\z/))
  end

  defp driver_message(:connection_error, _category), do: "Database connection failed"
  defp driver_message(:timeout_error, _category), do: "Query timed out"
  defp driver_message(_type, :unique_violation), do: "Query violates a unique constraint"

  defp driver_message(_type, :foreign_key_violation),
    do: "Query violates a foreign key constraint"

  defp driver_message(_type, :not_null_violation), do: "Query violates a not-null constraint"
  defp driver_message(_type, :check_violation), do: "Query violates a check constraint"
  defp driver_message(_type, :query_canceled), do: "Query was canceled by the database"
  defp driver_message(_type, _category), do: "Query execution failed"

  @doc """
  Converts a Selecto.Error to an exception for raising.
  """
  @spec to_exception(t()) :: Exception.t()
  def to_exception(%__MODULE__{type: :connection_error, message: message}) do
    RuntimeError.exception("Database connection failed: #{message}")
  end

  def to_exception(%__MODULE__{message: message}) do
    RuntimeError.exception(message)
  end

  @doc """
  Creates a user-friendly error message for display.
  """
  @spec to_display_message(t()) :: String.t()
  def to_display_message(%__MODULE__{type: :connection_error, message: message}) do
    "Database connection failed: #{message}"
  end

  def to_display_message(%__MODULE__{type: :query_error, message: message}) do
    "Query execution failed: #{message}"
  end

  def to_display_message(%__MODULE__{type: :validation_error, message: message}) do
    "Validation error: #{message}"
  end

  def to_display_message(%__MODULE__{type: :configuration_error, message: message}) do
    "Configuration error: #{message}"
  end

  def to_display_message(%__MODULE__{type: :no_results}) do
    "No results found"
  end

  def to_display_message(%__MODULE__{type: :multiple_results}) do
    "Expected one result, but got multiple"
  end

  def to_display_message(%__MODULE__{type: :timeout_error, message: message}) do
    "Query timeout: #{message}"
  end

  def to_display_message(%__MODULE__{type: :field_resolution_error, message: message}) do
    "Field resolution error: #{message}"
  end

  def to_display_message(%__MODULE__{type: :transformation_error, message: message}) do
    "Output format transformation error: #{message}"
  end

  def to_display_message(%__MODULE__{message: message}) do
    message
  end
end
