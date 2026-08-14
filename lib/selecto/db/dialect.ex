defmodule Selecto.DB.Dialect do
  @moduledoc """
  Cohesive rendering contract for database-specific SQL fragments.

  Core owns the finite fragment structs and generic statement composition.
  Dialects own only syntax and validation that varies by database. A dialect
  must return a structured error for an unsupported fragment; core never falls
  back to another database's SQL.
  """

  alias Selecto.Dialect.TextSearch.{Predicate, Rank}
  alias Selecto.Dialect.Text.Normalization, as: TextNormalization
  alias Selecto.Dialect.Predicate.Comparison
  alias Selecto.Dialect.Bucket.Expression, as: BucketExpression
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Hierarchy.{Adjacency, MaterializedPath}
  alias Selecto.Dialect.TableFunction.Join, as: TableFunctionJoin
  alias Selecto.Dialect.Window.FrameBoundary
  alias Selecto.Dialect.View.{Definition, Index, Refresh}
  alias Selecto.Dialect.Interval

  alias Selecto.Dialect.Json.{
    ArrayContains,
    ArrayContainsAll,
    Contains,
    Extraction,
    KeyExists,
    Operation
  }

  @type render_result :: {:ok, iodata() | term()} | {:error, term()}

  @callback render_text_search_predicate(Predicate.t(), Selecto.t()) :: render_result()
  @callback render_text_search_rank(Rank.t(), Selecto.t()) :: render_result()
  @callback render_interval(Interval.t(), Selecto.t()) :: render_result()
  @callback render_json_extraction(Extraction.t(), Selecto.t() | map()) :: render_result()
  @callback render_json_contains(Contains.t(), Selecto.t() | map()) :: render_result()
  @callback render_json_key_exists(KeyExists.t(), Selecto.t() | map()) :: render_result()
  @callback render_json_array_contains(ArrayContains.t(), Selecto.t() | map()) :: render_result()
  @callback render_json_array_contains_all(ArrayContainsAll.t(), Selecto.t() | map()) ::
              render_result()

  @callback render_json_operation(Operation.t(), Selecto.t() | map()) :: render_result()
  @callback render_collection_operation(CollectionOperation.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_datetime_operation(DateTimeOperation.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_text_normalization(TextNormalization.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_comparison(Comparison.t(), Selecto.t() | map()) :: render_result()
  @callback render_bucket(BucketExpression.t(), Selecto.t() | map()) :: render_result()
  @callback render_hierarchy_adjacency(Adjacency.t(), Selecto.t() | map()) :: render_result()
  @callback render_hierarchy_materialized_path(MaterializedPath.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_table_function_join(TableFunctionJoin.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_window_frame_boundary(FrameBoundary.t(), Selecto.t() | map()) ::
              render_result()
  @callback render_view_definition(Definition.t(), Selecto.t() | map()) :: render_result()
  @callback render_view_refresh(Refresh.t(), Selecto.t() | map()) :: render_result()
  @callback render_view_index(Index.t(), Selecto.t() | map()) :: render_result()

  @optional_callbacks render_text_search_predicate: 2,
                      render_text_search_rank: 2,
                      render_interval: 2,
                      render_json_extraction: 2,
                      render_json_contains: 2,
                      render_json_key_exists: 2,
                      render_json_array_contains: 2,
                      render_json_array_contains_all: 2,
                      render_json_operation: 2,
                      render_collection_operation: 2,
                      render_datetime_operation: 2,
                      render_text_normalization: 2,
                      render_comparison: 2,
                      render_bucket: 2,
                      render_hierarchy_adjacency: 2,
                      render_hierarchy_materialized_path: 2,
                      render_table_function_join: 2,
                      render_window_frame_boundary: 2,
                      render_view_definition: 2,
                      render_view_refresh: 2,
                      render_view_index: 2
end
