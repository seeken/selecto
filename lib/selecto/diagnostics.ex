defmodule Selecto.Diagnostics do
  @moduledoc """
  Query diagnostics helpers (EXPLAIN / EXPLAIN ANALYZE).
  """

  alias Selecto.Error

  @type explain_result :: %{
          explain_sql: String.t(),
          query_sql: String.t(),
          params: list(),
          columns: [String.t()],
          rows: list(),
          plan_lines: [String.t()]
        }

  @doc """
  Run `EXPLAIN` for a Selecto query.
  """
  @spec explain(Selecto.t(), keyword()) :: {:ok, explain_result()} | {:error, Selecto.Error.t()}
  def explain(selecto, opts \\ []) do
    run_explain(selecto, Keyword.put_new(opts, :analyze, false))
  end

  @doc """
  Run `EXPLAIN ANALYZE` for a Selecto query.
  """
  @spec explain_analyze(Selecto.t(), keyword()) ::
          {:ok, explain_result()} | {:error, Selecto.Error.t()}
  def explain_analyze(selecto, opts \\ []) do
    run_explain(selecto, Keyword.put(opts, :analyze, true))
  end

  @doc """
  Build the explain SQL wrapper.
  """
  @spec build_explain_sql(String.t(), keyword()) :: String.t()
  def build_explain_sql(query_sql, opts \\ []) when is_binary(query_sql) do
    flags =
      []
      |> maybe_true_flag("ANALYZE", Keyword.get(opts, :analyze, false))
      |> maybe_true_flag("VERBOSE", Keyword.get(opts, :verbose, false))
      |> maybe_true_flag("BUFFERS", Keyword.get(opts, :buffers, false))
      |> maybe_true_flag("SETTINGS", Keyword.get(opts, :settings, false))
      |> maybe_true_flag("WAL", Keyword.get(opts, :wal, false))
      |> maybe_false_flag("TIMING", Keyword.get(opts, :timing, true))
      |> maybe_false_flag("COSTS", Keyword.get(opts, :costs, true))
      |> maybe_false_flag("SUMMARY", Keyword.get(opts, :summary, true))
      |> maybe_format_flag(Keyword.get(opts, :format))

    prefix =
      case flags do
        [] -> "EXPLAIN"
        _ -> "EXPLAIN (#{Enum.join(flags, ", ")})"
      end

    "#{prefix} #{query_sql}"
  end

  defp run_explain(selecto, opts) do
    to_sql_opts = Keyword.get(opts, :to_sql_opts, [])
    {query_sql, params} = Selecto.to_sql(selecto, to_sql_opts)

    with {:ok, explain_sql} <- adapter_explain_sql(selecto, query_sql, opts),
         {:ok, rows, columns} <- execute_raw(selecto, explain_sql, params) do
      detail_position = Enum.find_index(columns, &(to_string(&1) == "detail")) || 0

      plan_lines =
        Enum.map(rows, fn row ->
          case Enum.at(row, detail_position) do
            line when is_binary(line) -> line
            _ -> inspect(row)
          end
        end)

      {:ok,
       %{
         explain_sql: explain_sql,
         query_sql: query_sql,
         params: params,
         columns: columns,
         rows: rows,
         plan_lines: plan_lines
       }}
    end
  end

  defp adapter_explain_sql(selecto, query_sql, opts) do
    if Selecto.AdapterSupport.adapter_name(runtime_adapter(selecto)) == :sqlite do
      unsupported_options =
        Enum.filter([:verbose, :buffers, :settings, :wal, :timing, :costs, :summary], fn option ->
          Keyword.has_key?(opts, option)
        end)

      cond do
        Keyword.get(opts, :analyze, false) ->
          {:error,
           Error.validation_error(
             "SQLite does not support EXPLAIN ANALYZE; use explain/2 for EXPLAIN QUERY PLAN",
             %{adapter: :sqlite, feature: :explain_analyze}
           )}

        unsupported_options != [] or Keyword.get(opts, :format) not in [nil, :text] ->
          {:error,
           Error.validation_error(
             "SQLite EXPLAIN QUERY PLAN does not support PostgreSQL explain flags or non-text formats",
             %{adapter: :sqlite, unsupported_options: unsupported_options}
           )}

        true ->
          {:ok, "EXPLAIN QUERY PLAN " <> query_sql}
      end
    else
      {:ok, build_explain_sql(query_sql, opts)}
    end
  end

  defp execute_raw(selecto, sql, params) do
    adapter = runtime_adapter(selecto)
    connection = runtime_connection(selecto)

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :execute_raw, 3) ->
        case Kernel.apply(adapter, :execute_raw, [connection, sql, params]) do
          {:ok, result} ->
            {:ok, Map.get(result, :rows, []), Map.get(result, :columns, [])}

          {:error, reason} ->
            {:error, Error.from_reason(reason)}
        end

      selecto.adapter && Selecto.AdapterSupport.callback_available?(adapter, :execute, 4) ->
        case Kernel.apply(adapter, :execute, [connection, sql, params, []]) do
          {:ok, result} ->
            {:ok, Map.get(result, :rows, []), Map.get(result, :columns, [])}

          {:error, reason} ->
            {:error, Error.from_reason(reason)}
        end

      true ->
        {:error,
         Error.connection_error("Raw execution is unavailable for adapter", %{adapter: adapter})}
    end
  rescue
    e ->
      {:error, Error.from_reason(e)}
  end

  defp runtime_connection(selecto), do: Selecto.Runtime.Context.connection(selecto)
  defp runtime_adapter(selecto), do: Selecto.Runtime.Context.adapter(selecto)

  defp maybe_true_flag(flags, _name, nil), do: flags
  defp maybe_true_flag(flags, _name, false), do: flags
  defp maybe_true_flag(flags, name, true), do: flags ++ [name]

  defp maybe_false_flag(flags, _name, nil), do: flags
  defp maybe_false_flag(flags, _name, true), do: flags
  defp maybe_false_flag(flags, name, false), do: flags ++ ["#{name} false"]

  defp maybe_format_flag(flags, nil), do: flags

  defp maybe_format_flag(flags, format) when format in [:text, :json, :yaml, :xml] do
    flags ++ ["FORMAT #{String.upcase(to_string(format))}"]
  end

  defp maybe_format_flag(flags, _), do: flags
end
