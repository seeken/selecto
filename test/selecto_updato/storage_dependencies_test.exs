defmodule SelectoUpdato.StorageDependenciesTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Error, RuleCandidateRequest}

  for stage <- [:candidate, :transaction, :evidence] do
    test "#{stage} advisory false conditions request all consumed fields before evaluation" do
      domain =
        domain(unquote(stage), %{
          op: "any",
          rules: [
            %{op: "value.eq", value: "new"},
            %{op: "path.test", path: [:id], test: %{op: "value.eq", value: nil}}
          ]
        })

      domain = put_in(domain, [:rules, :bindings, :check, :enforcement], :advisory)

      domain =
        put_in(domain, [:rules, :bindings, :check, :condition], %{
          op: "path.test",
          path: [:quantity],
          test: %{op: "value.eq", value: 0}
        })

      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{id: nil, name: "new", quantity: 2})

      provider = fn %RuleCandidateRequest{} = request ->
        send(self(), {:storage_request, request})

        {:error,
         Error.new(:validation, "unknown prospective value",
           details: %{code: :required_data_rule_pending}
         )}
      end

      assert {:error, %{details: %{code: :required_data_rule_pending}}} =
               SelectoUpdato.PortableCommand.compile(operation,
                 native_rule_candidate?: true,
                 rule_candidate_provider: provider,
                 context: %{selecto_rule_candidate_dependencies: []}
               )

      assert_received {:storage_request, request}
      assert request.context.selecto_rule_candidate_dependencies == ["id", "name", "quantity"]
    end
  end

  test "INPUT-only literals do not request a stored candidate" do
    operation =
      domain(:input, %{op: "value.eq", value: "new"})
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{id: nil, name: "new"})

    assert {:ok, _, _} =
             SelectoUpdato.PortableCommand.compile(operation,
               native_rule_candidate?: true,
               rule_candidate_provider: fn _ ->
                 flunk("INPUT must remain original submitted intent")
               end
             )
  end

  test "advisory transaction updates require protected prior record state" do
    domain = domain(:transaction, %{op: "value.eq", value: "new"})
    domain = put_in(domain, [:rules, :bindings, :check, :enforcement], :advisory)
    operation = domain |> SelectoUpdato.new() |> SelectoUpdato.update(%{quantity: 2})
    assert SelectoUpdato.PortableCommand.requires_prepared_record_state?(operation)
  end

  defp domain(stage, test) do
    columns = %{id: %{type: :integer}, name: %{type: :string}, quantity: %{type: :integer}}

    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: Map.keys(columns),
        columns: columns,
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields:
          Map.new(columns, fn {field, _} -> {field, %{insertable: true, updatable: true}} end)
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{check: %{version: 1, test: test}},
        normalizers: %{},
        bindings: %{
          check: %{
            subject: %{scope: stage, path: [:name]},
            operations: [:insert, :update],
            rule: %{id: :check, version: 1}
          }
        }
      }
    }
  end
end
