defmodule Selecto.Advanced.CTE do
  @moduledoc """
  Portable Common Table Expression (CTE) query intent.

  Provides comprehensive support for non-recursive and recursive CTEs, enabling
  hierarchical queries, query modularity, and complex data processing patterns.

  ## Examples

      # Non-recursive CTE
      selecto
      |> Selecto.with_cte("high_value_customers", fn ->
          Selecto.configure(customer_domain, connection)
          |> Selecto.select(["customer_id", "first_name", "last_name"])
          |> Selecto.aggregate([{"payment.amount", :sum, as: "total_spent"}])
          |> Selecto.join(:inner, "payment", on: "customer.customer_id = payment.customer_id")
          |> Selecto.group_by(["customer.customer_id", "customer.first_name", "customer.last_name"])
          |> Selecto.having([{"total_spent", {:>, 100}}])
        end,
        columns: ["customer_id", "first_name", "last_name", "total_spent"],
        join: [type: :inner, owner_key: :customer_id, related_key: :customer_id, fields: :infer]
      )
      |> Selecto.select(["film.title", "high_value_customers.first_name"])
      
      # Recursive CTE for hierarchical data
      selecto
      |> Selecto.with_recursive_cte("org_hierarchy",
          base_query: fn ->
            # Anchor: top-level managers
            Selecto.configure(employee_domain, connection)
            |> Selecto.select(["employee_id", "name", "manager_id", {:literal, 0, as: "level"}])
            |> Selecto.filter([{"manager_id", nil}])
          end,
          recursive_query: fn cte ->
            # Recursive: employees under each manager
            Selecto.configure(employee_domain, connection)
            |> Selecto.select(["employee.employee_id", "employee.name", "employee.manager_id", 
                              {:func, "org_hierarchy.level + 1", as: "level"}])
            |> Selecto.join(:inner, cte, on: "employee.manager_id = org_hierarchy.employee_id")
        end,
        columns: ["employee_id", "name", "manager_id", "level"],
        join: [type: :inner, owner_key: :employee_id, related_key: :employee_id, fields: :infer]
      )
  """

  defmodule Spec do
    @moduledoc """
    Specification for Common Table Expression definitions.
    """
    defstruct [
      # Unique identifier for the CTE
      :id,
      # CTE name (used in WITH clause)
      :name,
      # Function that builds the CTE query
      :query_builder,
      # Optional column list
      :columns,
      # :normal or :recursive
      :type,
      # For recursive CTEs - the anchor query
      :base_query,
      # For recursive CTEs - the recursive part
      :recursive_query,
      # List of other CTEs this depends on
      :dependencies,
      # Boolean indicating if CTE has been validated
      :validated
    ]

    @type cte_type :: :normal | :recursive

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            query_builder: (-> struct()) | nil,
            columns: [String.t()] | nil,
            type: cte_type(),
            base_query: (-> struct()) | nil,
            recursive_query: (struct() -> struct()) | nil,
            dependencies: [String.t()],
            validated: boolean()
          }
  end

  defmodule ValidationError do
    @moduledoc """
    Error raised when CTE specification is invalid.
    """
    defexception [:type, :message, :details]

    @type t :: %__MODULE__{
            type:
              :invalid_name
              | :invalid_query
              | :invalid_dependency
              | :missing_dependency
              | :duplicate_cte
              | :circular_dependency
              | :missing_recursive_parts,
            message: String.t(),
            details: map()
          }
  end

  @doc """
  Create a non-recursive CTE specification.

  ## Parameters

  - `name` - CTE name for the WITH clause
  - `query_builder` - Function that returns a Selecto query
  - `opts` - Options including :columns, :dependencies

  ## Examples

      # Simple CTE
      CTE.create_cte("active_customers", fn ->
        Selecto.configure(customer_domain, connection)
        |> Selecto.filter([{"active", true}])
      end)
      
      # CTE with explicit columns
      CTE.create_cte("customer_stats", 
        fn ->
          Selecto.configure(customer_domain, connection)
          |> Selecto.select(["customer_id", {:func, "COUNT", ["rental_id"], as: "rental_count"}])
          |> Selecto.join(:left, "rental", on: "customer.customer_id = rental.customer_id")
          |> Selecto.group_by(["customer_id"])
        end,
        columns: ["customer_id", "rental_count"]
      )
  """
  def create_cte(name, query_builder, opts \\ []) do
    spec = %Spec{
      id: generate_cte_id(name),
      name: name,
      query_builder: query_builder,
      columns: Keyword.get(opts, :columns),
      type: :normal,
      base_query: nil,
      recursive_query: nil,
      dependencies: Keyword.get(opts, :dependencies, []),
      validated: false
    }

    case validate_cte(spec) do
      {:ok, validated_spec} -> validated_spec
      {:error, validation_error} -> raise validation_error
    end
  end

  @doc """
  Create a recursive CTE specification.

  ## Parameters

  - `name` - CTE name for the WITH clause
  - `base_query` - Function that returns the anchor query
  - `recursive_query` - Function that takes the CTE reference and returns recursive query
  - `opts` - Options including :columns, :dependencies

  ## Examples

      # Hierarchical employee structure
      CTE.create_recursive_cte("employee_hierarchy",
        base_query: fn ->
          # Anchor: top-level managers
          Selecto.configure(employee_domain, connection)
          |> Selecto.select(["employee_id", "name", "manager_id", {:literal, 0, as: "level"}])
          |> Selecto.filter([{"manager_id", nil}])
        end,
        recursive_query: fn cte_ref ->
          # Recursive: subordinates
          Selecto.configure(employee_domain, connection)
          |> Selecto.select(["employee.employee_id", "employee.name", "employee.manager_id",
                            {:func, "employee_hierarchy.level + 1", as: "level"}])
          |> Selecto.join(:inner, cte_ref, on: "employee.manager_id = employee_hierarchy.employee_id")
        end
      )
  """
  def create_recursive_cte(name, opts) do
    base_query = Keyword.get(opts, :base_query)
    recursive_query = Keyword.get(opts, :recursive_query)

    unless is_function(base_query, 0) do
      raise ArgumentError, "base_query must be a function with arity 0"
    end

    unless is_function(recursive_query, 1) do
      raise ArgumentError, "recursive_query must be a function with arity 1"
    end

    spec = %Spec{
      id: generate_cte_id(name),
      name: name,
      query_builder: nil,
      columns: Keyword.get(opts, :columns),
      type: :recursive,
      base_query: base_query,
      recursive_query: recursive_query,
      dependencies: Keyword.get(opts, :dependencies, []),
      validated: false
    }

    case validate_cte(spec) do
      {:ok, validated_spec} -> validated_spec
      {:error, validation_error} -> raise validation_error
    end
  end

  @doc """
  Validate a CTE specification.

  Ensures the CTE name, query builder, and dependency declarations are valid.
  Cross-CTE checks such as missing references, duplicates, and cycles are
  performed by `validate_dependencies/1`.
  """
  def validate_cte(%Spec{} = spec) do
    with :ok <- validate_cte_name(spec.name),
         :ok <- validate_cte_queries(spec),
         :ok <- validate_cte_dependencies(spec) do
      validated_spec = %{spec | validated: true}
      {:ok, validated_spec}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Validate CTE name follows SQL identifier rules
  defp validate_cte_name(name) when is_binary(name) do
    cond do
      String.length(name) == 0 ->
        {:error,
         %ValidationError{
           type: :invalid_name,
           message: "CTE name cannot be empty",
           details: %{name: name}
         }}

      not String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) ->
        {:error,
         %ValidationError{
           type: :invalid_name,
           message: "CTE name must be a valid SQL identifier",
           details: %{name: name, expected: "Valid SQL identifier (letters, numbers, underscore)"}
         }}

      String.length(name) > 63 ->
        {:error,
         %ValidationError{
           type: :invalid_name,
           message: "CTE name too long (max 63 characters)",
           details: %{name: name, length: String.length(name)}
         }}

      true ->
        :ok
    end
  end

  defp validate_cte_name(name) do
    {:error,
     %ValidationError{
       type: :invalid_name,
       message: "CTE name must be a string",
       details: %{name: name}
     }}
  end

  # Validate CTE queries are properly formed
  defp validate_cte_queries(%Spec{type: :normal, query_builder: query_builder}) do
    if is_function(query_builder, 0) do
      :ok
    else
      {:error,
       %ValidationError{
         type: :invalid_query,
         message: "Normal CTE must have a query_builder function with arity 0",
         details: %{}
       }}
    end
  end

  defp validate_cte_queries(%Spec{
         type: :recursive,
         base_query: base_query,
         recursive_query: recursive_query
       }) do
    cond do
      not is_function(base_query, 0) ->
        {:error,
         %ValidationError{
           type: :missing_recursive_parts,
           message: "Recursive CTE must have a base_query function with arity 0",
           details: %{}
         }}

      not is_function(recursive_query, 1) ->
        {:error,
         %ValidationError{
           type: :missing_recursive_parts,
           message: "Recursive CTE must have a recursive_query function with arity 1",
           details: %{}
         }}

      true ->
        :ok
    end
  end

  defp validate_cte_dependencies(%Spec{dependencies: dependencies}) do
    cond do
      not is_list(dependencies) ->
        invalid_dependency_error(
          "CTE dependencies must be a list of valid CTE names",
          dependencies
        )

      invalid_dependency = Enum.find(dependencies, &(validate_dependency_name(&1) != :ok)) ->
        invalid_dependency_error(
          "Each CTE dependency must be a valid CTE name",
          dependencies,
          invalid_dependency
        )

      true ->
        :ok
    end
  end

  defp validate_dependency_name(name) when is_binary(name) do
    if String.length(name) in 1..63 and String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) do
      :ok
    else
      :error
    end
  end

  defp validate_dependency_name(_name), do: :error

  defp invalid_dependency_error(message, dependencies, dependency \\ nil) do
    details =
      %{dependencies: dependencies}
      |> then(fn details ->
        if is_nil(dependency), do: details, else: Map.put(details, :dependency, dependency)
      end)

    {:error,
     %ValidationError{
       type: :invalid_dependency,
       message: message,
       details: details
     }}
  end

  # Generate unique ID for CTE
  defp generate_cte_id(name) do
    unique = :erlang.unique_integer([:positive])
    "cte_#{name}_#{unique}"
  end

  @doc """
  Validate and order dependencies in a list of CTEs.

  Returns `{:ok, ordered_ctes}` in stable dependency order. Duplicate names,
  missing references, and cycles return distinct `ValidationError` types.
  """
  def validate_dependencies(ctes) when is_list(ctes) do
    with {:ok, validated_ctes} <- validate_cte_specs(ctes),
         :ok <- validate_unique_names(validated_ctes),
         :ok <- validate_dependency_references(validated_ctes),
         {:ok, ordered_names} <- topological_sort(validated_ctes) do
      specs_by_name = Map.new(validated_ctes, &{&1.name, &1})
      {:ok, Enum.map(ordered_names, &Map.fetch!(specs_by_name, &1))}
    end
  end

  defp validate_cte_specs(ctes) do
    Enum.reduce_while(ctes, {:ok, []}, fn
      %Spec{} = spec, {:ok, validated_specs} ->
        case validate_cte(spec) do
          {:ok, validated_spec} -> {:cont, {:ok, validated_specs ++ [validated_spec]}}
          {:error, validation_error} -> {:halt, {:error, validation_error}}
        end

      entry, {:ok, _validated_specs} ->
        {:halt,
         {:error,
          %ValidationError{
            type: :invalid_query,
            message: "CTE dependency validation requires CTE specifications",
            details: %{entry: entry}
          }}}
    end)
  end

  defp validate_unique_names(ctes) do
    names = Enum.map(ctes, & &1.name)
    counts = Enum.frequencies(names)
    duplicates = names |> Enum.filter(&(Map.fetch!(counts, &1) > 1)) |> Enum.uniq()

    case duplicates do
      [] ->
        :ok

      _ ->
        {:error,
         %ValidationError{
           type: :duplicate_cte,
           message: "CTE names must be unique within a query",
           details: %{duplicates: duplicates}
         }}
    end
  end

  defp validate_dependency_references(ctes) do
    known_names = ctes |> Enum.map(& &1.name) |> MapSet.new()

    missing =
      Enum.flat_map(ctes, fn cte ->
        cte.dependencies
        |> Enum.reject(&MapSet.member?(known_names, &1))
        |> Enum.map(&%{cte: cte.name, dependency: &1})
      end)

    case missing do
      [] ->
        :ok

      _ ->
        {:error,
         %ValidationError{
           type: :missing_dependency,
           message: "CTE dependencies must reference CTEs in the same query",
           details: %{missing: missing}
         }}
    end
  end

  defp topological_sort(ctes) do
    names = Enum.map(ctes, & &1.name)
    dependencies = Map.new(ctes, &{&1.name, &1.dependencies})
    topological_sort(names, dependencies, MapSet.new(), [])
  end

  defp topological_sort(names, dependencies, emitted, ordered) do
    case Enum.find(names, fn name ->
           not MapSet.member?(emitted, name) and
             Enum.all?(Map.fetch!(dependencies, name), &MapSet.member?(emitted, &1))
         end) do
      nil ->
        if MapSet.size(emitted) == length(names) do
          {:ok, Enum.reverse(ordered)}
        else
          remaining = Enum.reject(names, &MapSet.member?(emitted, &1))
          cycle = find_cycle(remaining, dependencies)

          {:error,
           %ValidationError{
             type: :circular_dependency,
             message: "Circular dependency detected in CTEs",
             details: %{cycle: cycle}
           }}
        end

      name ->
        topological_sort(
          names,
          dependencies,
          MapSet.put(emitted, name),
          [name | ordered]
        )
    end
  end

  defp find_cycle(names, dependencies) do
    Enum.find_value(names, [], &find_cycle_from(&1, dependencies, []))
  end

  defp find_cycle_from(name, dependencies, path) do
    case Enum.find_index(path, &(&1 == name)) do
      nil ->
        dependencies
        |> Map.fetch!(name)
        |> Enum.find_value(&find_cycle_from(&1, dependencies, path ++ [name]))

      cycle_start ->
        Enum.drop(path, cycle_start) ++ [name]
    end
  end
end
