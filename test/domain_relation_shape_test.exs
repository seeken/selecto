defmodule Selecto.DomainRelationShapeTest do
  use ExUnit.Case, async: true

  alias Selecto.{Domain, DomainValidator}

  @relation %{
    source_table: "items",
    primary_key: :id,
    fields: [:id],
    columns: %{id: %{type: :integer}},
    associations: %{}
  }

  test "malformed mandatory relation values fail at both public validation boundaries" do
    malformed = [
      Map.merge(@relation, %{source_table: nil, primary_key: nil, fields: nil, columns: nil}),
      %{@relation | fields: nil},
      %{@relation | columns: nil},
      %{@relation | columns: 42},
      %{@relation | columns: "invalid"},
      %{@relation | columns: [1]},
      %{@relation | columns: %{id: 42}},
      %{@relation | source_table: nil},
      %{@relation | primary_key: nil}
    ]

    for relation <- malformed, placement <- [:source, :schema] do
      domain = domain(relation, placement)
      assert {:error, diagnostics} = Domain.validate(domain)
      assert diagnostics.errors != []
      assert {:error, errors} = DomainValidator.validate_domain(domain)
      assert errors != []
    end
  end

  test "portable source metadata rejects invalid values before projection" do
    for {key, value, code} <- [
          {:source_kind, :alien, :invalid_source_kind},
          {:source_kind, nil, :invalid_source_kind},
          {:readonly, "yes", :invalid_readonly},
          {:readonly, nil, :invalid_readonly}
        ],
        placement <- [:source, :schema] do
      domain = domain(Map.put(@relation, key, value), placement)
      assert {:error, diagnostics} = Domain.validate(domain)
      assert Enum.any?(diagnostics.errors, &(&1.code == code))
      assert {:error, _} = DomainValidator.validate_domain(domain)
    end
  end

  test "valid metadata and open column metadata remain usable" do
    for kind <- [:table, :view, :materialized_view, "table", "view", "materialized_view"],
        readonly <- [true, false] do
      relation = @relation |> Map.put(:source_kind, kind) |> Map.put(:readonly, readonly)
      relation = put_in(relation, [:columns, :id, :host_label], "Identity")
      authored = domain(relation, :source)
      assert {:ok, _, _} = Domain.validate(authored)
      assert :ok = DomainValidator.validate_domain(authored)
    end
  end

  test "non-map domains and relations produce structured runtime errors" do
    for invalid <- [nil, [], "items"] do
      assert {:error, _} = DomainValidator.validate_domain(invalid)
      assert {:error, _} = DomainValidator.validate_domain(%{source: invalid, schemas: %{}})
      assert {:error, _} = DomainValidator.validate_domain(%{source: @relation, schemas: invalid})
      assert {:error, _} = DomainValidator.validate_domain(domain(invalid, :schema))
    end
  end

  defp domain(relation, :source),
    do: %{name: "Shapes", source: relation, schemas: %{}, joins: %{}}

  defp domain(relation, :schema),
    do: %{name: "Shapes", source: @relation, schemas: %{other: relation}, joins: %{}}
end
