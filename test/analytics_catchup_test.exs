defmodule Selecto.AnalyticsCatchupTest do
  use ExUnit.Case, async: true

  defp library do
    %{
      query_library: %{
        segments: %{open: %{filters: []}, closed: %{filters: []}},
        segment_picker_groups: %{
          state: %{
            label: "State",
            default: "open",
            default_views: ["aggregate"],
            choices: [%{segment: "open", label: "Open"}, %{segment: "closed", label: "Closed"}]
          }
        }
      }
    }
  end

  test "picker defaults are view-limited and explicit Off remains authoritative" do
    domain = library()
    resolve = &Selecto.QueryLibrary.resolve_segment_choices(domain, &1, &2, &3)
    assert resolve.([], %{}, :detail).segments == []
    assert resolve.([], %{}, :aggregate).segments == ["open"]
    assert resolve.([], %{state: ""}, :aggregate).choices == %{"state" => ""}
    assert resolve.(["closed"], %{}, :aggregate).segments == ["closed"]
    assert resolve.(["closed"], %{state: "open"}, :aggregate).segments == ["open"]

    for {segments, choices} <- [
          {["open", "closed"], %{}},
          {[], %{unknown: ""}},
          {[], %{state: nil}}
        ] do
      assert_raise Selecto.Builder.ScopeRefusal, fn -> resolve.(segments, choices, :aggregate) end
    end
  end

  test "picker validation refuses unknown defaults and overlapping group membership" do
    groups = library().query_library
    invalid = put_in(groups, [:segment_picker_groups, :state, :default], "missing")
    refute Selecto.QueryLibrary.structure_errors(invalid) == []

    duplicate =
      put_in(groups, [:segment_picker_groups, :second], groups.segment_picker_groups.state)

    refute Selecto.QueryLibrary.structure_errors(duplicate) == []
  end

  test "composite unit normalization is recursive and rejects unknown metadata" do
    unit = %{
      "kind" => "ratio",
      "numerator" => %{"kind" => "currency", "code" => "USD"},
      "denominator" => %{"kind" => "count"}
    }

    assert {:ok,
            %{
              kind: :ratio,
              numerator: %{kind: :currency, code: "USD"},
              denominator: %{kind: :count}
            }} = Selecto.Analytics.Unit.normalize_unit(unit)

    assert {:error, _} = Selecto.Analytics.Unit.normalize_unit(Map.put(unit, "unknown", true))
  end

  test "ratios require numeric public operands and cannot fan out owners" do
    domain = %{
      source: %{columns: %{cost: %{type: :decimal}, pieces: %{type: :integer}}, associations: %{}},
      ratio_measures: %{
        price: %{
          label: "Price",
          numerator: %{field: "cost", function: :sum},
          denominator: %{field: "pieces", function: :sum}
        }
      }
    }

    assert Selecto.RatioMeasures.errors(domain) == []

    for column <- [
          %{type: :string},
          %{type: :decimal, internal: true},
          %{type: :decimal, aggregatable: false}
        ] do
      refute domain
             |> put_in([:source, :columns, :cost], column)
             |> Selecto.RatioMeasures.errors() == []
    end

    invalid =
      domain
      |> put_in([:source, :associations, :lines], %{queryable: :lines, cardinality: :many})
      |> Map.put(:schemas, %{lines: %{columns: %{cost: %{type: :decimal}}}})
      |> put_in([:ratio_measures, :price, :numerator, :field], "lines.cost")

    refute Selecto.RatioMeasures.errors(invalid) == []
  end
end
