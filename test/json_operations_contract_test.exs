defmodule Selecto.JsonOperationsContractTest do
  use ExUnit.Case, async: true

  alias Selecto.Advanced.JsonOperations
  alias Selecto.Advanced.JsonOperations.ValidationError
  alias Selecto.Builder.JsonOperations, as: Builder
  alias Selecto.TestSQLParams, as: Params

  @valid_operations [
    {:json_extract, "metadata", [path: "$.status"]},
    {:json_extract_text, "metadata", [path: "$.status"]},
    {:json_contains, "metadata", [value: %{"active" => true}]},
    {:json_contained, "metadata", [value: %{"active" => true}]},
    {:json_exists, "metadata", [path: "status"]},
    {:json_path_exists, "metadata", [path: "$.status"]},
    {:json_agg, "metadata", []},
    {:json_object_agg, "id", [value_field: "metadata"]},
    {:json_build_object, nil, [value: [{"active", true}]]},
    {:json_build_array, nil, [value: [1, 2, 3]]},
    {:json_set, "metadata", [path: "$.active", value: true]},
    {:json_remove, "metadata", [path: "$.legacy"]},
    {:json_typeof, "metadata", []},
    {:json_array_length, "metadata", []}
  ]

  test "the reduced operation vocabulary has validated canonical shapes" do
    Enum.each(@valid_operations, fn {operation, column, opts} ->
      assert %{operation: ^operation, validated: true} =
               JsonOperations.create_json_operation(operation, column, opts)
    end)
  end

  test "removed aliases and insertion operation are rejected" do
    for operation <- [:json_extract_path, :json_extract_path_text, :json_insert] do
      assert_raise ValidationError, ~r/Unsupported JSON operation/, fn ->
        JsonOperations.create_json_operation(operation, "metadata", path: "$.status")
      end
    end
  end

  test "required and operation-specific arguments fail closed" do
    invalid_specs = [
      {:json_extract, nil, [path: "$.status"]},
      {:json_extract, "metadata", []},
      {:json_contains, "metadata", []},
      {:json_object_agg, "id", []},
      {:json_build_object, nil, [value: ["key", "value"]]},
      {:json_build_array, nil, [value: :not_a_list]},
      {:json_set, "metadata", [path: "$.status"]},
      {:json_remove, "metadata", []},
      {:json_typeof, "metadata", [path: "$.status"]}
    ]

    Enum.each(invalid_specs, fn {operation, column, opts} ->
      assert_raise ValidationError, fn ->
        JsonOperations.create_json_operation(operation, column, opts)
      end
    end)
  end

  test "explicit JSON null remains distinguishable from an absent value" do
    assert %{value: nil, validated: true} =
             JsonOperations.create_json_operation(:json_contains, "metadata", value: nil)

    assert_raise ValidationError, ~r/requires value/, fn ->
      JsonOperations.create_json_operation(:json_contains, "metadata")
    end
  end

  test "clause validation rejects operations outside their contract" do
    contains =
      JsonOperations.create_json_operation(:json_contains, "metadata", value: %{"a" => 1})

    agg = JsonOperations.create_json_operation(:json_agg, "metadata")
    extract = JsonOperations.create_json_operation(:json_extract, "metadata", path: "$.a")

    assert {:error, %ValidationError{type: :invalid_clause}} =
             JsonOperations.validate_operation_clause(contains, :select)

    assert {:error, %ValidationError{type: :invalid_clause}} =
             JsonOperations.validate_operation_clause(agg, :filter)

    assert {:error, %ValidationError{type: :invalid_arguments}} =
             JsonOperations.validate_operation_clause(extract, :filter)
  end

  test "extraction filters compile comparisons with bound parameters" do
    spec =
      JsonOperations.create_json_operation(:json_extract_text, "metadata",
        path: "$.status",
        comparison: {:=, "active"}
      )

    filter = Builder.build_json_filter(spec, adapter: SelectoDBPostgreSQL.Adapter)
    {sql, params} = Params.finalize(filter)

    assert sql =~ ~r/metadata.*->>.*= \$1/i
    assert params == ["active"]
  end

  test "object aggregation normalizes its key column" do
    spec =
      JsonOperations.create_json_operation(:json_object_agg, "product_id", value_field: "price")

    assert spec.key_field == "product_id"
    assert spec.value_field == "price"
  end

  test "high-level object aggregation tuple keeps key and value fields distinct" do
    domain = %{
      name: "JsonContract",
      source: %{
        source_table: "products",
        primary_key: :product_id,
        fields: [:product_id, :price],
        redact_fields: [],
        columns: %{
          product_id: %{type: :integer},
          price: %{type: :decimal}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    selecto =
      domain
      |> Selecto.configure(nil, adapter: SelectoDBPostgreSQL.Adapter, validate: false)
      |> Selecto.json_select({:json_object_agg, "product_id", "price", as: "price_map"})

    assert [%{key_field: "product_id", value_field: "price", alias: "price_map"}] =
             selecto.set.json_selects
  end
end
