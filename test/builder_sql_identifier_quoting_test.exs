defmodule Selecto.Builder.Sql.IdentifierQuotingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Selecto.Builder.Sql.Helpers

  # The regex and Unicode case mapping implementation the byte matching
  # replaced; the two must agree on every input.
  @reserved_words ~w(
    user order group select from where having limit offset join left right
    inner outer cross union all distinct as on using natural full exists
    case when then else end null is not and or in between like
    primary key foreign references table column index create alter drop
    insert update delete values set into default unique check constraint
    view trigger function procedure return declare begin commit rollback
    transaction isolation level read write only deferrable serializable
    repeatable committed uncommitted work savepoint release cursor fetch
    close cast row array text integer boolean date time timestamp interval
    numeric decimal real double precision varchar char bit varying zone
  )

  defp reference_needs_quoting?(str) do
    cond do
      String.downcase(str) in @reserved_words -> true
      str != String.downcase(str) -> true
      String.match?(str, ~r/^[0-9]/) -> true
      String.match?(str, ~r/[^a-z0-9_]/) -> true
      true -> false
    end
  end

  defp reference_valid_identifier?(str), do: not String.match?(str, ~r/[^a-zA-Z0-9_ :&-]/)

  @samples [
    "",
    "id",
    "order",
    "ORDER",
    "Order",
    "user_id",
    "1abc",
    "_x",
    "a b",
    "a-b",
    "a:b",
    "a&b",
    "a.b",
    "a\"b",
    "café",
    "É",
    <<255>>,
    "selecto_root",
    "zone",
    "zones",
    "9"
  ]

  test "needs_quoting? agrees with the regex implementation on known identifiers" do
    for str <- @samples ++ @reserved_words ++ Enum.map(@reserved_words, &String.upcase/1) do
      assert Helpers.needs_quoting?(str) == reference_needs_quoting?(str), inspect(str)
    end
  end

  property "needs_quoting? agrees with the regex implementation" do
    check all(
            str <-
              one_of([
                string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?\s, ?-, ?:, ?&, ?.]])),
                string(:printable),
                binary()
              ]),
            max_runs: 2_000
          ) do
      assert Helpers.needs_quoting?(str) == reference_needs_quoting?(str)
    end
  end

  property "quote_identifier accepts exactly the identifiers the regex accepted" do
    check all(
            str <-
              one_of([
                string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?\s, ?-, ?:, ?&, ?.]])),
                string(:printable),
                binary()
              ]),
            max_runs: 2_000
          ) do
      selecto = %{}

      if reference_valid_identifier?(str) do
        quoted = Helpers.quote_identifier(selecto, str)
        assert is_binary(quoted)
      else
        assert_raise RuntimeError, ~r/Invalid Table\/Column\/Alias Name/, fn ->
          Helpers.quote_identifier(selecto, str)
        end
      end
    end
  end
end
