defmodule SelectoUpdato.TelemetryTest do
  use ExUnit.Case, async: false

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:updato_telemetry, event, measurements, metadata})
  end

  setup do
    events = [
      [:selecto_updato, :telemetry, :operation, :start],
      [:selecto_updato, :telemetry, :operation, :stop]
    ]

    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "canonical write telemetry excludes operation input and raw errors" do
    operation = %SelectoUpdato.Operation{
      type: :update,
      changes: %{name: "secret-canary"},
      filters: []
    }

    assert {:error, %SelectoUpdato.Error{}} = SelectoUpdato.execute(operation, %Selecto{})

    assert_receive {:updato_telemetry, [_prefix1, _prefix2, _prefix3, :start], _, start}
    assert_receive {:updato_telemetry, [_prefix1, _prefix2, _prefix3, :stop], measures, stop}

    assert start.operation_kind == :execute
    assert stop.outcome == :error
    assert is_integer(measures.duration)
    refute inspect({start, stop}) =~ "secret-canary"
  end
end
