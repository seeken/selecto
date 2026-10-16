defmodule Selecto.Builder.ExactCompare do
  @moduledoc false

  # Tenant and site identity must compare exactly. MySQL and MariaDB compare
  # text under the column's collation: under the default ones (
  # utf8mb4_0900_ai_ci, utf8mb4_uca1400_ai_ci, *_general_ci, *_unicode_ci) a
  # tenant column matches case- and accent-insensitively, and under PAD SPACE
  # collations it ignores trailing spaces, so tenant 't1' would read and pair
  # rows of 'T1' and 't1 '. PostgreSQL and SQLite compare exactly.
  #
  # Adapters declaring `:exact_tenant_compare` (MySQL, MariaDB) get every
  # tenant/site comparison as
  #
  #     (<col> = ? AND CAST(CONVERT(<col> USING utf8mb4) AS BINARY) = CAST(? AS BINARY))
  #
  # which keeps the column's index usable and decides on the stored bytes.
  # Every other adapter gets the plain comparison, byte-identical to before.
  #
  # A column takes the exact form when its name is a tenant or site column the
  # domain declares (the root's tenant_field, its writes.scope tenant field,
  # its tenant_columns, and every schema's tenant_field), unless every
  # declaration of that name in the domain gives it a non-text type (integer,
  # decimal, UUID or binary key types compare exactly already). A column whose
  # type is not declared takes the exact form: it is correct for numbers too.

  alias Selecto.AdapterSupport

  @feature :exact_tenant_compare

  @non_text_types ~w(id integer bigint smallint tinyint serial bigserial int
                     decimal numeric float double real boolean bool
                     uuid binary_id binary bytea date time datetime naive_datetime
                     utc_datetime utc_datetime_usec naive_datetime_usec timestamp
                     timestamptz)

  @doc false
  def enabled?(%{adapter: adapter}) when is_atom(adapter) and not is_nil(adapter),
    do: AdapterSupport.supports_feature?(adapter, @feature)

  def enabled?(_selecto), do: false

  @doc false
  # Whether a column named `name` takes the exact form on this query.
  def column?(selecto, name) when is_atom(name) and not is_nil(name),
    do: column?(selecto, Atom.to_string(name))

  def column?(selecto, name) when is_binary(name) do
    enabled?(selecto) and exact_name?(Map.get(selecto, :domain), name)
  end

  def column?(_selecto, _name), do: false

  @doc false
  # Whether a column named `name` of `domain` is a text (or undeclared-type)
  # tenant/site column.
  def exact_name?(domain, name) when is_map(domain) and is_binary(name) do
    name in tenant_names(domain) and not non_text_everywhere?(domain, name)
  end

  def exact_name?(_domain, _name), do: false

  @doc false
  # `left = right`, exact when `exact?`. A column side is converted to utf8mb4
  # before its bytes are compared: CAST(col AS BINARY) alone would compare the
  # column's own charset bytes, so a utf16, ucs2, utf32 or latin1 tenant column
  # would never equal the utf8mb4 bound value. A bound value (`{:param, _}` or
  # `?`) is already utf8mb4.
  def eq(left, right, true),
    do: ["(", left, " = ", right, " AND ", bytes(left), " = ", bytes(right), ")"]

  def eq(left, right, _exact?), do: [left, " = ", right]

  @doc false
  # `left IN (values)` for parameter markers or rendered values, exact when
  # `exact?`: `left IN (v, ...) AND <bytes(left)> IN (<bytes(v)>, ...)`.
  def in_list(left, values, true) do
    plain = Enum.intersperse(values, ", ")
    cast = values |> Enum.map(&bytes/1) |> Enum.intersperse(", ")
    ["(", left, " IN (", plain, ") AND ", bytes(left), " IN (", cast, "))"]
  end

  def in_list(left, values, _exact?), do: [left, " IN (", Enum.intersperse(values, ", "), ")"]

  @doc false
  # `left IN <subquery>` (fragments include their parentheses), exact when
  # `exact?`: `left IN <plain> AND <bytes(left)> IN <bytes_subquery>`, where
  # `bytes_subquery` selects the utf8mb4 bytes of the subquery's single
  # column (see bytes_subquery/2). Both fragments bind their parameter
  # markers in SQL-text order.
  def in_subquery(left, plain, bytes_subquery, true),
    do: ["(", left, " IN ", plain, " AND ", bytes(left), " IN ", bytes_subquery, ")"]

  def in_subquery(left, plain, _bytes_subquery, _exact?), do: [left, " IN ", plain]

  @doc false
  # A subquery fragment selecting the utf8mb4 bytes of `column` of the derived
  # table built from `subquery` (iodata with its own parentheses).
  def bytes_subquery(subquery, column),
    do: [
      "(SELECT ",
      bytes(["`selecto_exact`.`", column, "`"]),
      " FROM ",
      subquery,
      " AS `selecto_exact`)"
    ]

  @doc false
  # The utf8mb4 bytes of a column expression or a bound value.
  def bytes({:param, _value} = param), do: ["CAST(", param, " AS BINARY)"]
  def bytes("?"), do: "CAST(? AS BINARY)"
  def bytes(expression), do: ["CAST(CONVERT(", expression, " USING utf8mb4) AS BINARY)"]

  @doc false
  # Whether a column named `name` takes the exact form by type alone: false
  # only when every declaration of it in `domain` is a non-text type.
  def text_column?(domain, name) when is_map(domain) and (is_binary(name) or is_atom(name)),
    do: not non_text_everywhere?(domain, to_string(name))

  def text_column?(_domain, _name), do: true

  defp tenant_names(domain) do
    root = Selecto.Tenant.domain_tenant_columns(domain)

    schemas =
      case get(domain, :schemas) do
        schemas when is_map(schemas) ->
          schemas
          |> Map.values()
          |> Enum.flat_map(fn schema ->
            [get(schema, :tenant_field), write_tenant_field(schema)]
          end)

        _ ->
          []
      end

    (root ++ [write_tenant_field(domain)] ++ schemas)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp write_tenant_field(relation) when is_map(relation) do
    tenant = relation |> get(:writes) |> get(:scope) |> get(:tenant)
    get(tenant, :field) || get(tenant, :tenant_field)
  end

  defp write_tenant_field(_relation), do: nil

  # True only when the name is declared somewhere and every declaration types
  # it as a non-text value.
  defp non_text_everywhere?(domain, name) do
    relations =
      [get(domain, :source)] ++
        case get(domain, :schemas) do
          schemas when is_map(schemas) -> Map.values(schemas)
          _ -> []
        end

    types =
      relations
      |> Enum.flat_map(fn relation ->
        case column_spec(relation, name) do
          nil -> []
          spec -> [column_type(spec)]
        end
      end)

    types != [] and Enum.all?(types, &non_text_type?/1)
  end

  defp column_spec(relation, name) when is_map(relation) do
    case get(relation, :columns) do
      columns when is_map(columns) ->
        Enum.find_value(columns, fn {field, spec} -> if to_string(field) == name, do: spec end)

      _ ->
        nil
    end
  end

  defp column_spec(_relation, _name), do: nil

  defp column_type(spec) when is_map(spec), do: get(spec, :type)
  defp column_type(spec) when is_atom(spec) or is_binary(spec), do: spec
  defp column_type(_spec), do: nil

  @doc false
  # Whether a declared column type takes the exact form: text types and an
  # undeclared (nil) or unrecognised type do; integer, decimal, UUID, binary,
  # boolean and temporal types compare exactly already.
  def text_type?(type), do: not non_text_type?(type)

  defp non_text_type?(type) when is_atom(type) and not is_nil(type),
    do: non_text_type?(Atom.to_string(type))

  defp non_text_type?(type) when is_binary(type),
    do: String.downcase(type) in @non_text_types

  defp non_text_type?({:array, _}), do: false
  defp non_text_type?(_type), do: false

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil
end
