defmodule Selecto.FieldResolverSchemaJoinFieldTest do
  use ExUnit.Case, async: true

  alias Selecto.FieldResolver

  # A join whose fields come from its source schema's columns, which carry no
  # :field. The database field must be the column's own name, not "nil".
  test "a join field taken from schema columns keeps its own database name" do
    selecto = %Selecto{
      domain: %{schemas: %{"authors" => %{columns: %{name: %{type: :string}}}}},
      config: %{
        source: %{fields: [:id], redact_fields: [], columns: %{id: %{type: :integer}}},
        joins: %{author: %{source: :authors}}
      },
      set: %{}
    }

    assert {:ok, %{field: "name", source_join: :author}} =
             FieldResolver.resolve_field(selecto, "author.name")

    assert %{field: "name"} = FieldResolver.get_available_fields(selecto)["author.name"]
  end
end
