defmodule Selecto.ViewPublisher do
  @moduledoc """
  Validates Selecto-authored published view specs before any DDL generation.

  This keeps publication constraints separate from ordinary runtime query
  validation so domains can register stable SQL view contracts explicitly.
  """

  alias Selecto.SQL.QualifiedIdentifier
  alias Selecto.Dialect.View.{Definition, Index, Refresh}

  @type validation_result :: :ok | {:error, [String.t()]}
  @type publish_result ::
          {:ok,
           %{
             sql: String.t(),
             ddl: String.t(),
             kind: atom(),
             database_name: String.t(),
             index_statements: [String.t()]
           }}
          | {:error, [String.t()]}
  @type refresh_result :: :ok | {:error, term()}

  @spec validate(Selecto.Types.domain(), map()) :: validation_result()
  def validate(domain, spec) when is_map(domain) and is_map(spec) do
    identifier_errors = identifier_errors(spec)

    case build_query(domain, spec) do
      {:ok, query} ->
        errors =
          identifier_errors
          |> validate_selected_columns(query, spec)
          |> validate_runtime_params(query)

        case errors do
          [] -> :ok
          _ -> {:error, errors}
        end

      {:error, query_errors} ->
        {:error, identifier_errors ++ query_errors}
    end
  end

  def validate(_domain, _spec),
    do: {:error, ["published view validation requires a domain and map spec"]}

  @spec build_sql(Selecto.Types.domain(), map()) :: publish_result()
  def build_sql(domain, spec) when is_map(domain) and is_map(spec) do
    with :ok <- validate(domain, spec),
         {:ok, query} <- build_query(domain, spec) do
      {sql, _aliases, _params} = Selecto.Builder.Sql.build(query, [])
      database_name = spec[:database_name] || spec["database_name"]
      kind = spec[:kind] || spec["kind"]

      adapter = query.adapter

      with {:ok, ddl} <-
             render_view(adapter, :render_view_definition, %Definition{
               kind: kind,
               database_name: database_name,
               query_sql: sql
             }),
           {:ok, indexes} <- render_indexes(adapter, spec) do
        {:ok,
         %{
           sql: sql,
           ddl: ddl,
           kind: kind,
           database_name: database_name,
           index_statements: indexes
         }}
      end
    end
  end

  def build_sql(_domain, _spec),
    do: {:error, ["published view SQL generation requires a domain and map spec"]}

  @spec refresh(Selecto.Types.domain(), map(), module(), term(), keyword()) :: refresh_result()
  def refresh(domain, spec, adapter, connection, opts \\ [])

  def refresh(domain, spec, adapter, connection, opts)
      when is_map(domain) and is_map(spec) and is_atom(adapter) do
    with :ok <- validate(domain, spec),
         :ok <- validate_materialized_refresh_spec(spec),
         true <- function_exported?(adapter, :refresh_materialized_view, 3),
         {:ok, _result} <-
           apply(adapter, :refresh_materialized_view, [connection, database_name(spec), opts]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, {:unsupported_adapter, adapter}}
    end
  end

  def refresh(_domain, _spec, _adapter, _connection, _opts),
    do: {:error, :invalid_refresh_arguments}

  @spec ddl_for(module(), atom(), String.t(), String.t()) :: String.t()
  def ddl_for(adapter, kind, database_name, sql)
      when is_atom(adapter) and kind in [:view, :materialized_view] and
             is_binary(database_name) and is_binary(sql) do
    render_view!(adapter, :render_view_definition, %Definition{
      kind: kind,
      database_name: database_name,
      query_sql: sql
    })
  end

  @spec refresh_sql(module(), String.t(), keyword()) :: String.t()
  def refresh_sql(adapter, database_name, opts \\ [])
      when is_atom(adapter) and is_binary(database_name) do
    render_view!(adapter, :render_view_refresh, %Refresh{
      database_name: database_name,
      concurrently: Keyword.get(opts, :concurrently, false)
    })
  end

  @spec index_statements(module(), map()) :: [String.t()]
  def index_statements(adapter, spec) when is_atom(adapter) and is_map(spec) do
    case render_indexes(adapter, spec) do
      {:ok, statements} -> statements
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "; ")
    end
  end

  defp build_query(domain, spec) do
    query_builder = spec[:query] || spec["query"]
    adapter = spec[:adapter] || spec["adapter"]

    if is_nil(adapter) do
      {:error, [":adapter is required for published view compilation"]}
    else
      runtime = Selecto.Runtime.Context.new(adapter, :view_publisher)
      selecto = Selecto.configure(domain, runtime, validate: false)

      if is_function(query_builder, 1) do
        case query_builder.(selecto) do
          %Selecto{} = query -> {:ok, query}
          other -> {:error, [":query must return a Selecto struct, got: #{inspect(other)}"]}
        end
      else
        {:error, [":query must be a function with arity 1"]}
      end
    end
  end

  defp validate_identifiers(spec) do
    errors =
      []
      |> validate_qualified_identifier(database_name(spec), ":database_name")
      |> validate_column_identifiers(published_columns(spec), ":columns")
      |> validate_index_identifiers(spec)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp identifier_errors(spec) do
    case validate_identifiers(spec) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp validate_qualified_identifier(errors, identifier, label) do
    case QualifiedIdentifier.validate(identifier) do
      :ok -> errors
      {:error, error} -> ["#{label} #{QualifiedIdentifier.error_message(error)}" | errors]
    end
  end

  defp validate_column_identifiers(errors, columns, label) when is_map(columns) do
    Enum.reduce(columns, errors, fn {column, _spec}, acc ->
      validate_identifier_part(acc, column, label)
    end)
  end

  defp validate_column_identifiers(errors, _columns, _label), do: errors

  defp validate_identifier_part(errors, identifier, label) do
    case QualifiedIdentifier.validate_part(identifier) do
      :ok -> errors
      {:error, error} -> ["#{label} #{QualifiedIdentifier.error_message(error)}" | errors]
    end
  end

  defp validate_index_identifiers(errors, spec) do
    spec
    |> published_indexes()
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {index_spec, index}, acc when is_map(index_spec) ->
        columns = index_spec[:columns] || index_spec["columns"] || []

        acc =
          Enum.reduce(List.wrap(columns), acc, fn column, column_errors ->
            validate_identifier_part(column_errors, column, ":indexes[#{index}].columns")
          end)

        case columns do
          columns when is_list(columns) and columns != [] ->
            validate_identifier_part(acc, index_name(spec, columns), ":indexes[#{index}].name")

          _ ->
            acc
        end

      {_index_spec, _index}, acc ->
        acc
    end)
  end

  defp validate_selected_columns(errors, query, spec) do
    declared_columns = declared_column_names(spec)
    aliases = query_aliases(query)

    cond do
      aliases == [] ->
        errors ++ ["published view queries must select stable aliased columns"]

      Enum.sort(aliases) != Enum.sort(declared_columns) ->
        errors ++
          [
            "declared :columns #{inspect(declared_columns)} must exactly match query aliases #{inspect(aliases)}"
          ]

      true ->
        errors
    end
  end

  defp validate_runtime_params(errors, query) do
    {_sql, _aliases, params} = Selecto.Builder.Sql.build(query, [])

    if params == [] do
      errors
    else
      errors ++ ["published view queries cannot depend on runtime bind params"]
    end
  end

  defp declared_column_names(spec) do
    spec
    |> published_columns()
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  defp published_columns(spec) do
    spec[:columns] || spec["columns"] || %{}
  end

  defp published_indexes(spec) do
    spec[:indexes] || spec["indexes"] || []
  end

  defp index_fragment(spec, index_spec) do
    columns = index_spec[:columns] || index_spec["columns"] || []
    unique = index_spec[:unique] || index_spec["unique"] || false
    concurrently = index_spec[:concurrently] || index_spec["concurrently"] || false

    %Index{
      database_name: database_name(spec),
      index_name: index_name(spec, columns),
      columns: Enum.map(columns, &to_string/1),
      unique: unique,
      concurrently: concurrently
    }
  end

  defp render_indexes(adapter, spec) do
    spec
    |> published_indexes()
    |> Enum.reduce_while({:ok, []}, fn index_spec, {:ok, statements} ->
      case render_view(adapter, :render_view_index, index_fragment(spec, index_spec)) do
        {:ok, statement} -> {:cont, {:ok, statements ++ [statement]}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp render_view(adapter, callback, fragment) do
    case Selecto.DialectSupport.render_view(adapter, callback, fragment, %{adapter: adapter}) do
      {:ok, sql} -> {:ok, IO.iodata_to_binary(sql)}
      {:error, %Selecto.Error{} = error} -> {:error, [error.message]}
      {:error, reason} -> {:error, ["view dialect error: #{inspect(reason)}"]}
    end
  end

  defp render_view!(adapter, callback, fragment) do
    case render_view(adapter, callback, fragment) do
      {:ok, sql} -> sql
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "; ")
    end
  end

  defp index_name(spec, columns) do
    relation_name =
      spec
      |> database_name()
      |> String.split(".")
      |> List.last()

    suffix = columns |> Enum.map(&to_string/1) |> Enum.join("_")
    "#{relation_name}_#{suffix}_idx"
  end

  defp query_aliases(query) do
    {_sql, aliases, _params} = Selecto.Builder.Sql.build(query, [])

    aliases
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp validate_materialized_refresh_spec(spec) do
    case spec[:kind] || spec["kind"] do
      :materialized_view -> :ok
      _ -> {:error, :refresh_requires_materialized_view}
    end
  end

  defp database_name(spec), do: spec[:database_name] || spec["database_name"]
end
