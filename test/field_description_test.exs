defmodule Selecto.FieldDescriptionTest do
  use ExUnit.Case, async: true

  # Column and filter-choice descriptions (certification specification 3.1,
  # field descriptions): plain text for people choosing or reading a field.

  alias Selecto.Domain

  defp domain(description \\ :keep) do
    total =
      %{
        "type" => "decimal",
        "label" => "Total",
        "description" => "What the customer pays.\nTaxes included."
      }

    total =
      case description do
        :keep -> total
        :drop -> Map.delete(total, "description")
        value -> Map.put(total, "description", value)
      end

    %{
      "schema_version" => 1,
      "name" => "Orders",
      "domain_version" => "1",
      "source" => %{
        "source_table" => "orders",
        "primary_key" => "id",
        "fields" => ["id", "total", "secret", "customer_id"],
        "redact_fields" => [],
        "columns" => %{
          "id" => %{"type" => "integer"},
          "total" => total,
          "secret" => %{"type" => "string", "internal" => true, "description" => "Never shown."},
          "customer_id" => %{"type" => "integer"}
        },
        "associations" => %{
          "customer" => %{
            "queryable" => "customers",
            "field" => "customer",
            "owner_key" => "customer_id",
            "related_key" => "id",
            "cardinality" => "one"
          }
        }
      },
      "schemas" => %{
        "customers" => %{
          "source_table" => "customers",
          "primary_key" => "id",
          "fields" => ["id", "name"],
          "columns" => %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string", "description" => "The trading name."}
          }
        }
      },
      "joins" => %{},
      "components" => %{
        "filter_choices" => %{
          "total" => %{
            "label" => "Size",
            "description" => "Order size bands.",
            "choices" => [%{"value" => "1", "label" => "Small"}]
          }
        }
      }
    }
  end

  defp accepted?(domain), do: match?({:ok, _, _}, Domain.validate(domain))

  test "reads descriptions by field path" do
    assert Domain.field_description(domain(), "total") ==
             "What the customer pays.\nTaxes included."

    assert Domain.field_description(domain(), "customer.name") == "The trading name."
    assert Domain.field_description(domain(), :id) == nil
    assert Domain.field_description(domain(), "customer.missing") == nil
    assert Domain.filter_choice_description(domain(), "total") == "Order size bands."
  end

  test "reads descriptions from a normalized domain" do
    {:ok, normalized, _diagnostics} = Domain.validate(domain())

    assert Domain.field_description(normalized, "total") ==
             "What the customer pays.\nTaxes included."

    assert Domain.field_description(normalized, "customer.name") == "The trading name."
    assert Domain.filter_choice_description(normalized, :total) == "Order size bands."
  end

  test "a valid description is accepted" do
    assert accepted?(domain())
    assert accepted?(domain(:drop))
    assert accepted?(domain("Line one\nLine two"))
    assert accepted?(domain("Prix TTC, été"))
    assert accepted?(domain(String.duplicate("x", 1000)))
    # Code points, not UTF-16 units: an emoji is one character.
    assert accepted?(domain(String.duplicate("😀", 1000)))
  end

  test "an invalid column description makes the domain invalid" do
    for value <- [
          nil,
          "",
          "   ",
          [1],
          %{},
          5,
          String.duplicate("x", 1001),
          String.duplicate("😀", 1001),
          "a\tb",
          "a\rb",
          "a\u007Fb",
          "a\u0000b"
        ] do
      assert {:error, diagnostics} = Domain.validate(domain(value)), inspect(value)

      assert Enum.any?(
               diagnostics.errors,
               &(&1.code == :invalid_column_description and
                   &1.path == [:source, :columns, "total", :description])
             )
    end
  end

  test "an associated schema's column description follows the rule" do
    bad = put_in(domain(), ["schemas", "customers", "columns", "name", "description"], " ")
    assert {:error, diagnostics} = Domain.validate(bad)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_column_description))
  end

  test "a filter choice description follows the rule" do
    path = ["components", "filter_choices", "total", "description"]
    assert accepted?(put_in(domain(), path, "Bands."))

    for value <- [%{}, nil, "", "a\tb"] do
      assert {:error, diagnostics} = Domain.validate(put_in(domain(), path, value))
      assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_filter_choice_description))
    end
  end

  test "the runtime validator applies the rule too" do
    assert :ok = Selecto.DomainValidator.validate_domain(atomize(domain()))
    assert {:error, _} = Selecto.DomainValidator.validate_domain(atomize(domain(5)))
  end

  test "schema 2 columns take a description" do
    {:ok, %{document: v2}} = Domain.SchemaV2.migrate(domain())
    assert accepted?(v2)
    assert Domain.field_description(v2, "customer.name") == "The trading name."

    bad = put_in(v2, ["source", "columns", "total", "description"], 5)
    assert {:error, _} = Domain.validate(bad)
  end

  defp atomize(domain) do
    %{
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :total],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          total:
            Map.new(domain["source"]["columns"]["total"], fn {k, v} -> {String.to_atom(k), v} end)
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
