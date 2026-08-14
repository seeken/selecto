defmodule Selecto.JsonTest do
  use ExUnit.Case, async: true

  alias Selecto.Json

  defp domain do
    %{
      columns: %{
        "attributes" => %{
          type: :json,
          schema: %{
            "color" => %{type: :string},
            "weight" => %{type: :decimal},
            "dimensions" => %{
              type: :object,
              schema: %{"length" => %{type: :decimal}, "width" => %{type: :decimal}}
            },
            "items" => %{
              type: :array,
              items: %{type: :object, schema: %{"sku" => %{type: :string}}}
            },
            "tags" => %{type: :array, items: %{type: :string}}
          }
        },
        "name" => %{type: :string}
      }
    }
  end

  test "parse_field_reference distinguishes JSON paths" do
    assert {:json_path, "attributes", ["color"]} =
             Json.parse_field_reference("attributes.color", domain())

    assert {:json_path, "attributes", ["dimensions", "length"]} =
             Json.parse_field_reference("attributes.dimensions.length", domain())

    assert {:regular, "name"} = Json.parse_field_reference("name", domain())
    assert {:regular, "users.name"} = Json.parse_field_reference("users.name", domain())
    assert {:regular, :name} = Json.parse_field_reference(:name, domain())
  end

  test "get_path_schema resolves nested object and array object paths" do
    assert %{type: :string} = Json.get_path_schema(domain(), "attributes", ["color"])

    assert %{type: :decimal} =
             Json.get_path_schema(domain(), "attributes", ["dimensions", "length"])

    assert %{type: :string} = Json.get_path_schema(domain(), "attributes", ["items", "sku"])
    assert nil == Json.get_path_schema(domain(), "attributes", ["missing"])
    assert nil == Json.get_path_schema(domain(), "name", ["x"])
  end

  test "build_extraction supports alias path operators and casts" do
    assert ~s("attributes"->>'color') ==
             Json.build_extraction("attributes", ["color"], adapter: SelectoDBPostgreSQL.Adapter)

    assert ~s("u"."attributes"#>ARRAY['dimensions', 'length']) ==
             Json.build_extraction("attributes", ["dimensions", "length"],
               as_text: false,
               table_alias: "u",
               adapter: SelectoDBPostgreSQL.Adapter
             )

    assert "(\"attributes\"#>>ARRAY['dimensions', 'length'])::numeric" ==
             Json.build_extraction("attributes", ["dimensions", "length"],
               cast: :decimal,
               adapter: SelectoDBPostgreSQL.Adapter
             )
  end

  test "build_extraction supports mssql json value and query functions" do
    assert "JSON_VALUE([u].[attributes], '$.color')" ==
             Json.build_extraction("attributes", ["color"],
               adapter: SelectoDBMSSQL.Adapter,
               table_alias: "u"
             )

    assert "JSON_QUERY([u].[attributes], '$.dimensions')" ==
             Json.build_extraction("attributes", ["dimensions"],
               adapter: SelectoDBMSSQL.Adapter,
               table_alias: "u",
               as_text: false
             )

    assert "CAST(JSON_VALUE([u].[attributes], '$.dimensions.length') AS decimal(38, 10))" ==
             Json.build_extraction("attributes", ["dimensions", "length"],
               adapter: SelectoDBMSSQL.Adapter,
               table_alias: "u",
               cast: :decimal
             )
  end

  test "build_extraction supports mysql json extract functions" do
    assert "JSON_UNQUOTE(JSON_EXTRACT(`u`.`attributes`, '$.color'))" ==
             Json.build_extraction("attributes", ["color"],
               adapter: SelectoDBMySQL.Adapter,
               table_alias: "u"
             )

    assert "JSON_EXTRACT(`u`.`attributes`, '$.dimensions')" ==
             Json.build_extraction("attributes", ["dimensions"],
               adapter: SelectoDBMySQL.Adapter,
               table_alias: "u",
               as_text: false
             )

    assert "CAST(JSON_UNQUOTE(JSON_EXTRACT(`u`.`attributes`, '$.dimensions.length')) AS DECIMAL(38, 10))" ==
             Json.build_extraction("attributes", ["dimensions", "length"],
               adapter: SelectoDBMySQL.Adapter,
               table_alias: "u",
               cast: :decimal
             )
  end

  test "build_extraction supports sqlite json_extract functions" do
    assert ~s|json_extract("u"."attributes", '$.color')| ==
             Json.build_extraction("attributes", ["color"],
               adapter: SelectoDBSQLite.Adapter,
               table_alias: "u"
             )

    assert ~s|json_extract("u"."attributes", '$.dimensions')| ==
             Json.build_extraction("attributes", ["dimensions"],
               adapter: SelectoDBSQLite.Adapter,
               table_alias: "u",
               as_text: false
             )

    assert ~s|CAST(json_extract("u"."attributes", '$.dimensions.length') AS NUMERIC)| ==
             Json.build_extraction("attributes", ["dimensions", "length"],
               adapter: SelectoDBSQLite.Adapter,
               table_alias: "u",
               cast: :decimal
             )
  end

  test "build_contains and key existence expressions" do
    contains =
      Json.build_contains("attributes", %{"color" => "red"},
        table_alias: "u",
        adapter: SelectoDBPostgreSQL.Adapter
      )

    assert String.contains?(contains, ~s("u"."attributes" @>))
    assert String.contains?(contains, "::jsonb")

    assert ~s("attributes" ? 'color') ==
             Json.build_key_exists("attributes", "color", adapter: SelectoDBPostgreSQL.Adapter)

    assert ~s("attributes" ? 'color') ==
             Json.build_key_exists("attributes", ["color"], adapter: SelectoDBPostgreSQL.Adapter)

    nested =
      Json.build_key_exists("attributes", ["dimensions", "length"],
        adapter: SelectoDBPostgreSQL.Adapter
      )

    assert String.contains?(nested, "? 'length'")
    assert String.contains?(nested, "->'dimensions'")
  end

  test "mssql contains and key existence use json functions" do
    contains =
      Json.build_contains("attributes", %{"color" => "red", "dimensions" => %{"length" => 5}},
        adapter: SelectoDBMSSQL.Adapter,
        table_alias: "u"
      )

    assert IO.iodata_to_binary(contains) =~ "JSON_VALUE([u].[attributes], '$.color') = 'red'"

    assert IO.iodata_to_binary(contains) =~
             "JSON_VALUE([u].[attributes], '$.dimensions.length') = '5'"

    exists =
      Json.build_key_exists("attributes", ["dimensions", "length"],
        adapter: SelectoDBMSSQL.Adapter,
        table_alias: "u"
      )

    assert exists =~ "JSON_QUERY([u].[attributes], '$.dimensions.length') IS NOT NULL"
    assert exists =~ "JSON_VALUE([u].[attributes], '$.dimensions.length') IS NOT NULL"
  end

  test "mssql containment rejects array semantics explicitly" do
    assert_raise RuntimeError, ~r/MSSQL JSON containment for arrays is not supported/, fn ->
      Json.build_contains("attributes", %{"tags" => ["featured"]},
        adapter: SelectoDBMSSQL.Adapter,
        table_alias: "u"
      )
    end
  end

  test "mysql contains and key existence use mysql json functions" do
    contains =
      Json.build_contains("attributes", %{"color" => "red"},
        adapter: SelectoDBMySQL.Adapter,
        table_alias: "u"
      )

    assert contains == "JSON_CONTAINS(`u`.`attributes`, '{\"color\":\"red\"}')"

    exists =
      Json.build_key_exists("attributes", ["dimensions", "length"],
        adapter: SelectoDBMySQL.Adapter,
        table_alias: "u"
      )

    assert exists == "JSON_CONTAINS_PATH(`u`.`attributes`, 'one', '$.dimensions.length')"
  end

  test "sqlite key existence and array helpers use sqlite json functions" do
    exists =
      Json.build_key_exists("attributes", ["dimensions", "length"],
        adapter: SelectoDBSQLite.Adapter,
        table_alias: "u"
      )

    one =
      Json.build_array_contains("attributes", ["tags"], "featured",
        adapter: SelectoDBSQLite.Adapter,
        table_alias: "u"
      )

    all =
      Json.build_array_contains_all("attributes", ["tags"], ["featured", "new"],
        adapter: SelectoDBSQLite.Adapter,
        table_alias: "u"
      )

    assert exists == ~s|json_type("u"."attributes", '$.dimensions.length') IS NOT NULL|

    assert IO.iodata_to_binary(one) =~
             ~s|EXISTS (SELECT 1 FROM json_each("u"."attributes", '$.tags') WHERE value = 'featured')|

    assert IO.iodata_to_binary(all) =~ ~s|json_each("u"."attributes", '$.tags')|
    assert IO.iodata_to_binary(all) =~ "WHERE value = 'new'"
  end

  test "sqlite json containment rejects unsupported current abstraction" do
    contains =
      Json.build_contains("attributes", %{"color" => "red", "dimensions" => %{"length" => 5}},
        adapter: SelectoDBSQLite.Adapter,
        table_alias: "u"
      )

    assert IO.iodata_to_binary(contains) =~ ~s|json_extract("u"."attributes", '$.color') = 'red'|

    assert IO.iodata_to_binary(contains) =~
             ~s|json_extract("u"."attributes", '$.dimensions.length') = 5|

    assert_raise RuntimeError,
                 ~r/SQLite JSON containment for arrays is not supported/,
                 fn ->
                   Json.build_contains("attributes", %{"tags" => ["featured"]},
                     adapter: SelectoDBSQLite.Adapter,
                     table_alias: "u"
                   )
                 end
  end

  test "mssql json array helpers use openjson" do
    one =
      Json.build_array_contains("attributes", ["tags"], "featured",
        adapter: SelectoDBMSSQL.Adapter,
        table_alias: "u"
      )

    all =
      Json.build_array_contains_all("attributes", ["tags"], ["featured", "new"],
        adapter: SelectoDBMSSQL.Adapter,
        table_alias: "u"
      )

    assert IO.iodata_to_binary(one) =~ "OPENJSON([u].[attributes], '$.tags')"
    assert IO.iodata_to_binary(one) =~ "WHERE value = 'featured'"
    assert IO.iodata_to_binary(all) =~ "OPENJSON([u].[attributes], '$.tags')"
    assert IO.iodata_to_binary(all) =~ "WHERE value = 'featured'"
    assert IO.iodata_to_binary(all) =~ "WHERE value = 'new'"
  end

  test "mysql json array helpers use json_contains" do
    one =
      Json.build_array_contains("attributes", ["tags"], "featured",
        adapter: SelectoDBMySQL.Adapter,
        table_alias: "u"
      )

    all =
      Json.build_array_contains_all("attributes", ["tags"], ["featured", "new"],
        adapter: SelectoDBMySQL.Adapter,
        table_alias: "u"
      )

    assert IO.iodata_to_binary(one) ==
             "JSON_CONTAINS(`u`.`attributes`, '\"featured\"', '$.tags')"

    assert IO.iodata_to_binary(all) =~
             "JSON_CONTAINS(`u`.`attributes`, '\"featured\"', '$.tags')"

    assert IO.iodata_to_binary(all) =~
             "JSON_CONTAINS(`u`.`attributes`, '\"new\"', '$.tags')"
  end

  test "array contains helpers" do
    one =
      Json.build_array_contains("attributes", ["tags"], "featured",
        adapter: SelectoDBPostgreSQL.Adapter
      )

    many =
      Json.build_array_contains("attributes", ["tags"], ["featured", "new"],
        adapter: SelectoDBPostgreSQL.Adapter
      )

    all =
      Json.build_array_contains_all("attributes", ["tags"], ["featured", "new"],
        adapter: SelectoDBPostgreSQL.Adapter
      )

    assert String.contains?(one, " ? 'featured'")
    assert String.contains?(many, "?| array['featured','new']")
    assert String.contains?(all, "?& array['featured','new']")
  end

  test "cast mapping and JSON column detection" do
    assert nil == Json.cast_for_type(:string)
    assert :integer == Json.cast_for_type(:integer)
    assert :decimal == Json.cast_for_type(:decimal)
    assert :float == Json.cast_for_type(:float)
    assert :boolean == Json.cast_for_type(:boolean)
    assert :date == Json.cast_for_type(:date)
    assert :datetime == Json.cast_for_type(:naive_datetime)
    assert :utc_datetime == Json.cast_for_type(:utc_datetime)
    assert nil == Json.cast_for_type(:unknown)

    assert Json.json_column?(domain(), "attributes")
    refute Json.json_column?(domain(), "name")
    refute Json.json_column?(domain(), "missing")
  end
end
