defmodule Selecto.Verification.BoundedModelTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.BoundedModel

  defmodule ArtifactStruct do
    defstruct [:struct, :value]
  end

  test "proves every invariant across the complete supplied model" do
    report =
      BoundedModel.check("booleans", [false, true], [
        {"is_boolean", fn state -> is_boolean(state) end},
        {"double_negation", fn state -> not not state == state end}
      ])

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 2
    assert report.invariant_count == 2
    assert report.check_count == 4
    assert report.proved?
    assert report.counterexamples == []
  end

  test "returns deterministic, reproducible counterexamples" do
    report =
      BoundedModel.check("small integers", 0..2, [
        {"less_than_two", fn state -> state < 2 end}
      ])

    refute report.proved?

    assert report.counterexamples == [
             %{
               invariant: "less_than_two",
               invariant_index: 0,
               state_index: 2,
               state: 2,
               reason: :returned_false
             }
           ]
  end

  test "captures invariant exceptions instead of aborting the proof run" do
    report =
      BoundedModel.check("exceptions", [:bad], [
        {"safe", fn _ -> raise "boom" end}
      ])

    assert [
             %{
               reason: %{tuple: [:exception, RuntimeError, "boom"]}
             }
           ] = report.counterexamples
  end

  test "counterexamples remain JSON serializable for artifact output" do
    report =
      BoundedModel.check("portable", [%{tuple: {:tenant_id, 7}, callback: fn -> :ok end}], [
        {"fails", fn _ -> false end}
      ])

    assert {:ok, _json} = Jason.encode(report)
  end

  test "shared portable encoding preserves colliding map keys and struct fields" do
    report =
      BoundedModel.check(
        "portable collisions",
        [%{"x" => 2, x: 1}, %ArtifactStruct{struct: "field value", value: 7}],
        [{"fails", fn _state -> false end}]
      )

    assert [map_counterexample, struct_counterexample] = report.counterexamples

    assert map_counterexample.state == %{
             map_entries: [
               %{key: %{type: :atom, value: "x"}, value: 1},
               %{key: %{type: :string, value: "x"}, value: 2}
             ]
           }

    assert struct_counterexample.state == %{
             struct_module: inspect(ArtifactStruct),
             fields: %{struct: "field value", value: 7}
           }

    assert {:ok, json} = Jason.encode(report)
    assert json =~ ~s("struct":"field value")
    assert json =~ ~s("struct_module":"#{inspect(ArtifactStruct)}")
  end

  test "portable encoding preserves improper lists and non-UTF-8 binaries" do
    invalid_binary = <<0xFF, 0x00, 0xFE>>
    encoded_binary = %{binary_base64: Base.encode64(invalid_binary)}
    improper_list = [:head, invalid_binary | {:tail, invalid_binary}]
    valid_string = "snowman ☃"
    proper_list = [:proper, valid_string]

    report =
      BoundedModel.check(
        "portable non-JSON terms",
        [improper_list, invalid_binary, proper_list, valid_string],
        [{"fails", fn _state -> false end}]
      )

    assert [
             improper_counterexample,
             binary_counterexample,
             proper_list_counterexample,
             valid_string_counterexample
           ] = report.counterexamples

    assert improper_counterexample.state == %{
             improper_list: %{
               head: [:head, encoded_binary],
               tail: %{tuple: [:tail, encoded_binary]}
             }
           }

    assert binary_counterexample.state == encoded_binary
    assert proper_list_counterexample.state == proper_list
    assert valid_string_counterexample.state == valid_string

    json = Jason.encode!(report)
    assert json =~ ~s("binary_base64":"#{Base.encode64(invalid_binary)}")
    assert json =~ ~s("improper_list")
  end
end
