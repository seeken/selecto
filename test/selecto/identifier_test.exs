defmodule Selecto.IdentifierTest do
  use ExUnit.Case, async: true

  alias Selecto.Identifier

  @identifier_source Path.expand("../../lib/selecto/identifier.ex", __DIR__)

  test "passes atoms through" do
    assert Identifier.to_atom!(:known_identifier) == :known_identifier
  end

  test "returns existing atoms without creating a dynamic identifier" do
    assert Identifier.to_atom!("known_identifier") == :known_identifier
  end

  test "interns a valid runtime identifier consistently" do
    identifier = "selecto_runtime_identifier_#{System.unique_integer([:positive])}"

    assert atom = Identifier.to_atom!(identifier)
    assert Atom.to_string(atom) == identifier
    assert Identifier.to_atom!(identifier) == atom
  end

  test "rejects invalid identifier inputs" do
    assert {:error, "identifier cannot be empty"} = Identifier.to_atom("")
    assert {:error, _message} = Identifier.to_atom(String.duplicate("x", 256))
    assert {:error, _message} = Identifier.to_atom(nil)
  end

  @tag timeout: 120_000
  test "concurrent new identifiers cannot exceed the public VM-lifetime budget" do
    # A fresh VM tests initialization and exhaustion without consuming the
    # application's shared budget or altering its persistent counter.
    code = ~S"""
    limit = Selecto.Identifier.max_dynamic_identifiers()
    results =
      Task.async_stream(1..(limit + 64), fn i ->
        Selecto.Identifier.to_atom("selecto_budget_probe_" <> Integer.to_string(i))
      end, max_concurrency: 32, ordered: false, timeout: 60_000)
      |> Enum.to_list()
    accepted = Enum.count(results, &match?({:ok, {:ok, _}}, &1))
    rejected = Enum.count(results, &match?({:ok, {:error, _}}, &1))
    if accepted != limit or rejected != 64 do
      raise "budget violated: accepted=#{accepted} rejected=#{rejected}"
    end
    IO.puts("budget enforced")
    """

    # Only the executable search path is needed by this standalone child VM.
    child_environment =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&(&1 == "PATH"))
      |> Enum.map(&{&1, nil})

    assert {"budget enforced\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-r", @identifier_source, "-e", code],
               env: child_environment,
               stderr_to_stdout: true
             )
  end
end
