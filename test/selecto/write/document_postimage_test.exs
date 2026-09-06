defmodule Selecto.Write.DocumentPostimageTest do
  use ExUnit.Case, async: true

  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Write.DocumentPostimage

  defp field(id, type \\ "string", opts \\ []) do
    %{
      "id" => id,
      "type" => type,
      "nullable" => Keyword.get(opts, :nullable, false),
      "missing" => Keyword.get(opts, :missing, "preserve")
    }
  end

  defp present(id, value), do: %{"field" => id, "present" => true, "value" => value}
  defp absent(id), do: %{"field" => id, "present" => false}

  test "ordered receipt cells preserve null and missing through a JSON roundtrip" do
    projection = [field("title"), field("due_at", "string", nullable: true), field("timezone")]
    cells = [present("title", "Updated"), present("due_at", nil), absent("timezone")]
    assert :ok = DocumentPostimage.validate(cells, projection)
    cells = cells |> Jason.encode!() |> Jason.decode!()

    assert {:ok, [%{"title" => "Updated", "due_at" => nil, "timezone" => %Missing{}}]} =
             DocumentPostimage.decode(cells, projection)

    assert {:error, _} = DocumentPostimage.validate(Enum.reverse(cells), projection)
    assert {:error, _} = DocumentPostimage.validate(tl(cells), projection)

    assert {:error, _} =
             DocumentPostimage.validate(cells, List.replace_at(projection, 1, field("due_at")))

    assert {:error, _} =
             DocumentPostimage.validate(
               cells,
               List.replace_at(projection, 2, field("timezone", "string", missing: "reject"))
             )
  end

  test "every portable scalar retains its declared value family" do
    cases = [
      {"string", "é\n\"\\"},
      {"integer", 9_007_199_254_740_991},
      {"integer", -9_007_199_254_740_991},
      {"boolean", false},
      {"boolean", true},
      {"object_id", Fixtures.object_id(1)}
    ]

    for {type, value} <- cases do
      cells = [present("value", value)]
      assert :ok = DocumentPostimage.validate(cells, [field("value", type)])

      assert {:ok, [%{"value" => ^value}]} =
               DocumentPostimage.decode(cells, [field("value", type)])

      for other <- ~w(string integer boolean object_id), other != type do
        assert {:error, _} = DocumentPostimage.validate(cells, [field("value", other)])
      end
    end

    for type <- ~w(string integer boolean object_id) do
      assert :ok =
               DocumentPostimage.validate([present("value", nil)], [
                 field("value", type, nullable: true)
               ])

      assert {:error, _} =
               DocumentPostimage.validate([present("value", nil)], [field("value", type)])
    end
  end

  test "cell and projection syntax is exact, bounded, plain data and fails without disclosing values" do
    valid = present("title", "secret-do-not-echo")
    projection = [field("title")]

    for cells <- [
          [],
          nil,
          %{},
          [nil],
          [1 | :invalid],
          [valid, valid],
          [Map.put(valid, "extra", true)],
          [Map.put(valid, "present", 1)],
          [Map.delete(valid, "value")],
          [Map.put(valid, "present", false)],
          [Map.put(valid, "field", "$title")],
          [Map.put(valid, "field", :title)],
          [%{field: "title", present: true, value: "secret-do-not-echo"}],
          [%{"field" => "title", "present" => false, __struct__: Date}],
          Enum.map(1..17, &absent("field#{&1}"))
        ] do
      assert {:error, error} = DocumentPostimage.validate(cells, projection)
      assert {:error, _} = DocumentPostimage.decode(cells, projection)
      assert {:error, _} = DocumentPostimage.budget(cells)
      refute inspect(error) =~ "secret-do-not-echo"
    end

    [definition] = projection

    for invalid <- [
          [],
          nil,
          %{},
          [nil],
          [1 | :invalid],
          [definition, definition],
          [Map.put(definition, "extra", true)],
          [Map.delete(definition, "missing")],
          [Map.put(definition, "nullable", 1)],
          [Map.put(definition, "missing", "null")],
          [Map.put(definition, "type", "float")],
          [Map.put(definition, "type", "binary")],
          [Map.put(definition, "id", "$title")],
          [%{id: "title", type: "string", nullable: false, missing: "preserve"}],
          [Map.put(definition, :__struct__, Date)],
          Enum.map(1..17, &field("field#{&1}"))
        ] do
      assert {:error, _} = DocumentPostimage.validate([valid], invalid)
    end

    sixteen = Enum.map(1..16, &absent("field#{&1}"))
    assert :ok = DocumentPostimage.validate(sixteen, Enum.map(1..16, &field("field#{&1}")))
  end

  test "budget covers JSON escaping and enforces its exact bound before decode" do
    projection = [field("a"), field("b", "boolean"), field("c", "integer")]
    # Three cells allow the conservative formula to reach exactly 16,384.
    value = String.duplicate(<<0>>, 2589)
    cells = [present("a", value), present("b", true), present("c", 1)]
    assert {:ok, 16_384} = DocumentPostimage.budget(cells)
    assert byte_size(Jason.encode!(cells)) <= 16_384
    assert :ok = DocumentPostimage.validate(cells, projection)

    too_large = [present("a", value <> "x"), present("b", true), present("c", 1)]
    assert {:ok, 16_390} = DocumentPostimage.budget(too_large)
    assert {:error, _} = DocumentPostimage.validate(too_large, projection)
    assert {:error, _} = DocumentPostimage.decode(too_large, projection)

    assert {:ok, 338} = DocumentPostimage.budget([present("a", "é")])

    for invalid <- [
          String.duplicate("x", 16_385),
          <<255>>,
          1.0,
          9_007_199_254_740_992,
          [],
          %{},
          %Missing{},
          Map.put(Fixtures.object_id(1), "extra", true)
        ] do
      assert {:error, _} = DocumentPostimage.budget([present("a", invalid)])
      assert {:error, _} = DocumentPostimage.validate([present("a", invalid)], [field("a")])
    end
  end

  test "patch fixtures preserve the prior ObjectId and owned-object shape refinements" do
    release = Fixtures.patch_release()
    assert :ok = ShapeRelease.validate(release, require_approved: true)
    assert ShapeRelease.features(release) == ["object_id", "object_relation"]

    assert {:ok, %{"type" => "boolean", "required" => false}} =
             ShapeRelease.field(release, "work_orders", "expedited")

    [first, second, third] = Fixtures.patch_documents()
    assert first["expedited"] == false and second["expedited"] == true
    refute Map.has_key?(third, "expedited")

    for document <- [first, second, third],
        do: assert(:ok = ShapeRelease.validate_document(release, document))

    refute Map.has_key?(Fixtures.object_id_shape()["shape"]["fields"], "expedited")
  end
end
