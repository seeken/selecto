defmodule SelectoUpdato.OriginalInputRuleTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.PortableCommand

  test "input rules see submitted text before domain text-case normalization" do
    authored = domain(%{op: "value.eq", value: "abc"})
    authored = put_in(authored, [:source, :columns, :name, :text_case], :uppercase)
    operation = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: "abc"})

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert %{field: "name", value: {:literal, "ABC"}} in command.assignments

    operation = %{operation | attrs: %{name: "ABC"}}
    assert {:error, %{details: %{code: :data_rule_failed}}} = PortableCommand.compile(operation)
  end

  test "input absence is checked before trusted tenant injection" do
    authored = domain(%{op: "presence.absent"}, :tenant_id)

    authored =
      put_in(authored, [:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})

    operation =
      authored
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{name: "abc"})

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments

    operation = %{operation | attrs: %{name: "abc", tenant_id: 7}}
    assert {:error, %{details: %{code: :data_rule_failed}}} = PortableCommand.compile(operation)
  end

  test "input normalizers run once before candidate rules" do
    authored = domain(%{op: "value.eq", value: nil})

    authored =
      put_in(authored, [:rules, :normalizers], %{
        empty: %{version: 1, steps: [%{op: "text.empty_to_null"}]}
      })

    authored = put_in(authored, [:rules, :bindings, :raw, :normalizer], %{id: :empty, version: 1})
    operation = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: ""})

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert %{field: "name", value: {:literal, nil}} in command.assignments
  end

  defp domain(test, field \\ :name) do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :tenant_id],
        columns: %{id: %{type: :integer}, name: %{type: :string}, tenant_id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{name: %{insertable: true, updatable: true}, tenant_id: %{insertable: true}}
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{raw: %{version: 1, test: test}},
        normalizers: %{},
        bindings: %{
          raw: %{
            subject: %{scope: :input, path: [field]},
            operations: [:insert, :update],
            rule: %{id: :raw, version: 1}
          }
        }
      }
    }
  end
end
