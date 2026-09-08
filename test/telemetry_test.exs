defmodule Selecto.TelemetryTest do
  use ExUnit.Case, async: false

  alias Selecto.Telemetry

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defmodule ContextProvider do
    @behaviour Selecto.Telemetry.ContextProvider

    def capture, do: Process.get(:test_trace_context)
    def attach(value), do: Process.put(:test_trace_context, value)
    def detach(previous), do: restore(previous)

    defp restore(nil), do: Process.delete(:test_trace_context)
    defp restore(value), do: Process.put(:test_trace_context, value)
  end

  setup do
    events = [
      [:selecto, :telemetry, :operation, :start],
      [:selecto, :telemetry, :operation, :stop],
      [:selecto, :telemetry, :operation, :exception]
    ]

    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:selecto, :telemetry_context_provider)
      Process.delete(:test_trace_context)
    end)

    :ok
  end

  test "emits a safe operation lifecycle for returned errors" do
    selecto = %{adapter: UnsafeAdapter, password: "secret"}
    error = Selecto.Error.query_error("password=secret", "select 'secret'", ["secret"])

    assert {:error, ^error} =
             Telemetry.operation(:execute, selecto, fn -> {:error, error} end)

    assert_receive {:telemetry_event, [:selecto, :telemetry, :operation, :start], _, start}
    assert_receive {:telemetry_event, [:selecto, :telemetry, :operation, :stop], measures, stop}

    assert start.operation_id == stop.operation_id
    assert start.operation_kind == :execute
    assert stop.outcome == :error
    assert stop.error_category == :query
    assert is_integer(measures.duration)
    refute inspect({start, stop}) =~ "secret"
  end

  test "sanitizes exception telemetry and preserves the original exception" do
    assert_raise RuntimeError, "secret failure", fn ->
      Telemetry.operation(:execute, %{}, fn -> raise "secret failure" end)
    end

    assert_receive {:telemetry_event, [:selecto, :telemetry, :operation, :start], _, _}
    assert_receive {:telemetry_event, [:selecto, :telemetry, :operation, :exception], _, metadata}
    assert metadata.outcome == :error
    assert metadata.reason_type == RuntimeError
    refute inspect(metadata) =~ "secret failure"
  end

  test "task supervisor propagates optional host context and restores worker context" do
    Application.put_env(:selecto, :telemetry_context_provider, ContextProvider)
    Process.put(:test_trace_context, :parent_trace)
    parent = self()

    task =
      Selecto.TaskSupervisor.async(fn ->
        send(parent, {:worker_context, Process.get(:test_trace_context)})
        :ok
      end)

    assert Task.await(task) == :ok
    assert_receive {:worker_context, :parent_trace}
  end

  test "single events discard non-numeric measurements and unreviewed metadata" do
    event = [:selecto, :telemetry, :cache, :lookup]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    Telemetry.emit([:cache, :lookup], %{count: 1, payload: "secret"}, %{
      cache_result: :hit,
      sql: "select 'secret'"
    })

    assert_receive {:telemetry_event, ^event, %{count: 1}, metadata}
    assert metadata.cache_result == :hit
    refute inspect(metadata) =~ "secret"
  end
end
