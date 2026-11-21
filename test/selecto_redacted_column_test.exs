defmodule Selecto.RedactedColumnTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  defp relation(table, extra) do
    Map.merge(
      %{
        source_table: table,
        primary_key: :id,
        fields: [:id, :label, :shown, :secret, :token, :maker_id],
        columns: %{
          id: %{type: :integer},
          label: %{type: :string},
          shown: %{type: :string, redacted: false},
          secret: %{type: :string},
          token: %{type: :string, redacted: true},
          maker_id: %{type: :integer}
        },
        associations: %{
          maker: %{queryable: :makers, field: :maker, owner_key: :maker_id, related_key: :id}
        }
      },
      extra
    )
  end

  # Schemas leave redact_fields out: configure/3 defaults it to [].
  defp domain do
    %{
      name: "Redaction",
      source: relation("redaction_items", %{redact_fields: [:secret]}),
      schemas: %{
        makers: %{
          source_table: "redaction_makers",
          primary_key: :id,
          fields: [:id, :name, :code],
          columns: %{
            id: %{type: :integer},
            name: %{type: :string},
            code: %{type: :string, redacted: 1}
          },
          associations: %{}
        }
      },
      joins: %{maker: %{type: :left, name: "Maker"}}
    }
  end

  defp configure(domain) do
    Selecto.configure(domain, :certification_no_connection,
      adapter: Selecto.Verification.QuerySafety.Adapter
    )
  end

  test "redacted_fields: redact_fields plus every column whose redacted flag holds" do
    assert Domain.redacted_fields(domain().source) == [:secret, :token]
    assert Domain.redacted_fields(domain().schemas.makers) == [:code]

    assert Domain.redacted_fields(%{
             "fields" => ["a", "b"],
             "columns" => %{"b" => %{"redacted" => "1"}}
           }) ==
             ["b"]

    assert Domain.redacted_fields(%{fields: [:a], columns: %{"a" => %{redacted: true}}}) == [:a]
    assert Domain.redacted_fields(%{}) == []
  end

  test "a redacted column is withheld like a redact_fields entry, on the root and on a join" do
    selecto = configure(domain())
    columns = Map.keys(selecto.config.columns) |> Enum.map(&to_string/1)

    for field <- ~w(label shown maker.name), do: assert(field in columns, field)
    for field <- ~w(secret token maker.code), do: refute(field in columns, field)

    # The authored domain, and so its contract, keeps the flag.
    assert selecto.domain.source.columns.token.redacted == true
    assert {:ok, contract} = Domain.contract_json(selecto)
    assert contract["source"]["columns"]["token"]["redacted"] == true
    assert contract["source"]["redact_fields"] == ["secret"]
  end

  test "flags follow the portable truth test" do
    assert Domain.flag?(1)
    assert Domain.flag?("yes")
    refute Domain.flag?(0)
    refute Domain.flag?("0")
    refute Domain.flag?("")
    refute Domain.flag?(nil)
    assert Domain.flag(%{"internal" => 1}, :internal, false)
    refute Domain.flag(%{internal: nil}, :internal, false)
    assert Domain.flag(%{}, :filterable, true)
  end
end
