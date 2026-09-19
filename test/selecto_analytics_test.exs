defmodule Selecto.AnalyticsTest do
  use ExUnit.Case, async: true

  alias Selecto.Analytics.{Pipeline, TransformRegistry, Unit}
  alias Selecto.Domain

  test "normalizes quantitative metadata and projects it to consumers" do
    domain =
      domain(%{type: :decimal, unit: %{"kind" => "Currency", "code" => "usd"}, behavior: "FLOW"})

    assert {:ok, normalized, _} = Domain.validate(domain)
    assert normalized.source.columns.amount.unit == %{kind: :currency, code: "USD"}
    assert normalized.source.columns.amount.behavior == :flow
    assert {:ok, contract, _} = Domain.query_contract(normalized)

    assert %{unit: %{kind: :currency, code: "USD"}, behavior: :flow} =
             Enum.find(contract.fields, &(&1.id == "amount"))
  end

  test "rejects malformed and non-numeric quantitative annotations" do
    for column <- [
          %{type: :string, unit: %{kind: :count}},
          %{type: :decimal, unit: %{kind: :currency, code: "US1"}},
          %{type: :decimal, unit: %{kind: :mass, code: "kg", scale: :whole}},
          %{type: :decimal, behavior: :unknown},
          %{type: :decimal, unit: nil}
        ] do
      assert {:error, diagnostics} = Domain.validate(domain(column))
      assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_quantitative_column))
    end
  end

  test "aggregate units and transform eligibility follow semantics" do
    currency = %{kind: :currency, code: "USD"}
    assert {:ok, %{kind: :count}} = Unit.aggregate_unit(currency, :count)
    assert {:ok, ^currency} = Unit.aggregate_unit(currency, :sum)
    refute Unit.compatible?(currency, %{kind: :currency, code: "EUR"})
    assert TransformRegistry.allows?(:cumulative, currency, :flow)
    refute TransformRegistry.allows?(:cumulative, currency, :stock)

    assert {:ok, %{kind: :percentage, scale: :whole}} =
             TransformRegistry.result_unit(:percent_change, currency, :flow)

    refute TransformRegistry.allows?(:percentage_point_change, currency, :flow)
  end

  test "pipeline computes ordered, chained transforms with provenance" do
    unit = %{kind: :count}

    assert {:ok, result} =
             Pipeline.apply(
               [10, nil, 30, 60],
               [%{type: :moving_average, parameters: %{window: 2}}, :percent_change],
               unit,
               :flow
             )

    assert Enum.map(result.points, & &1.value) == [nil, nil, nil, 50.0]
    assert Enum.map(result.points, & &1.raw_value) == [10.0, nil, 30.0, 60.0]
    assert result.unit == %{kind: :percentage, scale: :whole}
    assert length(result.transforms) == 2
    assert Enum.all?(result.points, &(length(&1.derivation) == 2))
  end

  test "pipeline preserves null semantics and rejects invalid parameters" do
    assert {:ok, %{unit: nil, points: [%{value: 2}]}} = Pipeline.apply([2], [], nil, nil)

    assert {:ok, %{points: points}} =
             Pipeline.apply([1, nil, 2], [:cumulative], %{kind: :count}, :flow)

    assert Enum.map(points, & &1.value) == [1.0, nil, 3.0]
    assert {:error, _} = Pipeline.apply([1, 2], [:cumulative], %{kind: :count}, :stock)

    assert {:error, _} =
             Pipeline.apply(
               [1, 2],
               [%{type: :moving_average, parameters: %{window: 1}}],
               %{kind: :count},
               nil
             )

    assert {:error, _} =
             Pipeline.apply(
               [1, 2],
               [%{type: :exponential_moving_average, parameters: %{alpha: 0}}],
               %{kind: :count},
               nil
             )

    assert {:error, _} = Pipeline.apply([1, "oops"], [], %{kind: :count}, nil)

    assert {:error, _} =
             Pipeline.apply([1], List.duplicate(:percent_of_total, 9), %{kind: :count}, nil)
  end

  test "pipeline accepts numeric strings with a leading or trailing decimal point" do
    assert {:ok, %{points: points}} =
             Pipeline.apply([".5", "1.", "-.5"], [:cumulative], %{kind: :count}, :flow)

    assert Enum.map(points, & &1.value) == [0.5, 1.5, 1.0]
    assert {:error, _} = Pipeline.apply(["1e3"], [], %{kind: :count}, :flow)
  end

  test "pipeline preserves raw integers beyond the exact float range" do
    values = [9_007_199_254_740_993, nil, -9_007_199_254_740_993]
    assert {:ok, %{points: points}} = Pipeline.apply(values, [], %{kind: :count}, nil)
    assert Enum.map(points, & &1.raw_value) === values
    assert Enum.map(points, & &1.value) === values
  end

  test "portable transform math matches Perl boundary cases" do
    count = %{kind: :count}
    flow = :flow
    values = [2, 4, 6]

    for {transform, expected} <- [
          {:percent_of_total, [16.666666666666664, 33.33333333333333, 50.0]},
          {:percent_change, [nil, 100.0, 50.0]},
          {:index_to_first, [100.0, 200.0, 300.0]},
          {:cumulative, [2.0, 6.0, 12.0]},
          {%{type: :moving_average, parameters: %{window: 2}}, [2.0, 3.0, 5.0]},
          {%{type: :exponential_moving_average, parameters: %{alpha: 0.5}}, [2.0, 3.0, 4.5]},
          {:min_max, [0.0, 50.0, 100.0]}
        ] do
      assert {:ok, result} = Pipeline.apply(values, [transform], count, flow)

      assert Enum.zip_with(result.points, expected, fn point, expected ->
               if is_nil(expected),
                 do: is_nil(point.value),
                 else: abs(point.value - expected) < 1.0e-10
             end)
             |> Enum.all?()
    end

    assert {:ok, %{points: [%{value: nil}, %{value: 0.25}]}} =
             Pipeline.apply(
               [0.25, 0.5],
               [:percentage_point_change],
               %{kind: :percentage, scale: :fraction},
               nil
             )
  end

  defp domain(column) do
    %{
      name: "Quantitative",
      source: %{
        source_table: "measurements",
        primary_key: :id,
        fields: [:id, :amount],
        columns: %{id: %{type: :integer}, amount: column},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
