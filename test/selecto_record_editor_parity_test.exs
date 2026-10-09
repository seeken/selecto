defmodule Selecto.RecordEditorParityTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  @fixture Path.join(__DIR__, "fixtures/record_editor_pure_v1.json")
           |> File.read!()
           |> Jason.decode!()

  test "canonical public projections expand shorthand and publish editor defaults" do
    authored = @fixture["domain"]
    assert {:ok, normalized, _} = Domain.validate(authored)
    assert normalized.authored_domain == authored

    ui = normalized |> Domain.project(:ui) |> json()
    api = normalized |> Domain.project(:api) |> json()
    assert ui["editors"] == api["editors"]

    assert ui["editors"]["order_profile"]["fields"] == [
             %{
               "field" => "status",
               "control" => "select",
               "required" => true,
               "options" => [%{"value" => "approved", "label" => "Approved"}]
             },
             %{"field" => "total"}
           ]

    assert ui["editors"]["order_profile"]["actions"] == ["approve"]
    action = ui["detail_actions"]["open_order"]
    assert action["required_fields"] == ["id"]

    assert action["payload"] == %{
             "editor" => "order_profile",
             "target_field" => "id",
             "title" => "Edit order",
             "size" => "lg",
             "navigation_enabled" => true
           }

    assert {:ok, again, _} = Domain.validate(normalized.domain)
    assert Domain.project(again, :ui) == Domain.project(normalized, :ui)
  end

  for probe <- @fixture["rejection_probes"] do
    @probe probe
    test "rejects shared malformed editor variant #{probe["id"]}" do
      authored =
        put_in(@fixture["domain"], Enum.map(@probe["path"], &Access.key/1), @probe["value"])

      assert {:error, diagnostics} = Domain.validate(authored)
      assert diagnostics.errors != []
    end
  end

  test "title interpolation requires published required fields and balanced placeholders" do
    path = ["detail_actions", "open_order", "payload", "title"]

    for title <- ["Order {{ id }}", "Order {{id}} {{id}}"] do
      assert {:ok, _, _} = Domain.validate(put_in(@fixture["domain"], path, title))
    end

    for title <- ["Order {{status}}", "Order {id}", "Order {{id}", "Order {{{id}}}", "", false] do
      assert {:error, diagnostics} = Domain.validate(put_in(@fixture["domain"], path, title))
      assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_record_editor_title))
    end
  end

  test "keeps explicit navigation false and rejects explicit null" do
    path = ["detail_actions", "open_order", "payload", "navigation_enabled"]
    assert {:ok, normalized, _} = Domain.validate(put_in(@fixture["domain"], path, false))

    assert json(Domain.project(normalized, :ui))["detail_actions"]["open_order"]["payload"][
             "navigation_enabled"
           ] == false

    assert {:error, diagnostics} = Domain.validate(put_in(@fixture["domain"], path, nil))
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_record_editor_navigation))
  end

  test "deduplicates atom and string identifiers without accepting malformed list entries" do
    authored =
      @fixture["domain"]
      |> put_in(["editors", "order_profile", "actions"], [:approve, "approve"])
      |> put_in(["detail_actions", "open_order", "required_fields"], [:id, "id"])

    assert {:ok, normalized, _} = Domain.validate(authored)
    ui = json(Domain.project(normalized, :ui))
    assert ui["editors"]["order_profile"]["actions"] == ["approve"]
    assert ui["detail_actions"]["open_order"]["required_fields"] == ["id"]

    assert {:error, _} =
             Domain.validate(put_in(authored, ["editors", "order_profile", "actions"], [42]))
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
