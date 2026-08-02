defmodule Selecto.IdentifierTest do
  use ExUnit.Case, async: true

  alias Selecto.Identifier

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
end
