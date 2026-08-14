defmodule Selecto.Performance.QueryAnalyzer do
  @moduledoc """
  Adapter-neutral entry point for database query-plan analysis.

  The configured adapter owns EXPLAIN syntax, result parsing, catalog queries,
  and database-specific recommendations. Core only dispatches the request and
  combines normalized comparison evidence.
  """

  alias Selecto.AdapterSupport
  alias Selecto.Error
  alias Selecto.Runtime.Context

  @doc "Analyze a query through the configured adapter."
  def analyze_query(%Selecto{} = selecto, options \\ []) do
    dispatch(selecto, :analyze_query, [selecto, options], :query_analysis)
  end

  @doc "Get a query plan without executing the query."
  def get_query_plan(%Selecto{} = selecto, options \\ []) do
    analyze_query(selecto, Keyword.put(options, :analyze, false))
  end

  @doc "Analyze adapter-native index evidence for a query."
  def analyze_index_usage(%Selecto{} = selecto, options \\ []) do
    dispatch(selecto, :analyze_index_usage, [selecto, options], :index_analysis)
  end

  @doc "Fetch normalized table statistics through the configured adapter."
  def get_table_statistics(%Selecto{} = selecto, options \\ []) do
    dispatch(selecto, :table_statistics, [selecto, options], :table_statistics)
  end

  @doc "Compare two normalized adapter analysis reports."
  def compare_queries(%Selecto{} = selecto1, %Selecto{} = selecto2, options \\ []) do
    with {:ok, analysis1} <- analyze_query(selecto1, options),
         {:ok, analysis2} <- analyze_query(selecto2, options) do
      {:ok,
       %{
         query1: analysis1,
         query2: analysis2,
         performance_diff: numeric_differences(analysis1, analysis2)
       }}
    end
  end

  defp dispatch(selecto, callback, args, feature) do
    adapter = Context.adapter(selecto)

    cond do
      is_nil(adapter) ->
        {:error, Error.validation_error("Query analysis requires a configured adapter", %{})}

      not AdapterSupport.callback_available?(adapter, callback, length(args)) ->
        {:error,
         Error.validation_error("Adapter does not support the requested analysis", %{
           adapter: AdapterSupport.adapter_name(adapter),
           unsupported_feature: feature
         })}

      true ->
        apply(adapter, callback, args)
    end
  end

  defp numeric_differences(left, right) do
    [:execution_time, :planning_time, :total_cost, :actual_rows]
    |> Enum.reduce(%{}, fn key, differences ->
      case {Map.get(left, key), Map.get(right, key)} do
        {left_value, right_value} when is_number(left_value) and is_number(right_value) ->
          Map.put(differences, key, right_value - left_value)

        _values ->
          differences
      end
    end)
  end
end
