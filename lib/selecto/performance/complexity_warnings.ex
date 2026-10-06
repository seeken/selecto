defmodule Selecto.Performance.ComplexityWarnings do
  @moduledoc false

  # Decides whether `Selecto.execute/2` logs a complexity warning. The same
  # query shape (its compiled SQL text, without parameter values) gives the
  # same warnings on every call, so by default each warning is logged once
  # per shape rather than on every execution:
  #
  #     config :selecto, :complexity_warning_log, :once_per_shape  # default
  #     config :selecto, :complexity_warning_log, :every_call
  #
  # Shapes already logged are kept in a bounded table owned by the
  # application; when it fills it is cleared and warnings are logged again.
  # Without the table (application not started) every warning is logged.
  # The `[:selecto, :query, :complexity_analyzed]` event is unaffected.

  @table :selecto_complexity_warnings_logged
  @max_entries 4_096

  @doc false
  def init_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc false
  @spec log?(String.t() | nil, String.t()) :: boolean()
  def log?(sql, warning) when is_binary(sql) and is_binary(warning) do
    case Application.get_env(:selecto, :complexity_warning_log, :once_per_shape) do
      :every_call -> true
      _once_per_shape -> first_for_shape?(sql, warning)
    end
  end

  def log?(_sql, _warning), do: true

  defp first_for_shape?(sql, warning) do
    key = {:erlang.phash2(sql, 4_294_967_296), byte_size(sql), warning}

    case :ets.info(@table, :size) do
      :undefined ->
        true

      size ->
        if size >= @max_entries, do: :ets.delete_all_objects(@table)
        :ets.insert_new(@table, {key})
    end
  rescue
    # The table went away between the size check and the insert.
    ArgumentError -> true
  end
end
