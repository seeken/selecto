defmodule SelectoUpdato.OperatorFilterPredicateTest do
  @moduledoc """
  Governed update and delete filters in Selecto's operator form compile to
  the matching portable predicate, as the read's filter does (they were bound
  as one literal and failed in the driver).
  """

  use ExUnit.Case, async: true

  alias Selecto.Write.Command
  alias SelectoUpdato.PortableCommand

  defp domain do
    %{
      name: "t",
      source: %{
        source_table: "t",
        primary_key: :id,
        fields: [:id, :d, :n, :day, :at],
        columns: %{
          id: %{type: :integer},
          d: %{type: :decimal},
          n: %{type: :integer},
          day: %{type: :date},
          at: %{type: :naive_datetime}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          update: %{enabled: true, expected_cardinality: :many},
          delete: %{enabled: true, expected_cardinality: :many}
        },
        fields: %{n: %{updatable: true}}
      }
    }
  end

  defp compile(filter, operation \\ :update) do
    builder = domain() |> SelectoUpdato.new() |> SelectoUpdato.filter(filter)

    operation =
      if operation == :update,
        do: SelectoUpdato.update(builder, %{n: 1}),
        else: SelectoUpdato.delete(builder)

    PortableCommand.compile(operation)
  end

  defp predicate(filter, operation \\ :update) do
    {:ok, %Command{predicate: predicate}, _context} = compile(filter, operation)
    predicate
  end

  test "operator-form filters refuse typed before any SQL; equality and nil compile as before" do
    d = Decimal.new("-0.0000004")

    for filter <- [
          {"id", {:>, 1}},
          {"id", {:gt, 1}},
          {"d", {:<=, d}},
          {"d", {"!=", d}},
          {"id", {:in, [1, 2]}},
          {"id", {:not_in, [1]}},
          {"id", {:between, 1, 3}},
          {"day", {:between, "2024-01-01", "2024-01-03"}},
          {"id", [1, 2]},
          {"id", :not_null}
        ],
        operation <- [:update, :delete] do
      assert {:error, %SelectoUpdato.Error{type: :unsupported_filter_operator}} =
               compile(filter, operation),
             inspect(filter)
    end

    # The three-element forms main accepted keep working; an atom operator
    # main did not accept still refuses as an invalid predicate.
    assert predicate({"id", :gt, 1}) == {:gt, {:field, "id"}, {:literal, 1}}

    assert predicate({"id", "in", [1, 2]}) ==
             {:in, {:field, "id"}, [{:literal, 1}, {:literal, 2}]}

    assert {:error, %SelectoUpdato.Error{type: :invalid_predicate}} = compile({"id", :>, 1})

    assert predicate({"id", 4}) == {:eq, {:field, "id"}, {:literal, 4}}
    assert predicate({"id", nil}) == {:is_null, {:field, "id"}}
  end

  test "a required or trusted BETWEEN on a date-like field is half-open, as the read" do
    # A trusted required filter (the execution scope's post-image check).
    operation =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{n: 1})

    operation = %{
      operation
      | opts:
          Keyword.put(operation.opts || [], :trusted_required_filters, [
            {"day", {:between, "2024-01-01", "2024-01-03"}}
          ])
    }

    assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(operation)
    assert inspect(metadata) =~ ~s({:lt, {:field, "day"}, {:literal, "2024-01-03"}})
    refute inspect(metadata) =~ ~s({:lte, {:field, "day"})

    # A domain required filter, on a field whose date-like presentation comes
    # from the domain's top-level columns (as the read configures it).
    for {field, extra} <- [
          {"day", %{}},
          {"n", %{columns: %{n: %{presentation_type: :date, datetime_storage: :unix_seconds}}}}
        ] do
      required =
        domain()
        |> Map.merge(extra)
        |> Map.put(:required_filters, [{field, {:between, 1, 3}}])

      operation =
        required
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({"id", 1})
        |> SelectoUpdato.update(%{n: 1})

      assert {:ok, %Command{predicate: predicate}, _context} = PortableCommand.compile(operation)
      assert inspect(predicate) =~ ~s({:lt, {:field, "#{field}"}, {:literal, 3}}), field
    end

    required = Map.put(domain(), :required_filters, [{"id", {:between, 1, 3}}])

    operation =
      required
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{n: 1})

    assert {:ok, %Command{predicate: predicate}, _context} = PortableCommand.compile(operation)
    assert inspect(predicate) =~ ~s({:lte, {:field, "id"}, {:literal, 3}})
  end

  test "a reference or an unknown operator refuses typed" do
    for filter <- [{"id", {:ref, "n"}}, {"id", {:like, "x"}}] do
      operation =
        domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter(filter)
        |> SelectoUpdato.update(%{n: 1})

      assert {:error, %SelectoUpdato.Error{}} = PortableCommand.compile(operation)
    end
  end
end
