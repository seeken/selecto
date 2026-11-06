defmodule Selecto.BuilderProvenanceTest do
  # Text is unsafe unless a builder proves it generated: a compile with any
  # of it is marked, and only an unmarked compile is stamped.
  use ExUnit.Case, async: true

  alias Selecto.Builder.Provenance

  defp domain(extra \\ %{}) do
    Map.merge(
      %{
        name: "D",
        source: %{
          source_table: "t",
          primary_key: :id,
          fields: [:id, :org, :c],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            org: %{type: :string},
            c: %{type: :string}
          },
          associations: %{}
        },
        schemas: %{},
        joins: %{}
      },
      extra
    )
  end

  defp base(extra \\ %{}) do
    domain(extra)
    |> Selecto.configure(nil, validate: false)
    |> Selecto.select(["id"])
  end

  defp marked?(selecto) do
    {_sql, marked?, _nodes} =
      Provenance.capture(fn -> Selecto.Builder.Sql.build(selecto, []) end)

    marked? or Provenance.config_text?(selecto)
  end

  test "generated filters stay unmarked" do
    refute marked?(base())
    refute marked?(Selecto.filter(base(), {"c", "x"}))
    refute marked?(Selecto.filter(base(), {"c", {:ref, "selecto_root.org"}}))
  end

  test "a {:ref, text} that is no plain name marks" do
    assert marked?(Selecto.filter(base(), {"c", {:ref, "NULLIF(selecto_root.org, NULL)"}}))
    assert marked?(Selecto.filter(base(), {"c", {"=", {:ref, "lower(selecto_root.org)"}}}))
  end

  test "the internal generated tag cannot be claimed through the public API" do
    raw = {:raw_sql_filter, "NULLIF(selecto_root.c, NULL) <> 'ABC'"}

    for forged <- [{:selecto_generated, raw}, {:selecto_generated, "guess", raw}] do
      assert_raise ArgumentError, fn -> Selecto.filter(base(), forged) end
    end
  end

  test "reference/1 proves plain and quoted name paths only" do
    for name <- ["a", "a.b", ~s("a b"."c"), "a_b$1.c"] do
      {_, marked?, _} = Provenance.capture(fn -> Provenance.reference(name) end)
      refute marked?, name
    end

    for text <- ["a + 1", "f(a)", "a.b = 1", "'x'", "a.", ".a", "", ~s("a)] do
      {_, marked?, _} = Provenance.capture(fn -> Provenance.reference(text) end)
      assert marked?, text
    end
  end

  test "operator/1 proves comparisons only" do
    {_, marked?, _} = Provenance.capture(fn -> Provenance.operator("=") end)
    refute marked?
    {_, marked?, _} = Provenance.capture(fn -> Provenance.operator("= 1 or 1 =") end)
    assert marked?
  end

  test "configuration that is not a plain name counts" do
    refute Provenance.config_text?(base())

    assert Provenance.config_text?(%{domain: %{schemas: %{x: %{source_table: "t WHERE 1 = 1"}}}})

    assert Provenance.config_text?(%{
             domain: %{joins: %{x: %{type: :tagging, join_table: "a JOIN b ON true"}}}
           })

    refute Provenance.config_text?(%{
             domain: %{joins: %{x: %{type: :tagging, join_table: "a_b"}}}
           })
  end
end
