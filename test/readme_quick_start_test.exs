defmodule Selecto.ReadmeQuickStartTest do
  use ExUnit.Case, async: false

  @moduletag :requires_db

  test "README quick start executes without an application default adapter" do
    previous = Application.fetch_env(:selecto, :default_adapter)
    Application.delete_env(:selecto, :default_adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:selecto, :default_adapter, adapter)
        :error -> Application.delete_env(:selecto, :default_adapter)
      end
    end)

    [_, quick_start] = File.read!("README.md") |> String.split("## Quick Start", parts: 2)
    [quick_start | _] = String.split(quick_start, "\n## ", parts: 2)

    code =
      Regex.scan(~r/```elixir\n(.*?)```/s, quick_start, capture: :all_but_first)
      |> Enum.map_join("\n", &hd/1)

    {_result, bindings} = Code.eval_string(code)
    assert [[2, total, "Acme"]] = bindings[:rows]
    assert Decimal.equal?(total, Decimal.new("150.00"))
    assert length(bindings[:columns]) == 3
    assert length(bindings[:aliases]) == 3
  end
end
