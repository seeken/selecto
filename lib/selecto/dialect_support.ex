defmodule Selecto.DialectSupport do
  @moduledoc false

  alias Selecto.{AdapterSupport, Error}

  def render_text_search_predicate(adapter, fragment, selecto) do
    render(adapter, :render_text_search_predicate, fragment, selecto, :text_search)
  end

  def render_text_search_rank(adapter, fragment, selecto) do
    render(adapter, :render_text_search_rank, fragment, selecto, :text_search_rank)
  end

  def render_interval(adapter, fragment, selecto) do
    render(adapter, :render_interval, fragment, selecto, :interval)
  end

  def render_json(adapter, callback, fragment, selecto)
      when callback in [
             :render_json_extraction,
             :render_json_contains,
             :render_json_key_exists,
             :render_json_array_contains,
             :render_json_array_contains_all,
             :render_json_operation
           ] do
    render(adapter, callback, fragment, selecto, :json)
  end

  def render_collection_operation(adapter, fragment, selecto) do
    render(adapter, :render_collection_operation, fragment, selecto, :collection_operation)
  end

  def render_datetime_operation(adapter, fragment, selecto) do
    render(adapter, :render_datetime_operation, fragment, selecto, :datetime_operation)
  end

  def render_text_normalization(adapter, fragment, selecto) do
    render(adapter, :render_text_normalization, fragment, selecto, :text_normalization)
  end

  def render_comparison(adapter, fragment, selecto) do
    render(adapter, :render_comparison, fragment, selecto, :case_insensitive_comparison)
  end

  def render_bucket(adapter, fragment, selecto) do
    render(adapter, :render_bucket, fragment, selecto, :bucket_expression)
  end

  def render_hierarchy_adjacency(adapter, fragment, selecto) do
    render(adapter, :render_hierarchy_adjacency, fragment, selecto, :hierarchy_adjacency)
  end

  def render_hierarchy_materialized_path(adapter, fragment, selecto) do
    render(
      adapter,
      :render_hierarchy_materialized_path,
      fragment,
      selecto,
      :hierarchy_materialized_path
    )
  end

  def render_table_function_join(adapter, fragment, selecto) do
    render(adapter, :render_table_function_join, fragment, selecto, :table_function_join)
  end

  def render_window_frame_boundary(adapter, fragment, selecto) do
    render(adapter, :render_window_frame_boundary, fragment, selecto, :window_frame_boundary)
  end

  def render_view(adapter, callback, fragment, context)
      when callback in [:render_view_definition, :render_view_refresh, :render_view_index] do
    render(adapter, callback, fragment, context, :view_publication)
  end

  defp render(adapter, callback, fragment, selecto, feature) do
    with {:ok, dialect} <- dialect(adapter),
         true <- AdapterSupport.callback_available?(dialect, callback, 2) do
      apply(dialect, callback, [fragment, selecto])
    else
      false -> unsupported(adapter, feature)
      {:error, _reason} = error -> error
    end
  end

  defp dialect(adapter) do
    if AdapterSupport.callback_available?(adapter, :dialect, 0) do
      case adapter.dialect() do
        dialect when is_atom(dialect) -> {:ok, dialect}
        invalid -> {:error, {:invalid_dialect, invalid}}
      end
    else
      {:error, :dialect_not_configured}
    end
  end

  defp unsupported(adapter, feature) do
    {:error,
     Error.validation_error("Adapter does not support the requested SQL fragment", %{
       adapter: AdapterSupport.adapter_name(adapter),
       unsupported_feature: feature
     })}
  end
end
