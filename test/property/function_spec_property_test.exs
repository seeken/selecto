defmodule Selecto.FunctionSpecPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @exact_cases [
    {:integer, 1},
    {:decimal, 1.5},
    {:boolean, true},
    {:string, "value"}
  ]

  @mismatch_cases [
    {:integer, :string},
    {:integer, :boolean},
    {:string, :integer},
    {:string, :boolean},
    {:boolean, :integer},
    {:boolean, :string}
  ]

  property "exact registered value types resolve deterministically" do
    check all({type, value} <- member_of(@exact_cases), max_runs: 60) do
      selecto = selecto_for(type, :value)

      assert {:ok, first} = Selecto.FunctionSpec.resolve(selecto, "typed", [value], :select)
      assert {:ok, second} = Selecto.FunctionSpec.resolve(selecto, "typed", [value], :select)
      assert first == second
      assert first.returns == type
    end
  end

  property "known incompatible registered types always fail with stable evidence" do
    check all({expected, actual} <- member_of(@mismatch_cases), max_runs: 60) do
      selecto = selecto_for(expected, :selector)
      field = field_for(actual)

      assert {:error, first} = Selecto.FunctionSpec.resolve(selecto, "typed", [field], :select)
      assert {:error, second} = Selecto.FunctionSpec.resolve(selecto, "typed", [field], :select)
      assert first == second
      assert first.code == :argument_type_mismatch

      assert [%{arguments: [%{expected: ^expected, actual: ^actual}]}] =
               first.details.candidates
    end
  end

  defp selecto_for(expected_type, source) do
    %{
      name: "Function property domain",
      source: %{
        source_table: "items",
        primary_key: :integer_value,
        fields: [:integer_value, :decimal_value, :boolean_value, :string_value],
        redact_fields: [],
        columns: %{
          integer_value: %{type: :integer},
          decimal_value: %{type: :decimal},
          boolean_value: %{type: :boolean},
          string_value: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      functions: %{
        "typed" => %{
          kind: :scalar,
          sql_name: "public.typed",
          args: [%{name: :value, type: expected_type, source: source}],
          returns: expected_type,
          allowed_in: [:select]
        }
      }
    }
    |> Selecto.configure(:mock_connection)
  end

  defp field_for(type), do: "#{type}_value"
end
