defmodule Selecto.CanonicalAssociationFieldTest do
  use ExUnit.Case, async: true

  defp domain(association) do
    %{
      schema_version: 1,
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :person_id],
        redact_fields: [],
        columns: %{id: %{type: :integer}, person_id: %{type: :integer}},
        associations: %{person: association}
      },
      schemas: %{
        person: %{
          source_table: "people",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{person: %{type: :left, name: "Person"}}
    }
  end

  defp sql(domain) do
    {sql, _aliases, _params} =
      domain
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["id", "person.name"])
      |> Selecto.gen_sql([])

    String.downcase(sql)
  end

  test "a canonical association without field validates and queries through its key" do
    domain = domain(%{queryable: :person, owner_key: :person_id, related_key: :id})

    assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate(domain)
    assert sql(domain) =~ "left join people"
  end

  test "an explicit field is preserved for existing domains" do
    canonical = domain(%{queryable: :person, owner_key: :person_id, related_key: :id})

    explicit =
      domain(%{queryable: :person, field: :person, owner_key: :person_id, related_key: :id})

    assert sql(canonical) == sql(explicit)
  end
end
