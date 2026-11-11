defmodule Selecto.DomainSchemaV2Test do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.SchemaV2

  describe "jcs/1" do
    test "serializes the RFC 8785 example" do
      input =
        ~S({"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],) <>
          ~S("string":"€$\u000F\u000aA'B\"\\\\\"\/","literals":[null,true,false]})

      expected =
        ~S({"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],) <>
          ~s("string":"€$\\u000f\\nA'B\\"\\\\\\\\\\"/"})

      assert input |> Jason.decode!() |> SchemaV2.jcs() == expected
    end

    test "orders keys by UTF-16 code units" do
      # U+1F600 (surrogates D83D DE00) sorts before U+FB33 in UTF-16, after it in UTF-8.
      assert SchemaV2.jcs(%{"\u{FB33}" => 1, "\u{1F600}" => 2, "a" => 3}) ==
               ~s({"a":3,"\u{1F600}":2,"\u{FB33}":1})
    end

    test "formats numbers as ECMAScript does" do
      assert SchemaV2.jcs([0.0, -0.0, 1.0, 1.0e21, 1.0e20, 1.0e-7, 1.0e-6, -2.5, 123]) ==
               "[0,0,1,1e+21,100000000000000000000,1e-7,0.000001,-2.5,123]"
    end

    test "refuses integers beyond 2^53" do
      assert SchemaV2.jcs(9_007_199_254_740_992) == "9007199254740992"
      assert_raise ArgumentError, fn -> SchemaV2.jcs(9_007_199_254_740_993) end
    end

    test "serializes atom keys and values as strings" do
      assert SchemaV2.jcs(%{b: :x, a: nil}) == ~S({"a":null,"b":"x"})
    end
  end

  test "fingerprint/1 ignores a declared fingerprint" do
    document = %{"schema_version" => 2, "name" => "Orders"}
    expected = :crypto.hash(:sha256, ~S({"name":"Orders","schema_version":2}))

    assert SchemaV2.fingerprint(document) == Base.encode16(expected, case: :lower)

    assert SchemaV2.fingerprint(Map.put(document, "domain_fingerprint", "x")) ==
             SchemaV2.fingerprint(document)
  end

  describe "validate/1" do
    test "accepts a schema 2 document" do
      assert SchemaV2.validate(v2_domain()) == []
    end

    test "reports the version 2 rules with their paths" do
      document =
        v2_domain()
        |> put_in(["source", "fields"], ["id"])
        |> put_in(["source", "field_order"], ["id"])
        |> put_in(["tenant", "satisfied_by"], ["prefix", "prefix"])
        |> put_in(["tenant", "pins"], [["region", "eu"], ["nope", 1]])
        |> put_in(["tenant", "other"], true)
        |> Map.put("domain_fingerprint", "0000")

      assert SchemaV2.validate(document) == [
               %{code: :fields_removed, path: ["source", "fields"]},
               %{code: :invalid_field_order, path: ["source", "field_order"]},
               %{code: :unknown_tenant_key, path: ["tenant", "other"]},
               %{code: :invalid_tenant_satisfied_by, path: ["tenant", "satisfied_by"]},
               %{code: :invalid_tenant_pin, path: ["tenant", "pins", 1]},
               %{code: :domain_fingerprint_mismatch, path: ["domain_fingerprint"]}
             ]
    end

    test "accepts the computed fingerprint" do
      document = v2_domain()

      assert SchemaV2.validate(
               Map.put(document, "domain_fingerprint", SchemaV2.fingerprint(document))
             ) == []
    end
  end

  describe "migrate/1 and to_version_1/1" do
    test "migrates a schema 1 document and maps it back" do
      v1 = %{
        "schema_version" => 1,
        "name" => "Orders",
        "domain_fingerprint" => "declared",
        "source" => %{
          "source_table" => "orders",
          "primary_key" => "id",
          "tenant_field" => "org_id",
          "fields" => ["org_id", "id", "region"],
          "columns" => %{
            "id" => %{"type" => "integer"},
            "org_id" => %{"type" => "integer"},
            "region" => %{"type" => "string"}
          },
          "associations" => %{}
        },
        "schemas" => %{},
        "joins" => %{},
        "required_filters" => [["org_id", 7], ["region", "eu"]],
        "writes" => %{
          "scope" => %{"tenant" => %{"field" => "org_id", "satisfied_by" => ["prefix"]}}
        }
      }

      assert {:ok, %{document: v2, diagnostics: diagnostics}} = SchemaV2.migrate(v1)

      assert diagnostics == [
               %{code: :domain_schema_deprecated},
               %{code: :declared_fingerprint_dropped, value: "declared"}
             ]

      assert v2["schema_version"] == 2
      assert v2["source"]["field_order"] == ["org_id", "id", "region"]
      refute Map.has_key?(v2["source"], "fields")
      refute Map.has_key?(v2, "writes")

      assert v2["tenant"] == %{
               "field" => "org_id",
               "satisfied_by" => ["prefix"],
               "pins" => [["org_id", 7]]
             }

      assert v2["required_filters"] == [["region", "eu"]]
      assert SchemaV2.validate(v2) == []

      v1_form = SchemaV2.to_version_1(v2)
      assert v1_form["source"]["tenant_field"] == "org_id"
      assert v1_form["source"]["fields"] == ["org_id", "id", "region"]
      assert v1_form["required_filters"] == [["org_id", 7], ["region", "eu"]]
    end

    test "refuses fields that do not name the columns" do
      v1 = %{"source" => %{"fields" => ["id"], "columns" => %{"id" => %{}, "x" => %{}}}}

      assert SchemaV2.migrate(v1) ==
               {:refused, %{code: :domain_migration_ambiguous, path: ["source", "fields"]}}
    end

    test "refuses a document that is not version 1" do
      assert SchemaV2.migrate(%{"schema_version" => 2}) ==
               {:refused, %{code: :not_version_1, path: ["schema_version"]}}
    end
  end

  describe "Selecto.Domain.validate/1" do
    test "accepts a schema 2 domain through its version 1 form" do
      assert {:ok, normalized, diagnostics} = Domain.validate(v2_domain())
      assert diagnostics.schema_version == 2
      assert normalized.source["tenant_field"] == "org_id"
      refute :domain_schema_deprecated in Enum.map(diagnostics.warnings, & &1.code)
    end

    test "rejects a schema 2 domain with the rule code and path" do
      document = put_in(v2_domain(), ["tenant", "field"], "missing")

      assert {:error, diagnostics} = Domain.validate(document)
      assert [%{code: :invalid_tenant_field, path: ["tenant", "field"]}] = diagnostics.errors
    end

    test "validates a schema 1 domain without new warnings" do
      assert {:ok, _normalized, diagnostics} =
               Domain.validate(SchemaV2.to_version_1(v2_domain()))

      refute :domain_schema_deprecated in Enum.map(diagnostics.warnings, & &1.code)
    end
  end

  defp v2_domain do
    %{
      "schema_version" => 2,
      "name" => "Orders",
      "tenant" => %{"field" => "org_id", "pins" => [["region", "eu"]]},
      "source" => %{
        "source_table" => "orders",
        "primary_key" => "id",
        "columns" => %{
          "id" => %{"type" => "integer"},
          "org_id" => %{"type" => "integer"},
          "region" => %{"type" => "string"}
        },
        "field_order" => ["org_id", "id", "region"],
        "associations" => %{}
      },
      "schemas" => %{},
      "joins" => %{}
    }
  end
end
