defmodule Selecto.AdapterSQL do
  @moduledoc false

  alias Selecto.AdapterSupport

  def adapter(selecto_or_adapter)

  def adapter(%{adapter: adapter}) when not is_nil(adapter), do: adapter
  def adapter(%{}), do: AdapterSupport.default_adapter()
  def adapter(nil), do: AdapterSupport.default_adapter()
  def adapter(adapter) when is_atom(adapter), do: adapter
  def adapter(_other), do: AdapterSupport.default_adapter()

  def format_datetime(selecto, expression, format) do
    adapter = adapter(selecto)

    if AdapterSupport.callback_available?(adapter, :format_datetime, 2) do
      adapter.format_datetime(expression, format)
    else
      unsupported!(
        "adapter #{inspect(adapter)} does not implement datetime formatting",
        :datetime_format
      )
    end
  end

  def rollup_sql(selecto, grouped_clauses) do
    adapter = adapter(selecto)

    cond do
      AdapterSupport.callback_available?(adapter, :rollup_sql, 1) ->
        adapter.rollup_sql(grouped_clauses)

      true ->
        unsupported!("adapter #{inspect(adapter)} does not implement rollup rendering", :rollup)
    end
  end

  # A shape the adapter cannot render refuses typed through every execute
  # entry point (Selecto.Builder.ScopeRefusal).
  defp unsupported!(message, feature) do
    Selecto.Builder.ScopeRefusal.unsupported!(
      Selecto.Error.validation_error(message, %{unsupported_feature: feature})
    )
  end

  def rollup_literal_order(selecto, index) when is_integer(index) do
    adapter = adapter(selecto)

    cond do
      AdapterSupport.callback_available?(adapter, :rollup_literal_order, 1) ->
        adapter.rollup_literal_order(index)

      true ->
        [Integer.to_string(index), " asc"]
    end
  end

  def rollup_sort_fix(selecto) do
    adapter = adapter(selecto)
    connection = Selecto.Runtime.Context.connection(selecto)

    if AdapterSupport.callback_available?(adapter, :rollup_sort_fix, 1) do
      adapter.rollup_sort_fix(connection)
    else
      false
    end
  end

  def native_null_ordering?(selecto) do
    AdapterSupport.supports_feature?(adapter(selecto), :native_null_ordering)
  end

  def requires_order_for_pagination?(selecto) do
    AdapterSupport.supports_feature?(adapter(selecto), :requires_order_for_pagination)
  end

  def offset_fetch_pagination?(selecto) do
    AdapterSupport.supports_feature?(adapter(selecto), :offset_fetch_pagination)
  end

  def array_any_comparison?(selecto) do
    AdapterSupport.supports_feature?(adapter(selecto), :array_any_comparison)
  end
end
