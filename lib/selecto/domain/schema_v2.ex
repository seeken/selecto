defmodule Selecto.Domain.SchemaV2 do
  @moduledoc """
  Domain schema 2 (certification specification 3.0).

  Schema 2 declares tenancy once in a top-level `tenant`, lists a relation's
  fields as the keys of its `columns` (ordered by an optional `field_order`),
  implies a capability entry that only restates its action, and computes the
  domain fingerprint: the lower-case hexadecimal SHA-256 of the RFC 8785 (JSON
  Canonicalization Scheme) serialization of the document without
  `domain_fingerprint`.

  - `jcs/1` - RFC 8785 canonical JSON text
  - `fingerprint/1` - the computed domain fingerprint
  - `validate/1` - the version 2 rules, as a list of `%{code, path}`
  - `migrate/1` - a version 1 document to version 2
  - `to_version_1/1` - the version 1 form of a valid version 2 document, which
    the rest of Selecto's domain contract reads

  Documents are JSON maps with string keys. Atom keys are read as their names;
  results use string keys.
  """

  import Bitwise, only: [<<<: 2]

  @sources ["trusted_context", "prefix", "filter", "payload"]
  @tenant_keys ["field", "write_field", "satisfied_by", "pins"]
  @max_safe_integer 1 <<< 53

  # ------------------------------------------------------------------ RFC 8785

  @doc """
  Returns the RFC 8785 canonical serialization of a JSON value.

  Object keys sort by their UTF-16 code units and numbers use the ECMAScript
  number format. Integers beyond ±2^53 raise `ArgumentError`. `nil` is null;
  other atoms serialize as strings.
  """
  @spec jcs(term()) :: String.t()
  def jcs(value), do: value |> encode() |> IO.iodata_to_binary()

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_integer(value), do: integer(value)
  defp encode(value) when is_float(value), do: float(value)
  defp encode(value) when is_binary(value), do: string(value)
  defp encode(value) when is_atom(value), do: value |> Atom.to_string() |> string()

  defp encode(value) when is_list(value),
    do: ["[", value |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]

  defp encode(value) when is_map(value) and not is_struct(value) do
    members =
      value
      |> Enum.map(fn {key, member} -> {key_name(key), member} end)
      |> Enum.sort_by(fn {key, _member} -> utf16(key) end)
      |> Enum.map(fn {key, member} -> [string(key), ":", encode(member)] end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp encode(value), do: raise(ArgumentError, "not a JSON value: #{inspect(value)}")

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
  defp key_name(key), do: raise(ArgumentError, "not a JSON object key: #{inspect(key)}")

  defp integer(value) when abs(value) > @max_safe_integer,
    do:
      raise(
        ArgumentError,
        "integer #{value} is outside the range RFC 8785 represents exactly"
      )

  defp integer(value), do: Integer.to_string(value)

  defp float(value) when value == 0, do: "0"

  defp float(value) do
    {digits, n} = shortest(abs(value))
    sign = if value < 0, do: "-", else: ""
    k = byte_size(digits)

    cond do
      k <= n and n <= 21 ->
        sign <> digits <> String.duplicate("0", n - k)

      0 < n and n <= 21 ->
        sign <> binary_part(digits, 0, n) <> "." <> binary_part(digits, n, k - n)

      -6 < n and n <= 0 ->
        sign <> "0." <> String.duplicate("0", -n) <> digits

      true ->
        e = n - 1
        fraction = if k > 1, do: "." <> binary_part(digits, 1, k - 1), else: ""
        exponent = if e >= 0, do: "+" <> Integer.to_string(e), else: Integer.to_string(e)
        sign <> binary_part(digits, 0, 1) <> fraction <> "e" <> exponent
    end
  end

  # The shortest round-trip digits and the point position n: value = 0.digits * 10^n.
  defp shortest(value) do
    text = :erlang.float_to_binary(value, [:short])

    {mantissa, exponent} =
      case String.split(text, ["e", "E"]) do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {whole, fraction} =
      case String.split(mantissa, ".") do
        [whole, fraction] -> {whole, fraction}
        [whole] -> {whole, ""}
      end

    all = whole <> fraction
    trimmed = String.trim_leading(all, "0")
    point = byte_size(whole) + exponent - (byte_size(all) - byte_size(trimmed))

    digits =
      case String.trim_trailing(trimmed, "0") do
        "" -> "0"
        digits -> digits
      end

    {digits, point}
  end

  defp string(value) do
    escaped =
      for <<byte <- value>>, into: "" do
        case byte do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\b -> "\\b"
          ?\f -> "\\f"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          byte when byte < 0x20 -> "\\u00" <> hex_byte(byte)
          byte -> <<byte>>
        end
      end

    "\"" <> escaped <> "\""
  end

  defp hex_byte(byte),
    do: byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  defp utf16(key), do: :unicode.characters_to_binary(key, :utf8, {:utf16, :big})

  @doc """
  Returns the domain fingerprint: the lower-case hexadecimal SHA-256 of the
  RFC 8785 serialization of the document without `domain_fingerprint`.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(document) when is_map(document) do
    body = Map.drop(document, ["domain_fingerprint", :domain_fingerprint])
    :crypto.hash(:sha256, jcs(body)) |> Base.encode16(case: :lower)
  end

  # ------------------------------------------------------------------ validation

  @doc "Whether a document declares schema version 2."
  @spec version_2?(term()) :: boolean()
  def version_2?(document) when is_map(document) do
    version = Map.get(document, "schema_version", Map.get(document, :schema_version))
    is_number(version) and version == 2
  end

  def version_2?(_document), do: false

  @doc """
  Returns the version 2 rule errors of a document, each `%{code: atom, path: list}`.

  Everything the version 2 rules do not name is validated as version 1 (see
  `to_version_1/1`).
  """
  @spec validate(term()) :: [%{code: atom(), path: list()}]
  def validate(document) when is_map(document) do
    document = stringify_keys(document)

    []
    |> check_version(document)
    |> check_relations(document)
    |> check_writes_scope(document)
    |> check_tenant(document)
    |> check_fingerprint(document)
    |> Enum.reverse()
  end

  def validate(_document), do: [%{code: :invalid_domain, path: []}]

  defp err(errors, code, path), do: [%{code: code, path: path} | errors]

  defp check_version(errors, document) do
    if version_2?(document),
      do: errors,
      else: err(errors, :invalid_schema_version, ["schema_version"])
  end

  defp check_relations(errors, document) do
    document
    |> relations()
    |> Enum.reduce(errors, fn {path, relation}, errors ->
      columns = Map.get(relation, "columns")

      errors =
        if Map.has_key?(relation, "fields"),
          do: err(errors, :fields_removed, path ++ ["fields"]),
          else: errors

      errors =
        if path == ["source"] and Map.has_key?(relation, "tenant_field"),
          do: err(errors, :tenant_field_removed, path ++ ["tenant_field"]),
          else: errors

      cond do
        not is_map(columns) or map_size(columns) == 0 ->
          err(errors, :invalid_columns, path ++ ["columns"])

        Map.has_key?(relation, "field_order") and
            not names_of?(Map.get(relation, "field_order"), columns) ->
          err(errors, :invalid_field_order, path ++ ["field_order"])

        true ->
          errors
      end
    end)
  end

  # A list of strings naming every key of columns exactly once.
  defp names_of?(names, columns) when is_list(names) do
    Enum.all?(names, &is_binary/1) and length(names) == length(Enum.uniq(names)) and
      MapSet.new(names) == MapSet.new(Map.keys(columns))
  end

  defp names_of?(_names, _columns), do: false

  defp check_writes_scope(errors, document) do
    with %{} = writes <- Map.get(document, "writes"),
         %{} = scope <- Map.get(writes, "scope"),
         true <- Map.has_key?(scope, "tenant") do
      err(errors, :writes_scope_tenant_removed, ["writes", "scope", "tenant"])
    else
      _ -> errors
    end
  end

  defp check_tenant(errors, %{"tenant" => tenant} = document) when is_map(tenant) do
    columns = source_columns(document)

    errors =
      tenant
      |> Map.keys()
      |> Enum.reject(&(&1 in @tenant_keys))
      |> Enum.sort()
      |> Enum.reduce(errors, &err(&2, :unknown_tenant_key, ["tenant", &1]))

    field = Map.get(tenant, "field")

    errors =
      if is_binary(field) and Map.has_key?(columns, field),
        do: errors,
        else: err(errors, :invalid_tenant_field, ["tenant", "field"])

    errors
    |> check_write_field(tenant, field, columns)
    |> check_satisfied_by(tenant)
    |> check_pins(tenant, columns)
  end

  defp check_tenant(errors, %{"tenant" => _tenant}), do: err(errors, :invalid_tenant, ["tenant"])
  defp check_tenant(errors, _document), do: errors

  defp check_write_field(errors, %{"write_field" => write_field}, field, columns) do
    if is_binary(write_field) and Map.has_key?(columns, write_field) and write_field != field,
      do: errors,
      else: err(errors, :invalid_tenant_write_field, ["tenant", "write_field"])
  end

  defp check_write_field(errors, _tenant, _field, _columns), do: errors

  defp check_satisfied_by(errors, %{"satisfied_by" => sources}) do
    valid =
      is_list(sources) and sources != [] and
        length(sources) == length(Enum.uniq(sources)) and
        Enum.all?(sources, &(is_binary(&1) and &1 in @sources))

    if valid,
      do: errors,
      else: err(errors, :invalid_tenant_satisfied_by, ["tenant", "satisfied_by"])
  end

  defp check_satisfied_by(errors, _tenant), do: errors

  defp check_pins(errors, %{"pins" => pins}, columns) when is_list(pins) do
    pins
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {pin, index}, errors ->
      if valid_pin?(pin, columns),
        do: errors,
        else: err(errors, :invalid_tenant_pin, ["tenant", "pins", index])
    end)
  end

  defp check_pins(errors, %{"pins" => _pins}, _columns),
    do: err(errors, :invalid_tenant_pins, ["tenant", "pins"])

  defp check_pins(errors, _tenant, _columns), do: errors

  defp valid_pin?([column, value], columns) when is_binary(column),
    do: Map.has_key?(columns, column) and scalar?(value)

  defp valid_pin?(_pin, _columns), do: false

  defp check_fingerprint(errors, %{"domain_fingerprint" => declared} = document) do
    if is_binary(declared) and declared == fingerprint(document),
      do: errors,
      else: err(errors, :domain_fingerprint_mismatch, ["domain_fingerprint"])
  end

  defp check_fingerprint(errors, _document), do: errors

  defp source_columns(document) do
    with %{} = source <- Map.get(document, "source"),
         %{} = columns <- Map.get(source, "columns") do
      columns
    else
      _ -> %{}
    end
  end

  defp relations(document) do
    source =
      case Map.get(document, "source") do
        %{} = source -> [{["source"], source}]
        _ -> []
      end

    schemas =
      case Map.get(document, "schemas") do
        %{} = schemas ->
          schemas
          |> Enum.filter(fn {_name, relation} -> is_map(relation) end)
          |> Enum.sort_by(fn {name, _relation} -> name end)
          |> Enum.map(fn {name, relation} -> {["schemas", name], relation} end)

        _ ->
          []
      end

    source ++ schemas
  end

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value)

  # ------------------------------------------------------------------ migration

  @doc """
  Migrates a valid version 1 document to version 2.

  Returns `{:ok, %{document: v2, diagnostics: diagnostics}}`, where diagnostics
  always starts with `%{code: :domain_schema_deprecated}` and includes
  `%{code: :declared_fingerprint_dropped, value: declared}` when the input
  declared a fingerprint, or `{:refused, %{code: atom, path: list}}` for what
  the migration cannot place.
  """
  @spec migrate(term()) ::
          {:ok, %{document: map(), diagnostics: [map()]}}
          | {:refused, %{code: atom(), path: list()}}
  def migrate(v1) when is_map(v1) do
    doc = stringify_keys(v1)

    if Map.get(doc, "schema_version", 1) == 1 do
      doc
      |> Map.put("schema_version", 2)
      |> migrate_fields()
      |> migrate_tenancy()
      |> migrate_finish()
    else
      refuse(:not_version_1, ["schema_version"])
    end
  end

  def migrate(_v1), do: refuse(:not_version_1, ["schema_version"])

  defp refuse(code, path), do: {:refused, %{code: code, path: path}}

  defp migrate_fields(doc) do
    doc
    |> relations()
    |> Enum.reduce_while({:ok, doc}, fn {path, relation}, {:ok, doc} ->
      case Map.pop(relation, "fields", :absent) do
        {:absent, _relation} ->
          {:cont, {:ok, doc}}

        {fields, relation} ->
          columns = Map.get(relation, "columns")

          if is_map(columns) and names_of?(fields, columns) do
            relation =
              if fields == sorted_names(Map.keys(columns)),
                do: relation,
                else: Map.put(relation, "field_order", fields)

            {:cont, {:ok, put_in(doc, path, relation)}}
          else
            {:halt, refuse(:domain_migration_ambiguous, path ++ ["fields"])}
          end
      end
    end)
  end

  defp migrate_tenancy({:refused, _refusal} = refused), do: refused

  defp migrate_tenancy({:ok, doc}) do
    {tenant_field, doc} =
      case Map.get(doc, "source") do
        %{} = source ->
          {tenant_field, source} = Map.pop(source, "tenant_field")
          {tenant_field, Map.put(doc, "source", source)}

        _ ->
          {nil, doc}
      end

    {scope_tenant, doc} = pop_scope_tenant(doc)

    if is_nil(tenant_field) and is_nil(scope_tenant) do
      {:ok, doc}
    else
      scope_field =
        case scope_tenant do
          %{"field" => field} -> field
          %{} -> Map.get(scope_tenant, "tenant_field")
          _ -> nil
        end

      case tenant_field || scope_field do
        nil ->
          refuse(:domain_migration_ambiguous, ["writes", "scope", "tenant"])

        field ->
          tenant =
            %{"field" => field}
            |> maybe_put("write_field", if(scope_field != field, do: scope_field))
            |> maybe_put("satisfied_by", scope_sources(scope_tenant))

          {:ok, move_tenant_pins(doc, tenant)}
      end
    end
  end

  defp pop_scope_tenant(%{"writes" => %{"scope" => %{} = scope} = writes} = doc) do
    {scope_tenant, scope} = Map.pop(scope, "tenant")

    writes =
      if map_size(scope) == 0,
        do: Map.delete(writes, "scope"),
        else: Map.put(writes, "scope", scope)

    doc =
      if map_size(writes) == 0,
        do: Map.delete(doc, "writes"),
        else: Map.put(doc, "writes", writes)

    {scope_tenant, doc}
  end

  defp pop_scope_tenant(doc), do: {nil, doc}

  defp scope_sources(%{"satisfied_by" => sources}) when is_list(sources), do: sources
  defp scope_sources(%{"satisfied_by" => _sources}), do: nil
  defp scope_sources(%{"sources" => sources}) when is_list(sources), do: sources
  defp scope_sources(_scope_tenant), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp move_tenant_pins(%{"required_filters" => filters} = doc, tenant) when is_list(filters) do
    tenant_columns = Enum.reject([tenant["field"], tenant["write_field"]], &is_nil/1)

    {pins, kept} =
      Enum.split_with(filters, fn
        [column, value] -> column in tenant_columns and scalar?(value)
        _entry -> false
      end)

    tenant = if pins == [], do: tenant, else: Map.put(tenant, "pins", pins)

    doc =
      if kept == [],
        do: Map.delete(doc, "required_filters"),
        else: Map.put(doc, "required_filters", kept)

    Map.put(doc, "tenant", tenant)
  end

  defp move_tenant_pins(doc, tenant), do: Map.put(doc, "tenant", tenant)

  defp migrate_finish({:refused, _refusal} = refused), do: refused

  defp migrate_finish({:ok, doc}) do
    doc = drop_implied_capabilities(doc)

    case Map.pop(doc, "domain_fingerprint", :absent) do
      {:absent, doc} ->
        {:ok, %{document: doc, diagnostics: [deprecated()]}}

      {declared, doc} ->
        {:ok,
         %{
           document: doc,
           diagnostics: [deprecated(), %{code: :declared_fingerprint_dropped, value: declared}]
         }}
    end
  end

  defp deprecated, do: %{code: :domain_schema_deprecated}

  defp drop_implied_capabilities(%{"capabilities" => %{} = capabilities} = doc) do
    actions =
      case Map.get(doc, "actions") do
        %{} = actions -> actions
        _ -> %{}
      end

    capabilities =
      actions
      |> Enum.sort_by(fn {id, _action} -> id end)
      |> Enum.reduce(capabilities, fn {id, action}, capabilities ->
        with %{} <- action,
             name when is_binary(name) <- Map.get(action, "capability"),
             operation when is_binary(operation) <- action_operation(action),
             %{} = entry <- Map.get(capabilities, name),
             true <- implied_entry?(entry, id, operation) do
          Map.delete(capabilities, name)
        else
          _ -> capabilities
        end
      end)

    if map_size(capabilities) == 0,
      do: Map.delete(doc, "capabilities"),
      else: Map.put(doc, "capabilities", capabilities)
  end

  defp drop_implied_capabilities(doc), do: doc

  defp action_operation(action) do
    case Map.get(action, "execution") do
      %{} = execution -> Map.get(execution, "operation")
      _ -> nil
    end
  end

  defp implied_entry?(entry, id, operation) do
    operations = Map.get(entry, "operations")

    Enum.sort(Map.keys(entry)) == ["action", "operations"] and entry["action"] == id and
      is_list(operations) and length(operations) == length(Enum.uniq(operations)) and
      Enum.sort(operations) == Enum.sort(Enum.uniq(["action", operation]))
  end

  # ------------------------------------------------------------------ version 1

  @doc """
  Returns the version 1 form of a valid version 2 document: the inverse of
  `migrate/1`, which the rest of Selecto's domain contract reads.
  """
  @spec to_version_1(map()) :: map()
  def to_version_1(v2) when is_map(v2) do
    doc =
      v2
      |> stringify_keys()
      |> Map.delete("domain_fingerprint")
      |> Map.put("schema_version", 1)

    doc =
      doc
      |> relations()
      |> Enum.reduce(doc, fn {path, relation}, doc ->
        {order, relation} = Map.pop(relation, "field_order")

        fields =
          case {order, Map.get(relation, "columns")} do
            {order, _columns} when is_list(order) -> order
            {_order, %{} = columns} -> sorted_names(Map.keys(columns))
            _ -> []
          end

        put_in(doc, path, Map.put(relation, "fields", fields))
      end)

    doc
    |> restore_tenant()
    |> restore_capabilities()
  end

  defp restore_tenant(%{"tenant" => %{} = tenant} = doc) do
    doc = Map.delete(doc, "tenant")
    field = Map.get(tenant, "field")

    source =
      case Map.get(doc, "source") do
        %{} = source -> source
        _ -> %{}
      end

    doc = Map.put(doc, "source", Map.put(source, "tenant_field", field))

    # The one tenant declaration bounds writes too, so it always restores
    # writes.scope.tenant: the explicit public write authority of version 1.
    scope =
      %{"required" => true, "field" => Map.get(tenant, "write_field") || field}
      |> then(fn scope ->
        if Map.has_key?(tenant, "satisfied_by"),
          do: Map.put(scope, "satisfied_by", tenant["satisfied_by"]),
          else: scope
      end)

    writes =
      case Map.get(doc, "writes") do
        %{} = writes -> writes
        _ -> %{}
      end

    writes_scope =
      case Map.get(writes, "scope") do
        %{} = writes_scope -> writes_scope
        _ -> %{}
      end

    doc = Map.put(doc, "writes", Map.put(writes, "scope", Map.put(writes_scope, "tenant", scope)))

    # Pins lead, as tenant pins usually do in version 1.
    case Map.get(tenant, "pins") do
      [_ | _] = pins ->
        existing =
          case Map.get(doc, "required_filters") do
            filters when is_list(filters) -> filters
            _ -> []
          end

        Map.put(doc, "required_filters", pins ++ existing)

      _ ->
        doc
    end
  end

  defp restore_tenant(doc), do: Map.delete(doc, "tenant")

  defp restore_capabilities(%{"actions" => %{} = actions} = doc) do
    actions
    |> Enum.sort_by(fn {id, _action} -> id end)
    |> Enum.reduce(doc, fn {id, action}, doc ->
      capabilities =
        case Map.get(doc, "capabilities") do
          %{} = capabilities -> capabilities
          _ -> nil
        end

      with %{} <- action,
           name when is_binary(name) <- Map.get(action, "capability"),
           operation when is_binary(operation) <- action_operation(action),
           false <- is_map(capabilities) and Map.has_key?(capabilities, name) do
        entry = %{"action" => id, "operations" => ["action", operation]}
        Map.put(doc, "capabilities", Map.put(capabilities || %{}, name, entry))
      else
        _ -> doc
      end
    end)
  end

  defp restore_capabilities(doc), do: doc

  # ------------------------------------------------------------------ helpers

  defp sorted_names(names), do: Enum.sort_by(names, &utf16/1)

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp stringify_key(key) when is_atom(key) and key not in [nil, true, false],
    do: Atom.to_string(key)

  defp stringify_key(key), do: key
end
