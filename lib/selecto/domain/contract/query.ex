defmodule Selecto.Domain.Contract.Query do
  @moduledoc false

  alias Selecto.Domain.Contract.Query.FieldLists
  alias Selecto.Domain.Contract.Query.Filters
  alias Selecto.Domain.Contract.Query.Functions
  alias Selecto.Domain.Contract.QueryLibrary
  alias Selecto.Domain.Contract.Shared.Core

  def validate(errors, query, field_index) do
    errors
    |> FieldLists.validate_query_field_lists(query, field_index)
    |> Filters.validate_filters(query, field_index)
    |> Functions.validate_functions(query)
    |> QueryLibrary.validate(
      Core.map_value(query, :query_library),
      field_index,
      Core.map_value(query, :functions)
    )
  end
end
