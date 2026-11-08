defmodule Selecto.Builder.GeneratedName do
  @moduledoc false

  # Names for the CTEs Selecto generates for itself (values-backed schemas,
  # hierarchy, materialized-path and closure joins). They start with a reserved
  # `__selecto_` prefix, so no table a host names is one of them, and fit the
  # identifier limits of every supported database (PostgreSQL keeps 63 bytes,
  # MySQL and MariaDB 64 characters): a longer id is cut and a digest of the
  # whole id (and of the content, where it is given) keeps the name unique.

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

  @doc false
  def hierarchy(join), do: name("__selecto_hierarchy_", join)
  @doc false
  def materialized_path(join), do: name("__selecto_path_", join)
  @doc false
  def closure(join), do: name("__selecto_closure_", join)
  @doc false
  def values(id, fields, rows), do: name("__selecto_values_", id, {fields, rows})
end
