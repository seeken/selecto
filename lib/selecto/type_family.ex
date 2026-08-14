defmodule Selecto.TypeFamily do
  @moduledoc """
  Canonical, database-neutral type families used by core and UI consumers.

  Concrete adapters may map native declared types into these families through
  `c:Selecto.DB.Adapter.type_family/1`.
  """

  @spec of(term()) :: atom()
  def of(type) when type in [:id, :integer, :float, :decimal], do: :number

  def of(type)
      when type in [:utc_datetime, :naive_datetime, :date, :datetime, :timestamp],
      do: :date

  def of(:boolean), do: :boolean
  def of(type) when type in [:string, :text], do: :text
  def of(:text_search_document), do: :text_search
  def of(:time), do: :time
  def of(:uuid), do: :uuid
  def of(:binary), do: :binary

  def of(type) when type in [:lookup, :star_dimension, :tag_dimension, :component, :link],
    do: :relation

  def of({:list, _type}), do: :list
  def of({:array, _type}), do: :list
  def of(:array), do: :list
  def of(type) when type in [:map, :json], do: :json

  def of(type)
      when type in [
             :geometry,
             :geography,
             :point,
             :linestring,
             :polygon,
             :multipoint,
             :multilinestring,
             :multipolygon,
             :geometrycollection
           ],
      do: :spatial

  def of(_type), do: :unknown
end
