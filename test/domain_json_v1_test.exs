defmodule Selecto.DomainJsonV1Test do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  defp relation(table) do
    %{
      "source_table" => table,
      "primary_key" => "id",
      "fields" => ["id", "maker_id", "label"],
      "columns" => %{
        "id" => %{"type" => "integer"},
        "maker_id" => %{"type" => "integer"},
        "label" => %{"type" => "string"}
      },
      "associations" => %{}
    }
  end

  defp base do
    %{
      "schema_version" => 1,
      "name" => "Json v1",
      "source" =>
        put_in(relation("items"), ["associations"], %{
          "maker" => %{"queryable" => "makers", "owner_key" => "maker_id", "related_key" => "id"}
        }),
      "schemas" => %{
        "makers" =>
          put_in(relation("makers"), ["associations"], %{
            "parent" => %{
              "queryable" => "makers",
              "owner_key" => "maker_id",
              "related_key" => "id"
            }
          })
      },
      "joins" => %{
        "maker" => %{"type" => "left", "name" => "Maker", "joins" => %{"parent" => %{}}}
      }
    }
  end

  defp refusals(domain) do
    case Domain.validate_json(domain) do
      {:ok, _normalized, _diagnostics} ->
        []

      {:error, diagnostics} ->
        for %{code: :invalid_domain} = error <- diagnostics.errors,
            do: {error.reason, error.path}
    end
  end

  test "contract_keys returns the seven shared tables" do
    keys = Domain.contract_keys()

    assert Map.keys(keys) |> Enum.sort() ==
             [:association, :join, :join_types, :relation, :source, :through, :top_level]

    assert keys.source == Enum.sort(["fts5_index" | keys.relation])
    assert "alias" in keys.join
    assert keys.join_types == ~w(left inner star_dimension right full)

    for table <- [:top_level, :source, :relation, :association, :join, :through],
        do: assert(keys[table] == Enum.sort(keys[table]))

    assert keys.top_level ==
             Selecto.Domain.Sections.sections() |> Map.values() |> List.flatten() |> Enum.sort()
  end

  test "the JSON v1 parser admits exactly the tables" do
    assert refusals(base()) == []

    admitted =
      base()
      |> put_in(["joins", "maker", "alias"], "m")
      |> put_in(["source", "associations", "maker", "join_strategy"], "lateral_lookup")
      |> Map.put("domain_data", %{"anything" => [1, "two"]})
      |> Map.put("jsonb_schemas", %{})
      |> put_in(["schemas", "makers", "source_kind"], "view")
      |> put_in(["schemas", "makers", "readonly"], true)

    assert refusals(admitted) == []

    for type <- ["left", "INNER", "star_dimension", "right", "full"] do
      assert refusals(put_in(base(), ["joins", "maker", "type"], type)) == [], type
    end
  end

  test "an unknown key at any level refuses with invalid_domain" do
    for {path, key} <- [
          {[], "invented"},
          {["source"], "source_schema"},
          {["source"], "hidden_fields"},
          {["schemas", "makers"], "source_schema"},
          {["source", "associations", "maker"], "join_through"},
          {["source", "associations", "maker"], "write"},
          {["schemas", "makers", "associations", "parent"], "join_keys"},
          {["joins", "maker"], "filters"},
          {["joins", "maker", "joins", "parent"], "tag_field"}
        ] do
      domain =
        if path == [],
          do: Map.put(base(), key, %{}),
          else: update_in(base(), path, &Map.put(&1, key, %{}))

      assert [{:unknown_domain_key, _path}] = refusals(domain), "#{inspect(path)} #{key}"
    end

    assert [{:unknown_domain_key, [:source, :associations, "maker", :through]}] =
             base()
             |> put_in(["source", "associations", "maker", "through"], %{
               "table" => "links",
               "owner_key" => "item_id",
               "related_key" => "maker_id",
               "join_table" => "links"
             })
             |> refusals()
             |> Enum.filter(&match?({:unknown_domain_key, _}, &1))
  end

  test "a through list and an unknown join type refuse instead of falling back" do
    assert {:invalid_through, [:source, :associations, "maker", :through]} in refusals(
             put_in(base(), ["source", "associations", "maker", "through"], ["links", "maker"])
           )

    for type <- ["dimension", "lateral_join", "cross", "outer", 7] do
      assert [{:unsupported_join_type, [:joins, "maker", :type]}] =
               refusals(put_in(base(), ["joins", "maker", "type"], type))
    end

    # validate/1 (native authoring) still admits Selecto's join families.
    assert {:ok, _, _} = Domain.validate(put_in(base(), ["joins", "maker", "type"], "dimension"))
  end

  test "fts5_index on a schemas relation refuses in validate/1 and validate_json/1" do
    domain =
      put_in(base(), ["schemas", "makers", "fts5_index"], %{"table" => "fts", "key" => "id"})

    for validate <- [&Domain.validate/1, &Domain.validate_json/1] do
      assert {:error, diagnostics} = validate.(domain)

      assert Enum.any?(
               diagnostics.errors,
               &match?(%{code: :invalid_domain, reason: :fts5_index_not_root}, &1)
             )
    end

    # Even when no association names the relation.
    unreachable =
      put_in(base(), ["schemas", "orphan"], Map.put(relation("orphan"), "fts5_index", %{}))

    assert {:error, _} = Domain.validate(unreachable)
  end

  test "metadata keys keep their semantics on the JSON v1 path" do
    assert [] != elem(Domain.validate_json(put_in(base(), ["source", "readonly"], 1)), 1).errors
    assert {:error, _} = Domain.validate_json(put_in(base(), ["source", "source_kind"], "tbl"))
    assert {:error, _} = Domain.validate_json(Map.put(base(), "events", %{"e" => 1}))
  end

  test "an association join's type: :inner renders INNER JOIN" do
    domain = fn type ->
      %{
        schema_version: 1,
        name: "Orders",
        source: %{
          source_table: "orders",
          primary_key: :id,
          fields: [:id, :person_id],
          redact_fields: [],
          columns: %{id: %{type: :integer}, person_id: %{type: :integer}},
          associations: %{person: %{queryable: :person, owner_key: :person_id, related_key: :id}}
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
        joins: %{person: %{type: type, name: "Person"}}
      }
    end

    sql = fn type ->
      {sql, _aliases, _params} =
        type
        |> domain.()
        |> Selecto.configure(:compile_only)
        |> Selecto.select(["id", "person.name"])
        |> Selecto.gen_sql([])

      String.downcase(sql)
    end

    assert sql.(:inner) =~ "inner join people"
    assert sql.("inner") =~ "inner join people"
    assert sql.(:left) =~ "left join people"
  end
end
