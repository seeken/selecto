defmodule Selecto.Builder.Provenance do
  @moduledoc false

  # What a compile saw, in the building process: whether any builder emitted
  # text it did not generate, and how many filters it compiled. Every builder
  # that takes SQL text marks here, and an unknown selector or filter shape
  # never reaches SQL, so a statement is unmarked only if all of it was
  # generated. An adapter that types statements then treats a marked statement
  # as hand-built, as a whole.

  @raw :selecto_builder_raw_sql
  @nodes :selecto_builder_filter_nodes

  def mark, do: Process.put(@raw, true)

  def count_filter, do: Process.put(@nodes, Process.get(@nodes, 0) + 1)

  @doc "Runs `fun`: `{result, marked?, filter_nodes}`, adding to any outer capture."
  def capture(fun) do
    raw = Process.get(@raw, false)
    nodes = Process.get(@nodes, 0)
    Process.put(@raw, false)
    Process.put(@nodes, 0)

    try do
      result = fun.()
      {result, Process.get(@raw, false), Process.get(@nodes, 0)}
    after
      Process.put(@raw, raw or Process.get(@raw, false))
      Process.put(@nodes, nodes + Process.get(@nodes, 0))
    end
  end

  @doc "Runs `fun`, whose text Selecto generated, without marking."
  def generated(fun) do
    raw = Process.get(@raw, false)

    try do
      fun.()
    after
      Process.put(@raw, raw)
    end
  end
end
