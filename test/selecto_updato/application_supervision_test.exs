defmodule SelectoUpdato.ApplicationSupervisionTest do
  use ExUnit.Case, async: true

  test "application boots supervisor and authorization server" do
    assert is_pid(Process.whereis(Selecto.Supervisor))
    assert is_pid(Process.whereis(SelectoUpdato.ActionAuthorization))
  end
end
