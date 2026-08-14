defmodule Selecto.Performance.QueryAnalyzerTest do
  use ExUnit.Case, async: true

  alias Selecto.Performance.QueryAnalyzer

  defmodule AnalysisAdapter do
    def name, do: :analysis_probe

    def analyze_query(_selecto, options) do
      multiplier = if Keyword.get(options, :analyze, true), do: 2, else: 1

      {:ok,
       %{
         execution_time: 10 * multiplier,
         planning_time: 2,
         total_cost: 30,
         actual_rows: 4,
         options: options
       }}
    end

    def analyze_index_usage(_selecto, _options),
      do: {:ok, %{indexes_used: ["users_pkey"], indexes_missing: []}}

    def table_statistics(_selecto, _options),
      do: {:ok, %{"users" => %{live_rows: 4}}}
  end

  defmodule UnsupportedAdapter do
    def name, do: :unsupported_analysis_probe
  end

  defp selecto(adapter \\ AnalysisAdapter) do
    %Selecto{
      adapter: adapter,
      runtime: %Selecto.Runtime.Context{adapter: adapter, connection: :probe}
    }
  end

  test "analysis dispatches to the configured adapter" do
    assert {:ok, %{execution_time: 20}} = QueryAnalyzer.analyze_query(selecto())

    assert {:ok, %{options: options}} =
             QueryAnalyzer.get_query_plan(selecto(), buffers: false)

    assert options[:analyze] == false
    assert options[:buffers] == false
  end

  test "index and table-statistics requests cross adapter callbacks" do
    assert {:ok, %{indexes_used: ["users_pkey"]}} =
             QueryAnalyzer.analyze_index_usage(selecto())

    assert {:ok, %{"users" => %{live_rows: 4}}} =
             QueryAnalyzer.get_table_statistics(selecto())
  end

  test "unsupported analysis fails closed with normalized evidence" do
    assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
             QueryAnalyzer.analyze_query(selecto(UnsupportedAdapter))

    assert details.adapter == :unsupported_analysis_probe
    assert details.unsupported_feature == :query_analysis
  end

  test "comparison computes only normalized numeric differences" do
    assert {:ok, comparison} = QueryAnalyzer.compare_queries(selecto(), selecto())

    assert comparison.performance_diff == %{
             actual_rows: 0,
             execution_time: 0,
             planning_time: 0,
             total_cost: 0
           }
  end
end
