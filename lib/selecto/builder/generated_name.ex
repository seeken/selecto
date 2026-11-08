defmodule Selecto.Builder.GeneratedName do
  @moduledoc false

  # Names for the CTEs Selecto generates for itself (values-backed schemas,
  # hierarchy, materialized-path and closure joins): a `__selecto_` prefix, the
  # id, and a digest of what the CTE holds (a values list's rows, a hierarchy
  # join's definition), within the identifier limits of every supported
  # database (PostgreSQL keeps 63 bytes, MySQL and MariaDB 64 characters): a
  # longer id is cut. Selecto.Executor refuses a statement where one of them
  # names a relation it reads, or names two different lists.

  @limit 63
  @digest 10

  @doc false
  def name(prefix, id, content \\ :none) do
    id = to_string(id)

    case content do
      :none ->
        full = prefix <> id
        if byte_size(full) <= @limit, do: full, else: cut(prefix, id, digest({id}))

      content ->
        suffix = "_" <> digest({id, content})
        full = prefix <> id <> suffix
        if byte_size(full) <= @limit, do: full, else: cut(prefix, id, digest({id, content}))
    end
  end

  defp cut(prefix, id, digest) do
    room = @limit - byte_size(prefix) - 1 - byte_size(digest)
    prefix <> safe_slice(id, room) <> "_" <> digest
  end

  # Cuts at a character boundary at or below `bytes`.
  defp safe_slice(id, bytes) do
    id
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) <= bytes, do: {:cont, acc <> g}, else: {:halt, acc}
    end)
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @digest)
  end

  # What decides a hierarchy join's generated CTE: the relation and columns it
  # reads, its depth and path settings, its declared schema. Two joins with one
  # id and different definitions (a root's and a CTE body's) get two names.
  @definition_keys [
    :source,
    :source_schema,
    :closure_table,
    :ancestor_field,
    :descendant_field,
    :depth_field,
    :id_field,
    :name_field,
    :parent_field,
    :hierarchy_depth,
    :depth_limit,
    :path_field,
    :path_separator,
    :root_path
  ]

  @doc false
  def hierarchy(join, config), do: name("__selecto_hierarchy_", join, definition(config))
  @doc false
  def materialized_path(join, config), do: name("__selecto_path_", join, definition(config))
  @doc false
  def closure(join, config), do: name("__selecto_closure_", join, definition(config))

  defp definition(config) when is_map(config),
    do: config |> Map.take(@definition_keys) |> Enum.sort()

  defp definition(_config), do: []
  @doc false
  def values(id, fields, rows), do: name("__selecto_values_", id, {fields, rows})
end
