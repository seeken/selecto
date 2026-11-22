defmodule Selecto.PerlAlignmentTest do
  use ExUnit.Case, async: true

  defp domain do
    %{
      name: "Alignment",
      source: %{
        source_table: "records",
        primary_key: :id,
        fields: [:id, :active],
        redact_fields: [],
        columns: %{id: %{type: :integer}, active: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  test "numeric string bounds normalize numerically before overlap and ordering checks" do
    buckets = [%{label: "later", min: "10"}, %{label: "early", min: "-2", max: "9"}]
    computed = %{kind: :bucket, field: "id", buckets: buckets}
    authored = put_in(domain(), [:source, :columns, :band], %{type: :string, computed: computed})
    assert {:ok, normalized, _} = Selecto.Domain.validate(authored)

    assert normalized.source.columns.band.computed.expression == [
             "case",
             [["gte", "id", 10], ["literal", "later", "string"]],
             [["and", ["gte", "id", -2], ["lte", "id", 9]], ["literal", "early", "string"]]
           ]
  end

  test "decimal strings retain numeric meaning and malformed strings refuse" do
    for bound <- ["-1.25", "0", "10.5"] do
      shorthand = %{kind: :bucket, field: "id", buckets: [%{label: "a", min: bound}]}

      {_, errors} =
        Selecto.Domain.Shorthand.Computed.expand(
          put_in(domain(), [:source, :columns, :band], %{type: :string, computed: shorthand})
        )

      assert errors == []
    end

    for bound <- ["1e2", "+1", " 1", "1 ", "NaN", "1x", ".5", "1."] do
      shorthand = %{kind: :bucket, field: "id", buckets: [%{label: "a", min: bound}]}

      {_, errors} =
        Selecto.Domain.Shorthand.Computed.expand(
          put_in(domain(), [:source, :columns, :band], %{type: :string, computed: shorthand})
        )

      refute errors == []
    end
  end

  test "enabled tenant requirement recognizes the declared custom tenant column" do
    authored =
      domain()
      |> put_in([:source, :tenant_field], :active)
      |> Map.put(:tenant_required, true)
      |> Map.put(:required_filters, [{"active", 1}])

    query = authored |> Selecto.configure(:compile_only) |> Selecto.select(["id"])
    assert :ok = Selecto.Tenant.validate_scope(query)
    assert {_, [1]} = Selecto.to_sql(query)
  end

  test "invalid tenant requirement shapes refuse runtime admission even without validation" do
    for flag <- ["true", "false", 2, "", [], %{}], validate <- [true, false] do
      assert_raise Selecto.DomainValidator.ValidationError, fn ->
        Selecto.configure(Map.put(domain(), :tenant_required, flag), :compile_only,
          validate: validate
        )
      end
    end
  end

  test "bare query library ordering refuses full construction with a stable diagnostic" do
    authored = Map.put(domain(), :query_library, %{orderings: %{bare: %{order_by: ["id"]}}})
    # Metadata retains its existing admission; executable construction is stricter.
    assert {:ok, _, _} = Selecto.Domain.validate(authored)
    assert {:error, errors} = Selecto.DomainValidator.validate_domain(authored)
    assert Enum.any?(errors, &(&1.code == :invalid_query_library))

    assert_raise Selecto.DomainValidator.ValidationError, fn ->
      Selecto.configure(authored, :compile_only)
    end
  end
end
