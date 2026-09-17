defmodule Selecto.Importer do
  @moduledoc """
  Governed CSV/TSV inspection, mapping normalization, and row preview.

  The importer never chooses tenant scope, resolves database records, or
  executes writes by itself. Hosts provide a request-scoped `:key_resolver`
  callback and trusted values; preview output contains canonical write and
  action intents that still pass through the ordinary governed execution path.
  """

  alias Selecto.{Domain, Error}

  @enforce_keys [:domain, :contract, :runtime_contract]
  defstruct [
    :domain,
    :contract,
    :runtime_contract,
    max_columns: 200,
    max_rows: 50_000,
    max_sample_rows: 25
  ]

  @sources ~w(column static parameter trusted)
  @transforms ~w(trim uppercase lowercase normalize_whitespace empty_to_null)
  @blank_policies ~w(omit empty null error)

  @type t :: %__MODULE__{}

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(domain, opts \\ []) do
    with {:ok, normalized, _diagnostics} <- Domain.validate(domain),
         imports when is_map(imports) <- normalized.imports,
         true <- get(imports, :enabled) == true,
         {:ok, limits} <- limits(opts) do
      public = normalized |> Domain.project(:import) |> Map.fetch!(:imports)
      runtime = runtime_contract(normalized, imports)

      {:ok,
       struct!(
         __MODULE__,
         Keyword.merge(limits, domain: normalized, contract: public, runtime_contract: runtime)
       )}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, diagnostics} ->
        invalid(:invalid_importer, "importer requires a valid Selecto domain", %{
          diagnostics: diagnostics
        })

      _ ->
        invalid(:import_not_enabled, "This domain does not publish an importer contract")
    end
  end

  @spec contract(t()) :: map()
  def contract(%__MODULE__{contract: contract}), do: deep_copy(contract)

  @spec domain_fingerprint(t()) :: String.t()
  def domain_fingerprint(%__MODULE__{domain: domain}) do
    domain.domain_fingerprint || fingerprint(domain.domain)
  end

  @spec inspect_csv(t(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def inspect_csv(%__MODULE__{} = importer, content, opts \\ []) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    header? = Keyword.get(opts, :header, true)

    cond do
      not is_binary(content) ->
        invalid(:invalid_import_file, "CSV content must be a binary")

      not is_binary(delimiter) or String.length(delimiter) != 1 ->
        invalid(:invalid_import_file, "CSV delimiter must be one character")

      not is_boolean(header?) ->
        invalid(:invalid_import_file, "CSV header setting must be boolean")

      true ->
        do_inspect_csv(importer, content, delimiter, header?)
    end
  end

  @spec normalize_configuration(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_configuration(%__MODULE__{} = importer, configuration, opts \\ []) do
    columns = Keyword.get(opts, :columns, [])

    with :ok <-
           object(
             configuration,
             :invalid_import_configuration,
             "import configuration must be a map"
           ),
         :ok <-
           known(
             configuration,
             ~w(config_version domain_fingerprint upload_id profile parser rows mappings actions match idempotency errors parameters),
             "import configuration"
           ),
         :ok <- fingerprint_matches(importer, get(configuration, :domain_fingerprint)),
         :ok <-
           equal(
             get(configuration, :config_version) || 1,
             1,
             :invalid_import_configuration,
             "config_version must be 1"
           ),
         true <- is_list(columns),
         {:ok, mappings} <-
           normalize_mappings(importer, get(configuration, :mappings) || [], columns),
         {:ok, actions} <-
           normalize_actions(importer, get(configuration, :actions) || [], columns),
         {:ok, match} <- normalize_match(importer, get(configuration, :match) || %{}),
         {:ok, rows} <- normalize_rows(get(configuration, :rows) || %{}),
         {:ok, idempotency} <- normalize_idempotency(importer, get(configuration, :idempotency)),
         {:ok, errors} <- normalize_errors(get(configuration, :errors)),
         parameters when is_map(parameters) <- get(configuration, :parameters) || %{},
         :ok <- optional_string(get(configuration, :upload_id), "upload_id must be a string") do
      value = %{
        config_version: 1,
        domain_fingerprint: domain_fingerprint(importer),
        mappings: mappings,
        actions: actions,
        match: match,
        rows: rows,
        parameters: deep_copy(parameters),
        idempotency: idempotency,
        errors: errors
      }

      {:ok, maybe_put(value, :upload_id, get(configuration, :upload_id))}
    else
      {:error, %Error{} = error} -> {:error, error}
      false -> invalid(:invalid_import_configuration, "columns must be a list")
      _ -> invalid(:invalid_import_configuration, "parameters must be a map")
    end
  end

  @spec preview_rows(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def preview_rows(%__MODULE__{} = importer, inspection, configuration, opts \\ []) do
    resolver = Keyword.get(opts, :key_resolver)
    trusted = Keyword.get(opts, :trusted_values, %{})

    with :ok <- object(inspection, :invalid_import_file, "import inspection must be a map"),
         true <- is_function(resolver, 3),
         true <- is_map(trusted),
         {:ok, normalized} <-
           normalize_configuration(importer, configuration,
             columns: get(inspection, :columns) || []
           ),
         key_set when is_map(key_set) <-
           find_key_set(importer.runtime_contract.key_sets, normalized.match.key_set) do
      rows =
        (get(inspection, :rows) || [])
        |> Enum.filter(fn row ->
          number = get(row, :row_number)

          number >= normalized.rows.start and
            (is_nil(normalized.rows[:end]) or number <= normalized.rows.end)
        end)
        |> Enum.map(&preview_row(importer, &1, normalized, key_set, trusted, resolver))

      {:ok, %{configuration: normalized, rows: rows, returned: length(rows)}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      false ->
        invalid(
          :invalid_import_host,
          "preview requires a three-arity key_resolver and trusted values map"
        )

      _ ->
        invalid(:import_key_set_not_found, "Published import key set is unavailable")
    end
  end

  defp do_inspect_csv(importer, content, delimiter, header?) do
    with {:ok, records} <- parse_delimited(content, delimiter),
         :ok <- non_empty(records),
         :ok <- row_bounds(importer, records, header?) do
      {headers, data} =
        if header? do
          [first | rest] = records
          {first.values, rest}
        else
          width = records |> hd() |> Map.fetch!(:values) |> length()
          {Enum.map(1..width, &"Column #{&1}"), records}
        end

      columns = columns(headers)

      rows =
        data
        |> Enum.with_index(1)
        |> Enum.map(fn {record, index} ->
          values =
            Map.new(columns, fn column ->
              {column.id, Enum.at(record.values, column.ordinal - 1)}
            end)

          %{row_number: index, physical_line: record.physical_line, values: values}
        end)

      {:ok,
       %{
         format: if(delimiter == "\t", do: "tsv", else: "csv"),
         delimiter: delimiter,
         header: header?,
         sha256: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower),
         columns: columns,
         rows: rows,
         sample_rows: Enum.take(rows, importer.max_sample_rows),
         row_count: length(rows)
       }}
    end
  end

  defp columns(headers) do
    {columns, _counts} =
      headers
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{}}, fn {header, ordinal}, {acc, counts} ->
        header = if is_nil(header), do: "", else: to_string(header)
        key = String.downcase(header)
        occurrence = Map.get(counts, key, 0) + 1

        label =
          if header == "",
            do: "Column #{ordinal}",
            else: header <> if(occurrence > 1, do: " ##{occurrence}", else: "")

        {acc ++
           [
             %{
               id: "c#{ordinal}",
               ordinal: ordinal,
               header: header,
               occurrence: occurrence,
               label: label
             }
           ], Map.put(counts, key, occurrence)}
      end)

    columns
  end

  defp parse_delimited(content, delimiter) do
    content = String.trim_leading(content, <<0xEF, 0xBB, 0xBF>>)

    if content == "",
      do: {:ok, []},
      else: parse_chars(content, delimiter, false, false, "", [], [], 1, 1)
  rescue
    _ -> invalid(:import_parser_error, "CSV parsing failed")
  end

  defp parse_chars(<<>>, _delimiter, true, _quoted, _field, _row, _records, line, _start),
    do:
      invalid(:import_parser_error, "CSV parsing failed", %{
        physical_line: line,
        reason: :unclosed_quote
      })

  defp parse_chars(<<>>, _delimiter, false, _quoted, field, row, records, _line, start) do
    record = %{values: row ++ [field], physical_line: start}
    {:ok, if(record.values == [""] and records != [], do: records, else: records ++ [record])}
  end

  defp parse_chars(binary, delimiter, in_quotes, quoted, field, row, records, line, start) do
    {char, rest} = String.next_grapheme(binary)

    cond do
      in_quotes and char == "\"" and String.starts_with?(rest, "\"") ->
        parse_chars(
          String.slice(rest, 1..-1//1),
          delimiter,
          true,
          true,
          field <> "\"",
          row,
          records,
          line,
          start
        )

      in_quotes and char == "\"" ->
        parse_chars(rest, delimiter, false, true, field, row, records, line, start)

      in_quotes ->
        parse_chars(
          rest,
          delimiter,
          true,
          quoted,
          field <> char,
          row,
          records,
          line + if(char == "\n", do: 1, else: 0),
          start
        )

      char == "\"" and field == "" and not quoted ->
        parse_chars(rest, delimiter, true, true, field, row, records, line, start)

      char == delimiter ->
        parse_chars(rest, delimiter, false, false, "", row ++ [field], records, line, start)

      char in ["\n", "\r"] ->
        rest =
          if char == "\r" and String.starts_with?(rest, "\n"),
            do: String.slice(rest, 1..-1//1),
            else: rest

        record = %{values: row ++ [field], physical_line: start}

        parse_chars(
          rest,
          delimiter,
          false,
          false,
          "",
          [],
          records ++ [record],
          line + 1,
          line + 1
        )

      quoted ->
        invalid(:import_parser_error, "CSV parsing failed", %{
          physical_line: line,
          reason: :characters_after_quote
        })

      true ->
        parse_chars(rest, delimiter, false, false, field <> char, row, records, line, start)
    end
  end

  defp normalize_mappings(importer, mappings, columns) when is_list(mappings) do
    column_ids =
      MapSet.new(
        for column <- columns, is_map(column), id = get(column, :id), is_binary(id), do: id
      )

    mappings
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn mapping, {:ok, acc, seen} ->
      with :ok <- object(mapping, :invalid_import_configuration, "import mapping must be a map"),
           :ok <- known(mapping, ~w(target source transforms blank_policy), "import mapping"),
           target when is_binary(target) <- id(get(mapping, :target)),
           field when is_map(field) <- fetch(importer.runtime_contract.fields, target),
           false <- MapSet.member?(seen, target),
           {:ok, source} <- normalize_source(get(mapping, :source), field, column_ids, target),
           {:ok, transforms} <-
             normalize_transforms(get(mapping, :transforms) || [], field, target),
           {:ok, blank_policy} <-
             normalize_blank(
               get(mapping, :blank_policy) || get(field, :blank_policy) || :omit,
               target
             ) do
        value = %{
          target: target,
          source: source,
          transforms: transforms,
          blank_policy: blank_policy
        }

        {:cont, {:ok, acc ++ [value], MapSet.put(seen, target)}}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        true ->
          {:halt, invalid(:invalid_import_configuration, "Import field is mapped more than once")}

        _ ->
          {:halt, invalid(:import_field_not_enabled, "Import field is not enabled")}
      end
    end)
    |> strip_seen()
  end

  defp normalize_mappings(_importer, _mappings, _columns),
    do: invalid(:invalid_import_configuration, "mappings must be a list")

  defp normalize_actions(importer, actions, columns) when is_list(actions) do
    column_ids =
      MapSet.new(
        for column <- columns, is_map(column), id = get(column, :id), is_binary(id), do: id
      )

    actions
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn configured, {:ok, acc, seen} ->
      with :ok <- object(configured, :invalid_import_configuration, "import action must be a map"),
           :ok <- known(configured, ~w(action inputs), "import action"),
           action when is_binary(action) <- id(get(configured, :action)),
           spec when is_map(spec) <- fetch(importer.runtime_contract.actions, action),
           false <- MapSet.member?(seen, action),
           inputs when is_map(inputs) <- get(configured, :inputs),
           {:ok, inputs} <-
             normalize_action_inputs(action, inputs, get(spec, :inputs) || %{}, column_ids),
           :ok <- required_action_inputs(action, inputs, get(spec, :inputs) || %{}) do
        {:cont, {:ok, acc ++ [%{action: action, inputs: inputs}], MapSet.put(seen, action)}}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        true ->
          {:halt,
           invalid(:invalid_import_configuration, "Import action is configured more than once")}

        _ ->
          {:halt, invalid(:import_action_not_enabled, "Import action is not enabled")}
      end
    end)
    |> strip_seen()
  end

  defp normalize_actions(_importer, _actions, _columns),
    do: invalid(:invalid_import_configuration, "actions must be a list")

  defp normalize_action_inputs(action, inputs, specs, columns) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn {name, mapping}, {:ok, acc} ->
      name = id(name)
      spec = fetch(specs, name)

      with true <- is_map(spec),
           :ok <-
             object(mapping, :invalid_import_configuration, "action input mapping must be a map"),
           :ok <- known(mapping, ~w(source transforms blank_policy), "action input mapping"),
           {:ok, source} <-
             normalize_source(get(mapping, :source), spec, columns, "#{action}.#{name}"),
           {:ok, transforms} <-
             normalize_transforms(get(mapping, :transforms) || [], spec, "#{action}.#{name}"),
           {:ok, blank} <-
             normalize_blank(
               get(mapping, :blank_policy) || get(spec, :blank_policy) || :omit,
               "#{action}.#{name}"
             ) do
        {:cont,
         {:ok, Map.put(acc, name, %{source: source, transforms: transforms, blank_policy: blank})}}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        _ ->
          {:halt,
           invalid(:import_action_input_not_enabled, "Action input is not enabled", %{
             action: action,
             input: name
           })}
      end
    end)
  end

  defp required_action_inputs(action, inputs, specs) do
    case Enum.find(specs, fn {name, spec} ->
           get(spec, :required) == true and not Map.has_key?(inputs, id(name))
         end) do
      nil ->
        :ok

      {name, _} ->
        invalid(:import_action_input_missing, "Action requires an input", %{
          action: action,
          input: id(name)
        })
    end
  end

  defp normalize_source(source, spec, columns, target) do
    with :ok <- object(source, :invalid_import_configuration, "import source must be a map"),
         :ok <- known(source, ~w(kind column_id value name), "import source"),
         kind when kind in @sources <- id(get(source, :kind)),
         true <- kind in Enum.map(get(spec, :sources) || [], &id/1) do
      case kind do
        "column" ->
          column_id = get(source, :column_id)

          if is_binary(column_id) and MapSet.member?(columns, column_id),
            do: {:ok, %{kind: kind, column_id: column_id}},
            else:
              invalid(:import_column_missing, "Import column is not present", %{target: target})

        "static" ->
          if present?(source, :value),
            do: {:ok, %{kind: kind, value: deep_copy(get(source, :value))}},
            else:
              invalid(:invalid_import_configuration, "Static import source requires value", %{
                target: target
              })

        "parameter" ->
          if id(get(source, :name)),
            do: {:ok, %{kind: kind, name: id(get(source, :name))}},
            else:
              invalid(:invalid_import_configuration, "Parameter import source requires name", %{
                target: target
              })

        "trusted" ->
          provider = id(get(spec, :trusted_provider))

          if provider,
            do: {:ok, %{kind: kind, name: provider}},
            else:
              invalid(:invalid_import_contract, "Trusted import source has no provider", %{
                target: target
              })
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> invalid(:import_source_not_allowed, "Import source is not allowed", %{target: target})
    end
  end

  defp normalize_transforms(values, spec, target) when is_list(values) do
    normalized = Enum.map(values, &id/1)
    allowed = Enum.map(get(spec, :transforms) || [], &id/1)

    if Enum.all?(normalized, &(&1 in @transforms and &1 in allowed)) and
         Enum.uniq(normalized) == normalized,
       do: {:ok, normalized},
       else:
         invalid(:import_transform_not_allowed, "Import transform is not allowed", %{
           target: target
         })
  end

  defp normalize_transforms(_, _spec, target),
    do: invalid(:invalid_import_configuration, "Transforms must be a list", %{target: target})

  defp normalize_blank(value, target) do
    value = id(value)

    if value in @blank_policies,
      do: {:ok, value},
      else: invalid(:invalid_import_configuration, "Invalid blank policy", %{target: target})
  end

  defp normalize_match(importer, match) when is_map(match) do
    with :ok <- known(match, ~w(key_set on_match on_missing), "import match") do
      key_set_id = id(get(match, :key_set))
      key_set = find_key_set(importer.runtime_contract.key_sets, key_set_id)

      if key_set do
        on_match = id(get(match, :on_match) || get(key_set, :default_on_match))
        on_missing = id(get(match, :on_missing) || get(key_set, :default_on_missing))
        allowed_match = Enum.map(get(key_set, :allowed_on_match), &id/1)
        allowed_missing = Enum.map(get(key_set, :allowed_on_missing), &id/1)

        if on_match in allowed_match and on_missing in allowed_missing,
          do: {:ok, %{key_set: key_set_id, on_match: on_match, on_missing: on_missing}},
          else: invalid(:invalid_import_configuration, "Import match decision is not allowed")
      else
        invalid(:import_key_set_not_found, "Import key set is not published", %{
          key_set: key_set_id
        })
      end
    end
  end

  defp normalize_match(_importer, _),
    do: invalid(:invalid_import_configuration, "match must be a map")

  defp normalize_rows(rows) when is_map(rows) do
    start = get(rows, :start) || 1
    finish = get(rows, :end)

    with :ok <- known(rows, ~w(start end), "import rows") do
      if is_integer(start) and start > 0 and
           (is_nil(finish) or (is_integer(finish) and finish >= start)),
         do: {:ok, maybe_put(%{start: start}, :end, finish)},
         else: invalid(:invalid_import_configuration, "Import row bounds are invalid")
    end
  end

  defp normalize_rows(_), do: invalid(:invalid_import_configuration, "rows must be a map")

  defp normalize_idempotency(importer, nil), do: normalize_idempotency(importer, %{})

  defp normalize_idempotency(importer, value) when is_map(value) do
    supported = get(importer.runtime_contract.idempotency, :supported) == true
    mode = id(get(value, :mode) || :none)
    duplicate = id(get(value, :on_duplicate) || :skip)

    with :ok <- known(value, ~w(mode on_duplicate), "import idempotency") do
      cond do
        mode not in ~w(none source_row) ->
          invalid(:invalid_import_configuration, "idempotency mode must be none or source_row")

        mode == "source_row" and not supported ->
          invalid(
            :import_idempotency_not_supported,
            "This importer does not support source-row idempotency"
          )

        duplicate not in ~w(skip error) ->
          invalid(:invalid_import_configuration, "idempotency on_duplicate must be skip or error")

        true ->
          {:ok, %{mode: mode, on_duplicate: duplicate}}
      end
    end
  end

  defp normalize_idempotency(_importer, _),
    do: invalid(:invalid_import_configuration, "idempotency must be a map")

  defp normalize_errors(nil), do: {:ok, %{mode: "continue"}}

  defp normalize_errors(value) when is_map(value) do
    mode = id(get(value, :mode) || :continue)

    with :ok <- known(value, ["mode"], "import errors") do
      if mode in ~w(continue fail_fast),
        do: {:ok, %{mode: mode}},
        else: invalid(:invalid_import_configuration, "error mode must be continue or fail_fast")
    end
  end

  defp normalize_errors(_), do: invalid(:invalid_import_configuration, "errors must be a map")

  defp preview_row(importer, row, configuration, key_set, trusted, resolver) do
    {assignments, match_values, write_on, errors} =
      resolve_field_mappings(importer, row, configuration, trusted)

    {pending_actions, errors} =
      resolve_action_mappings(importer, row, configuration, trusted, errors)

    key =
      Map.new(get(key_set, :fields), fn field ->
        field = id(field)
        {field, Map.get(assignments, field, Map.get(match_values, field))}
      end)

    errors =
      Enum.reduce(key, errors, fn {field, value}, acc ->
        if blank?(value),
          do: [row_error(:import_key_incomplete, "A key value is required", field: field) | acc],
          else: acc
      end)

    {match_result, errors} = resolve_match(resolver, key, key_set, row, errors)
    matches = get(match_result, :matches) || []

    {decision, target, errors} =
      cond do
        errors != [] ->
          {"error", nil, errors}

        length(matches) > 1 ->
          {"error", nil,
           [
             row_error(:import_key_ambiguous, "Key matches more than one record",
               details: %{count: length(matches)}
             )
             | errors
           ]}

        length(matches) == 1 ->
          {configuration.match.on_match, hd(matches), errors}

        true ->
          {configuration.match.on_missing, nil, errors}
      end

    assignments =
      if decision in ~w(insert update),
        do:
          Map.filter(assignments, fn {field, _} -> decision in Map.get(write_on, field, []) end),
        else: assignments

    {actions, errors} = materialize_actions(importer, decision, target, pending_actions, errors)
    errors = required_insert_fields(importer, decision, assignments, errors)
    {write, errors} = write_intent(importer, decision, target, assignments, errors)

    errors =
      if decision == "update" and is_nil(write) and actions == [] and errors == [],
        do: [
          row_error(
            :import_no_operation,
            "The matched row has no governed write or action to apply"
          )
        ],
        else: errors

    decision = if errors == [], do: decision, else: "error"

    %{
      row_number: get(row, :row_number),
      physical_line: get(row, :physical_line),
      source: deep_copy(get(row, :values) || %{}),
      assignments: assignments,
      match_values: match_values,
      key: key,
      decision: decision,
      errors: Enum.reverse(errors)
    }
    |> maybe_put(:target, target)
    |> maybe_put(:write, if(errors == [], do: write))
    |> maybe_put(:actions, if(errors == [] and actions != [], do: actions))
  end

  defp resolve_field_mappings(importer, row, configuration, trusted) do
    Enum.reduce(configuration.mappings, {%{}, %{}, %{}, []}, fn mapping,
                                                                {assignments, matches, write_on,
                                                                 errors} ->
      spec = fetch(importer.runtime_contract.fields, mapping.target)

      {present, value} =
        resolve_value(mapping.source, get(row, :values) || %{}, configuration.parameters, trusted)

      {present, value, error} = transform_value(present, value, mapping.transforms)

      errors =
        if error,
          do: [
            row_error(:import_transform_failed, "Import transform failed", field: mapping.target)
            | errors
          ],
          else: errors

      {present, value, errors} =
        blank_value(present, value, mapping.blank_policy, mapping.target, errors)

      match_only? = get(spec, :match_only) == true

      cond do
        error or not present ->
          {assignments, matches, write_on, errors}

        match_only? ->
          {assignments, Map.put(matches, mapping.target, value), write_on, errors}

        true ->
          {Map.put(assignments, mapping.target, value), matches,
           Map.put(write_on, mapping.target, Enum.map(get(spec, :write_on) || [], &id/1)), errors}
      end
    end)
  end

  defp resolve_action_mappings(importer, row, configuration, trusted, errors) do
    Enum.reduce(configuration.actions, {[], errors}, fn configured, {actions, errors} ->
      specs = get(fetch(importer.runtime_contract.actions, configured.action), :inputs) || %{}

      {inputs, errors} =
        Enum.reduce(configured.inputs, {%{}, errors}, fn {name, mapping}, {inputs, errors} ->
          spec = fetch(specs, name)

          {present, value} =
            resolve_value(
              mapping.source,
              get(row, :values) || %{},
              configuration.parameters,
              trusted
            )

          {present, value, error} = transform_value(present, value, mapping.transforms)

          errors =
            if error,
              do: [
                row_error(:import_transform_failed, "Action input transform failed",
                  action: configured.action,
                  input: name
                )
                | errors
              ],
              else: errors

          {present, value, errors} =
            blank_value(present, value, mapping.blank_policy, name, errors)

          invalid_date =
            present and id(get(spec, :type)) == "date" and
              match?({:error, _}, Date.from_iso8601(to_string(value)))

          errors =
            if invalid_date,
              do: [
                row_error(:import_invalid_action_input, "An action date must be an ISO date",
                  action: configured.action,
                  input: name
                )
                | errors
              ],
              else: errors

          if present and not invalid_date and not error,
            do: {Map.put(inputs, name, value), errors},
            else: {inputs, errors}
        end)

      {actions ++ [%{action: configured.action, inputs: inputs}], errors}
    end)
  end

  defp resolve_match(_resolver, _key, _key_set, _row, errors) when errors != [],
    do: {%{matches: []}, errors}

  defp resolve_match(resolver, key, key_set, row, errors) do
    case resolver.(key, key_set, row) do
      %{matches: matches} = result when is_list(matches) ->
        {result, errors}

      %{"matches" => matches} = result when is_list(matches) ->
        {result, errors}

      _ ->
        {%{matches: []},
         [row_error(:invalid_import_host, "key resolver returned an invalid result") | errors]}
    end
  rescue
    _ -> {%{matches: []}, [row_error(:invalid_import_host, "key resolver failed") | errors]}
  end

  defp materialize_actions(_importer, _decision, _target, [], errors), do: {[], errors}

  defp materialize_actions(_importer, "insert", _target, _pending, errors),
    do:
      {[],
       [
         row_error(
           :import_action_requires_match,
           "A governed action can only be applied to an existing matched record"
         )
         | errors
       ]}

  defp materialize_actions(importer, "update", target, pending, errors) do
    primary = id(get(importer.domain.source, :primary_key) || :id)
    target_id = fetch(target, primary)

    if is_nil(target_id),
      do:
        {[],
         [
           row_error(
             :invalid_import_host,
             "Matched record has no primary key for action execution"
           )
           | errors
         ]},
      else: {Enum.map(pending, &Map.put(&1, :target, %{ids: [target_id]})), errors}
  end

  defp materialize_actions(_importer, _decision, _target, _pending, errors), do: {[], errors}

  defp required_insert_fields(_importer, decision, _assignments, errors)
       when decision != "insert", do: errors

  defp required_insert_fields(importer, "insert", assignments, errors) do
    fields = get(importer.domain.writes, :fields) || %{}

    Enum.reduce(fields, errors, fn {field, spec}, acc ->
      field = id(field)

      if get(spec, :required) == true and blank?(Map.get(assignments, field)),
        do: [row_error(:import_required_value_missing, "Required for insert", field: field) | acc],
        else: acc
    end)
  end

  defp write_intent(_importer, decision, _target, _assignments, errors)
       when errors != [] or decision not in ~w(insert update), do: {nil, errors}

  defp write_intent(_importer, _decision, _target, assignments, errors)
       when map_size(assignments) == 0, do: {nil, errors}

  defp write_intent(importer, "insert", _target, assignments, errors) do
    primary = id(get(importer.domain.source, :primary_key) || :id)

    {%{operation: "insert", assignments: assignments, expected_count: 1, returning: [primary]},
     errors}
  end

  defp write_intent(importer, "update", target, assignments, errors) do
    primary = id(get(importer.domain.source, :primary_key) || :id)
    target_id = fetch(target, primary)

    if is_nil(target_id),
      do: {nil, [row_error(:invalid_import_host, "Matched record has no primary key") | errors]},
      else:
        {%{
           operation: "update",
           assignments: assignments,
           filters: [%{field: primary, op: "eq", value: target_id}],
           expected_count: 1,
           returning: [primary]
         }, errors}
  end

  defp resolve_value(%{kind: "column", column_id: id}, values, _parameters, _trusted),
    do: {present?(values, id), fetch(values, id)}

  defp resolve_value(%{kind: "static", value: value}, _values, _parameters, _trusted),
    do: {true, value}

  defp resolve_value(%{kind: "parameter", name: name}, _values, parameters, _trusted),
    do: {present?(parameters, name), fetch(parameters, name)}

  defp resolve_value(%{kind: "trusted", name: name}, _values, _parameters, trusted),
    do: {present?(trusted, name), fetch(trusted, name)}

  defp transform_value(false, value, _), do: {false, value, false}

  defp transform_value(true, value, transforms) do
    result =
      Enum.reduce(transforms, value, fn
        "trim", value when is_binary(value) ->
          String.trim(value)

        "uppercase", value when is_binary(value) ->
          String.upcase(value)

        "lowercase", value when is_binary(value) ->
          String.downcase(value)

        "normalize_whitespace", value when is_binary(value) ->
          String.replace(value, ~r/\s+/u, " ")

        "empty_to_null", value when is_binary(value) ->
          if(value == "", do: nil, else: value)

        _transform, value ->
          value
      end)

    {true, result, false}
  rescue
    _ -> {false, value, true}
  end

  defp blank_value(present, value, policy, target, errors) do
    if not present or blank?(value) do
      case policy do
        "omit" ->
          {false, nil, errors}

        "empty" ->
          {true, "", errors}

        "null" ->
          {true, nil, errors}

        "error" ->
          {false, nil,
           [
             row_error(:import_required_value_missing, "A value is required", field: target)
             | errors
           ]}
      end
    else
      {true, value, errors}
    end
  end

  defp runtime_contract(normalized, imports) do
    projected = normalized |> Domain.project(:import) |> Map.fetch!(:imports)

    fields = merge_trusted(projected.fields, get(imports, :fields) || %{})

    actions =
      Map.new(projected.actions || %{}, fn {action, spec} ->
        raw_inputs = get(fetch(get(imports, :actions) || %{}, action), :inputs) || %{}
        {action, Map.put(spec, :inputs, merge_trusted(spec.inputs || %{}, raw_inputs))}
      end)

    %{
      fields: fields,
      actions: actions,
      key_sets: get(projected, :key_sets) || [],
      idempotency: get(projected, :idempotency) || %{supported: false}
    }
  end

  defp merge_trusted(projected, raw) do
    Map.new(projected, fn {key, spec} ->
      provider = get(fetch(raw, key), :trusted_provider)

      {id(key),
       maybe_put(
         Map.new(spec, fn {k, v} -> {normalize_key(k), v} end),
         :trusted_provider,
         id(provider)
       )}
    end)
  end

  defp limits(opts) do
    values =
      for key <- [:max_columns, :max_rows, :max_sample_rows],
          into: %{},
          do: {key, Keyword.get(opts, key, default_limit(key))}

    if Enum.all?(values, fn {_k, v} -> is_integer(v) and v > 0 end),
      do: {:ok, Map.to_list(values)},
      else: invalid(:invalid_importer, "importer limits must be positive integers")
  end

  defp default_limit(:max_columns), do: 200
  defp default_limit(:max_rows), do: 50_000
  defp default_limit(:max_sample_rows), do: 25

  defp row_bounds(importer, records, header?) do
    data_count = length(records) - if(header?, do: 1, else: 0)
    width = records |> Enum.map(&length(&1.values)) |> Enum.max(fn -> 0 end)

    cond do
      width > importer.max_columns ->
        invalid(:import_column_limit_exceeded, "Import file has too many columns", %{
          maximum: importer.max_columns,
          columns: width
        })

      data_count > importer.max_rows ->
        invalid(:import_row_limit_exceeded, "Import file has too many rows", %{
          maximum: importer.max_rows
        })

      true ->
        :ok
    end
  end

  defp non_empty([]), do: invalid(:import_file_empty, "Import file has no rows")
  defp non_empty(_), do: :ok
  defp fingerprint_matches(_importer, nil), do: :ok

  defp fingerprint_matches(importer, value),
    do:
      equal(
        value,
        domain_fingerprint(importer),
        :import_domain_changed,
        "Import configuration does not match the current domain"
      )

  defp equal(left, right, _code, _message) when left == right, do: :ok
  defp equal(_left, _right, code, message), do: invalid(code, message)
  defp object(value, _code, _message) when is_map(value), do: :ok
  defp object(_value, code, message), do: invalid(code, message)
  defp optional_string(nil, _message), do: :ok
  defp optional_string(value, _message) when is_binary(value) and value != "", do: :ok
  defp optional_string(_value, message), do: invalid(:invalid_import_configuration, message)

  defp known(value, allowed, label) do
    unknown = Enum.reject(Map.keys(value), &(to_string(&1) in allowed))

    if unknown == [],
      do: :ok,
      else:
        invalid(:invalid_import_configuration, "#{label} has unknown properties", %{
          properties: unknown
        })
  end

  defp find_key_set(values, id), do: Enum.find(values || [], &(id(get(&1, :id)) == id))
  defp strip_seen({:ok, value, _seen}), do: {:ok, value}
  defp strip_seen(error), do: error

  defp invalid(code, message, details \\ %{}),
    do: {:error, Error.validation_error(message, Map.put(details, :code, code))}

  defp row_error(code, message, details \\ []),
    do: details |> Map.new() |> Map.merge(%{code: code, message: message})

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp fingerprint(value),
    do:
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])),
          case: :lower
        )

  defp deep_copy(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)
  defp normalize_key(key), do: key
  defp id(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp id(value) when is_binary(value) and value != "", do: value
  defp id(_), do: nil
  defp get(value, key) when is_map(value), do: Map.get(value, key, Map.get(value, to_string(key)))
  defp get(_, _), do: nil

  defp fetch(value, key) when is_map(value),
    do:
      Enum.find_value(value, fn {candidate, entry} -> if id(candidate) == id(key), do: entry end)

  defp fetch(_, _), do: nil

  defp present?(value, key) when is_map(value),
    do: Map.has_key?(value, key) or Map.has_key?(value, to_string(key))

  defp present?(_, _), do: false
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
