defmodule SelectoTest do
  use ExUnit.Case
  doctest Selecto

  test "single quotes" do
    assert Selecto.Builder.Sql.Helpers.single_wrap("It's") == "'It''s'"
  end

  test "double quotes" do
    assert Selecto.Builder.Sql.Helpers.double_wrap(~s[Hi There]) == ~s["Hi There"]
  end

  test "double quotes escape" do
    assert_raise RuntimeError, ~r/Invalid Table/, fn ->
      Selecto.Builder.Sql.Helpers.double_wrap(~s["Hi," she said])
    end
  end

  ## build configuration

  ### Add selects
  ### Add filters
  ### Add Orders
  ### generate SQL





end
