defmodule Selecto.RelatedRows do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M

  def config(query, association, fields) do
    {:ok, edge} =
      case M.fetch_key(query.domain.source.associations, association) do
        {:ok, edge} when is_map(edge) -> {:ok, edge}
        _ -> raise ArgumentError, "unknown related_rows association"
      end

    target = M.map_value(edge, :queryable)

    id =
      Enum.find(
        Map.keys(query.domain.source.associations),
        &(to_string(&1) == to_string(association))
      )

    temporary =
      Selecto.subselect(query, [
        %{
          target_schema: target,
          join_path: [id],
          fields: fields,
          format: :json_agg,
          alias: "selecto_related_rows"
        }
      ])

    temporary |> Selecto.Subselect.get_subselect_configs() |> List.last()
  end
end
