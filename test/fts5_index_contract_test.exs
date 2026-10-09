defmodule Selecto.Fts5IndexContractTest do
  use ExUnit.Case, async: true

  defp domain do
    %{
      schema_version: 1,
      source: %{
        source_table: "people",
        primary_key: :id,
        fields: [:id, :name],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{},
        fts5_index: %{table: "people_fts", key: :id}
      },
      schemas: %{},
      joins: %{}
    }
  end

  test "an explicit root index survives canonical normalization and JSON authoring" do
    authored = domain()
    assert {:ok, normalized, _} = Selecto.Domain.validate(authored)
    assert normalized.source.fts5_index == authored.source.fts5_index
    json = authored |> Jason.encode!() |> Jason.decode!()
    assert {:ok, normalized_json, _} = Selecto.Domain.validate(json)

    assert Selecto.Domain.Shared.Map.map_value(normalized_json, :source)
           |> Selecto.Domain.Shared.Map.map_value(:fts5_index) == json["source"]["fts5_index"]

    refute Map.has_key?(Map.delete(authored.source, :fts5_index), :fts5_index)
  end

  test "index declaration is closed and refers to one public stored integer root key" do
    for invalid <- [
          put_in(domain(), [:source, :fts5_index], "people_fts"),
          put_in(domain(), [:source, :fts5_index], %{table: "people_fts"}),
          put_in(domain(), [:source, :fts5_index], %{table: "people_fts", key: :id, grant: true}),
          put_in(domain(), [:source, :fts5_index], %{table: "temp.people_fts", key: :id}),
          put_in(domain(), [:source, :fts5_index], %{table: "people_fts", key: :name}),
          put_in(domain(), [:source, :primary_key], [:id, :name]),
          put_in(domain(), [:source, :columns, :id, :type], :string),
          put_in(domain(), [:source, :columns, :id, :internal], true),
          put_in(domain(), [:source, :columns, :id, :computed], %{
            kind: :predicate,
            expression: ["eq", "name", "ada"]
          })
        ] do
      assert {:error, diagnostics} = Selecto.Domain.validate(invalid)
      assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_fts5_index))
    end
  end

  test "normalization never supplies an undeclared index" do
    authored = update_in(domain(), [:source], &Map.delete(&1, :fts5_index))
    assert {:ok, normalized, _} = Selecto.Domain.validate(authored)
    refute Map.has_key?(normalized.source, :fts5_index)
  end
end
