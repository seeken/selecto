defmodule Selecto.Verification.BoundedTraceModelTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.BoundedTraceModel

  defmodule ArtifactStruct do
    defstruct [:struct, :value]
  end

  test "explores deterministic breadth-first traces through the maximum depth" do
    report =
      BoundedTraceModel.check(
        "counter",
        [0],
        [
          {"increment", fn state -> {:next, state + 1, %{amount: 1}} end},
          {"decrement",
           fn
             0 -> :disabled
             state -> {:next, state - 1}
           end}
        ],
        [{"non_negative", fn state -> state >= 0 end}],
        max_depth: 2
      )

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 3
    assert report.invariant_count == 1
    assert report.check_count == 3
    assert report.event_count == 2
    assert report.transition_count == 3
    assert report.revisited_state_count == 1
    assert report.disabled_event_count == 1
    assert report.reached_depth == 2
    assert report.proved?
  end

  test "reduces equivalent states with a caller-supplied state key" do
    report =
      BoundedTraceModel.check(
        "parity",
        [%{value: 0}],
        [{:increment, fn state -> {:next, %{value: state.value + 1}} end}],
        [{:map_state, fn state -> is_map(state) end}],
        max_depth: 5,
        state_key: fn state -> rem(state.value, 2) end,
        include_trace_coverage: true
      )

    assert report.state_count == 2
    assert report.transition_count == 2
    assert report.revisited_state_count == 1
    assert report.reached_depth == 1
    assert report.trace_coverage == [[], ["increment"], ["increment", "increment"]]
    assert report.proved?
  end

  test "trace coverage includes successful transitions that revisit a state" do
    report =
      BoundedTraceModel.check(
        "revisited transition coverage",
        [0],
        [
          {:one, fn _state -> {:next, 1} end},
          {:also_one, fn _state -> {:next, 1} end}
        ],
        [],
        max_depth: 1,
        include_trace_coverage: true
      )

    assert report.state_count == 2
    assert report.transition_count == 2
    assert report.revisited_state_count == 1
    assert report.trace_coverage == [[], ["one"], ["also_one"]]
  end

  test "counterexamples contain deterministic JSON-portable event traces" do
    report =
      BoundedTraceModel.check(
        "trace counterexample",
        [%{count: 0}],
        [
          {:increment,
           fn state ->
             {:next, %{state | count: state.count + 1}, {:new_count, state.count + 1}}
           end}
        ],
        [{:below_two, fn state -> state.count < 2 end}],
        max_depth: 2
      )

    refute report.proved?

    assert [counterexample] = report.counterexamples
    assert counterexample.type == :invariant
    assert counterexample.invariant == "below_two"
    assert counterexample.depth == 2

    assert counterexample.trace == [
             %{
               event: "increment",
               event_index: 0,
               state: %{count: 1},
               data: %{tuple: [:new_count, 1]}
             },
             %{
               event: "increment",
               event_index: 0,
               state: %{count: 2},
               data: %{tuple: [:new_count, 2]}
             }
           ]

    assert {:ok, _json} = Jason.encode(report)
  end

  test "can store a compact trace snapshot without weakening checked state" do
    report =
      BoundedTraceModel.check(
        "compact trace",
        [%{large: String.duplicate("x", 100), value: 0}],
        [{:increment, fn state -> {:next, %{state | value: state.value + 1}} end}],
        [{:value_stays_zero, fn state -> state.value == 0 end}],
        max_depth: 1,
        trace_state: &Map.take(&1, [:value])
      )

    assert [%{state: %{large: large}, trace: [%{state: %{value: 1}}]}] =
             report.counterexamples

    assert byte_size(large) == 100
  end

  test "shared portable encoding preserves colliding map keys and struct fields in traces" do
    report =
      BoundedTraceModel.check(
        "portable collisions",
        [%{"x" => 2, x: 1}],
        [
          {:to_struct,
           fn _state ->
             {:next, %ArtifactStruct{struct: "field value", value: 7},
              %{"source" => "string", source: :event}}
           end}
        ],
        [{:always_fails, fn _state -> false end}],
        max_depth: 1
      )

    assert [initial, reached] = report.counterexamples

    assert initial.state == %{
             map_entries: [
               %{key: %{type: :atom, value: "x"}, value: 1},
               %{key: %{type: :string, value: "x"}, value: 2}
             ]
           }

    assert reached.state == %{
             struct_module: inspect(ArtifactStruct),
             fields: %{struct: "field value", value: 7}
           }

    assert [
             %{
               state: %{
                 struct_module: struct_module,
                 fields: %{struct: "field value", value: 7}
               },
               data: %{map_entries: data_entries}
             }
           ] = reached.trace

    assert struct_module == inspect(ArtifactStruct)

    assert data_entries == [
             %{key: %{type: :atom, value: "source"}, value: :event},
             %{key: %{type: :string, value: "source"}, value: "string"}
           ]

    assert {:ok, json} = Jason.encode(report)
    assert json =~ ~s("type":"atom")
    assert json =~ ~s("type":"string")
    assert json =~ ~s("struct":"field value")
    assert json =~ ~s("struct_module":"#{inspect(ArtifactStruct)}")
  end

  test "portable trace encoding preserves improper lists and non-UTF-8 binaries" do
    invalid_binary = <<0xFF, 0x00, 0xFE>>
    encoded_binary = %{binary_base64: Base.encode64(invalid_binary)}
    improper_list = [:head, invalid_binary | {:tail, invalid_binary}]
    valid_string = "snowman ☃"
    proper_list = [:proper, valid_string]

    encoded_improper_list = %{
      improper_list: %{
        head: [:head, encoded_binary],
        tail: %{tuple: [:tail, encoded_binary]}
      }
    }

    report =
      BoundedTraceModel.check(
        "portable non-JSON terms",
        [improper_list],
        [
          {:to_binary,
           fn _state ->
             {:next, invalid_binary,
              %{
                invalid_binary => improper_list,
                proper_list: proper_list,
                valid_string: valid_string
              }}
           end}
        ],
        [{:always_fails, fn _state -> false end}],
        max_depth: 1
      )

    assert [initial, reached] = report.counterexamples
    assert initial.state == encoded_improper_list
    assert reached.state == encoded_binary

    assert [
             %{
               state: ^encoded_binary,
               data: %{map_entries: data_entries}
             }
           ] = reached.trace

    assert Enum.any?(data_entries, fn entry ->
             entry == %{
               key: %{type: :term, value: encoded_binary},
               value: encoded_improper_list
             }
           end)

    assert Enum.any?(data_entries, fn entry ->
             entry == %{
               key: %{type: :atom, value: "proper_list"},
               value: proper_list
             }
           end)

    assert Enum.any?(data_entries, fn entry ->
             entry == %{
               key: %{type: :atom, value: "valid_string"},
               value: valid_string
             }
           end)

    json = Jason.encode!(report)
    assert json =~ ~s("binary_base64":"#{Base.encode64(invalid_binary)}")
    assert json =~ ~s("improper_list")
  end

  test "captures event errors, invalid results, exceptions, and throws" do
    events = [
      {:reported_error, fn _state -> {:error, :blocked} end},
      {:invalid_result, fn _state -> :unexpected end},
      {:exception, fn _state -> raise "boom" end},
      {:throw, fn _state -> throw(:boom) end}
    ]

    report =
      BoundedTraceModel.check("bad events", [:initial], events, [], max_depth: 1)

    refute report.proved?
    assert report.check_count == 0

    assert Enum.map(report.counterexamples, & &1.event) ==
             Enum.map(events, &to_string(elem(&1, 0)))

    assert Enum.all?(report.counterexamples, &(&1.type == :transition))
    assert Enum.all?(report.counterexamples, &(length(&1.trace) == 1))
    assert {:ok, _json} = Jason.encode(report)
  end

  test "checks unique initial states even when maximum depth is zero" do
    report =
      BoundedTraceModel.check(
        "initial states",
        [:ok, :ok, :bad],
        [{:unused, fn _state -> {:next, :unreachable} end}],
        [{:is_ok, fn state -> state == :ok end}],
        max_depth: 0
      )

    assert report.state_count == 2
    assert report.initial_state_count == 2
    assert report.revisited_state_count == 1
    assert report.transition_count == 0
    assert report.reached_depth == 0
    refute report.proved?
    assert [%{state: :bad, trace: []}] = report.counterexamples
  end

  test "validates bounded trace model configuration" do
    assert_raise ArgumentError, ~r/missing required :max_depth/, fn ->
      BoundedTraceModel.check("missing", [0], [], [], [])
    end

    assert_raise ArgumentError, ~r/non-negative integer/, fn ->
      BoundedTraceModel.check("negative", [0], [], [], max_depth: -1)
    end

    assert_raise ArgumentError, ~r/events must be/, fn ->
      BoundedTraceModel.check("events", [0], [:bad], [], max_depth: 0)
    end

    assert_raise ArgumentError, ~r/state_key/, fn ->
      BoundedTraceModel.check("key", [0], [], [], max_depth: 0, state_key: :bad)
    end

    assert_raise ArgumentError, ~r/trace_state/, fn ->
      BoundedTraceModel.check("trace", [0], [], [], max_depth: 0, trace_state: :bad)
    end

    assert_raise ArgumentError, ~r/include_trace_coverage/, fn ->
      BoundedTraceModel.check("coverage", [0], [], [],
        max_depth: 0,
        include_trace_coverage: :bad
      )
    end
  end
end
