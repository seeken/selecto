defmodule Selecto.AdapterSupport do
  @moduledoc false

  @feature_aliases %{
    text_search_boolean: [:text_search_boolean, :text_search_boolean_mode],
    text_search_query_expansion: [
      :text_search_query_expansion,
      :text_search_query_expansion_mode
    ]
  }

  def default_adapter do
    Application.get_env(:selecto, :default_adapter)
  end

  def adapter_name(nil), do: nil

  def adapter_name(adapter) when is_atom(adapter) do
    cond do
      callback_available?(adapter, :name, 0) ->
        adapter.name()

      true ->
        nil
    end
  end

  def adapter_name(_adapter), do: nil

  def supports_feature?(nil, _feature), do: false

  def supports_feature?(adapter, feature) when is_atom(adapter) and is_atom(feature) do
    if callback_available?(adapter, :supports?, 1) do
      feature
      |> feature_aliases()
      |> Enum.any?(&adapter.supports?/1)
    else
      false
    end
  end

  def supports_feature?(_adapter, _feature), do: false

  def capability(adapter, feature) when is_atom(feature) do
    if callback_available?(adapter, :capability, 1) do
      adapter.capability(feature)
    else
      %{
        feature: canonical_feature_name(feature),
        supported?: supports_feature?(adapter, feature)
      }
    end
  end

  def type_family(adapter, type) do
    if callback_available?(adapter, :type_family, 1) do
      adapter.type_family(type)
    else
      Selecto.TypeFamily.of(type)
    end
  end

  def normalize_type(adapter, type) do
    if callback_available?(adapter, :normalize_type, 1) do
      adapter.normalize_type(type)
    else
      Selecto.TypeSystem.normalize_type(type)
    end
  end

  def normalize_result(adapter, result) do
    if callback_available?(adapter, :normalize_execution_result, 1) do
      adapter.normalize_execution_result(result)
    else
      normalize_standard_result(result)
    end
  end

  def normalize_error(_adapter, %Selecto.Error{} = error), do: error

  def normalize_error(adapter, reason) do
    if callback_available?(adapter, :normalize_error, 1) do
      adapter.normalize_error(reason)
    else
      Selecto.Error.from_reason(reason)
    end
  end

  def canonical_feature_name(feature) when is_atom(feature) do
    Enum.find_value(@feature_aliases, feature, fn {canonical, aliases} ->
      if feature in aliases, do: canonical, else: nil
    end)
  end

  def canonical_feature_name(feature), do: feature

  defp feature_aliases(feature) when is_atom(feature) do
    canonical = canonical_feature_name(feature)
    Map.get(@feature_aliases, canonical, [canonical])
  end

  defp normalize_standard_result(%{rows: rows, columns: columns}) do
    {:ok, %{rows: rows || [], columns: Enum.map(columns || [], &to_string/1)}}
  end

  defp normalize_standard_result(result), do: {:error, {:invalid_adapter_result, result}}

  def callback_available?(adapter, function, arity)

  def callback_available?(adapter, function, arity)
      when is_atom(adapter) and is_atom(function) and is_integer(arity) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity)
  end

  def callback_available?(_adapter, _function, _arity), do: false
end
