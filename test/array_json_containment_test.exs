defmodule Selecto.ArrayJsonContainmentTest do
  use ExUnit.Case, async: true

  defp domain do
    %{
      name: "Assets",
      source: %{
        source_table: "assets",
        primary_key: :id,
        fields: [:id, :metadata, :tags],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          tags: %{type: {:array, :string}},
          metadata: %{type: :jsonb}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp sql(query) do
    {sql, _aliases, params} = Selecto.gen_sql(query, [])
    {sql, params}
  end

  test "json containment accepts jsonb columns" do
    {sql, _params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["id"])
      |> Selecto.filter({"metadata", {:json_contains, %{"power" => "three_phase"}}})
      |> sql()

    assert sql =~ "@>"
    assert sql =~ "::jsonb"
  end

  test "unnest columns address the table function's value and ordinality columns" do
    {sql, _params} =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.unnest("tags", as: "tag_rows", ordinality: "position")
      |> Selecto.select(["id", "tag_rows", "tag_rows_ordinality"])
      |> sql()

    assert sql =~ ~r/tag_rows\.value/
    assert sql =~ ~r/tag_rows\.position/
    assert sql =~ "WITH ORDINALITY AS tag_rows(value, position)"
  end
end
