defmodule SelectoUpdato.QueryEnforcement do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain.WriteContract
  alias SelectoUpdato.{Error, Operation}
  alias SelectoUpdato.ColumnCatalog
  alias SelectoUpdato.QueryEnforcement.Scalar

  @comparison_operators [:eq, :neq, :gt, :gte, :lt, :lte]
  @deferrable [:not_evaluable_in_process, :untyped_candidate_value, :untyped_predicate_value]

  @spec capture(Selecto.t()) :: map()
  def capture(%Selecto{} = selecto, opts \\ []) do
    domain = selecto.domain || %{}
    source = map_value(domain, :source) || %{}

    %{
      filters: Selecto.query_filters(selecto, Keyword.take(opts, [:include_engine_tenant])),
      scope_filters: scope_filters(selecto, opts),
      storage_backend: Selecto.AdapterSupport.adapter_name(selecto.adapter),
      source: %{
        domain_name: map_value(domain, :name),
        relation: relation(source),
        primary_key: primary_key(source),
        fingerprint: Selecto.Domain.domain_fingerprint(domain)
      },
      applied_query_library: Selecto.applied_query_library(selecto)
    }
  end

  # The captured filters a host may install as its scope, by provenance: the
  # engine tenant (unless excluded), the query's own required filters
  # (Selecto.Tenant.require_tenant_filter/2 and friends) and its filters.
  # The domain's required_filters are left out: they are plain required
  # filters, which bound only the pre-image of an UPDATE (TW-09 decision).
  # They still guard the write through `filters`.
  defp scope_filters(selecto, opts) do
    set = Map.get(selecto, :set) || %{}

    engine =
      if Keyword.get(opts, :include_engine_tenant, true),
        do: Selecto.Tenant.engine_filters(selecto),
        else: []

    # The configured query starts its required filters with the domain's
    # (Selecto.configure/3); the host's own required filters follow them.
    domain_required = List.wrap(map_value(Map.get(selecto, :domain) || %{}, :required_filters))
    required = List.wrap(Map.get(set, :required_filters))

    host_required =
      if Enum.take(required, length(domain_required)) == domain_required,
        do: Enum.drop(required, length(domain_required)),
        else: required

    (engine ++
       host_required ++
       List.wrap(Map.get(set, :filtered)) ++ List.wrap(Map.get(set, :post_retarget_filters)))
    |> Enum.uniq()
  end

  @spec compile(Operation.t(), WriteContract.t()) :: {:ok, term() | nil} | {:error, Error.t()}
  def compile(%Operation{} = operation, %WriteContract{} = contract) do
    with {:ok, required} <- required_predicate(operation.domain, contract),
         {:ok, captured} <- captured_predicate(operation, contract),
         predicate = combine_predicates(required, captured),
         :ok <- supported_operation(operation, predicate) do
      {:ok, predicate}
    end
  end

  defp required_predicate(domain, contract) do
    case map_value(domain, :required_filters) || [] do
      [] ->
        {:ok, nil}

      filters when is_list(filters) ->
        compile_root_filters(filters, contract, field_types(domain))

      filters ->
        invalid_filter(filters)
    end
  end

  defp captured_predicate(%Operation{query_enforcement: nil}, _contract), do: {:ok, nil}

  defp captured_predicate(%Operation{query_enforcement: evidence} = operation, contract)
       when is_map(evidence) do
    filters = Map.get(evidence, :filters, [])

    with :ok <- validate_source(evidence, operation.domain, contract),
         :ok <- require_filters(filters) do
      compile_root_filters(filters, contract, field_types(operation.domain))
    end
  end

  defp captured_predicate(_operation, _contract) do
    error(
      :invalid_query_enforcement,
      "query enforcement evidence must be captured from a Selecto query"
    )
  end

  defp compile_root_filters(filters, contract, types) do
    with {:ok, predicate} <- compile_filter_group(filters, types),
         :ok <- validate_fields(predicate, contract),
         do: {:ok, predicate}
  end

  defp combine_predicates(nil, captured), do: captured
  defp combine_predicates(required, nil), do: required
  defp combine_predicates(predicate, predicate), do: predicate

  defp combine_predicates(required, captured) do
    {:and, Enum.uniq(conjuncts(required) ++ conjuncts(captured))}
  end

  defp conjuncts({:and, predicates}), do: predicates
  defp conjuncts(predicate), do: [predicate]

  defp supported_operation(%Operation{type: :upsert}, predicate) when not is_nil(predicate) do
    error(
      :query_enforcement_unsupported_operation,
      "required query predicates are not yet supported for upsert operations",
      %{operation: :upsert}
    )
  end

  defp supported_operation(_operation, _predicate), do: :ok

  # Execution overwrites this option with the configured adapter's backend.
  # Captured evidence remains the fallback for standalone portable compilation.
  def sqlite_insert_admission?(%Operation{type: :insert} = operation, opts) do
    captured = operation.query_enforcement || %{}
    Keyword.get(opts, :storage_backend, Map.get(captured, :storage_backend)) == :sqlite
  end

  def sqlite_insert_admission?(_operation, _opts), do: false

  @doc false
  # SQLite checks the candidate under the stored column's type before the
  # INSERT instead of the portable candidate model. MySQL and MariaDB keep the
  # portable check (it also refuses at compile and preview time) and then
  # re-read the stored row under the predicate inside the write transaction,
  # so column types, DECIMAL rounding, collations and triggers decide too.
  def storage_insert_admission_backend(%Operation{type: :insert} = operation, opts) do
    captured = operation.query_enforcement || %{}

    case Keyword.get(opts, :storage_backend, Map.get(captured, :storage_backend)) do
      backend when backend in [:sqlite, :mysql, :mariadb] -> backend
      _ -> nil
    end
  end

  def storage_insert_admission_backend(_operation, _opts), do: nil

  @spec validate_insert_candidate(Operation.t(), [map()], term() | nil, keyword()) ::
          :ok | {:error, Error.t()}
  def validate_insert_candidate(operation, assignments, predicate, opts \\ [])

  def validate_insert_candidate(
        %Operation{type: :insert} = operation,
        assignments,
        predicate,
        opts
      )
      when not is_nil(predicate) do
    if sqlite_insert_admission?(operation, opts) do
      :ok
    else
      validate_candidate(operation, assignments, predicate, opts)
    end
  end

  def validate_insert_candidate(%Operation{}, _assignments, _predicate, _opts), do: :ok

  # The portable candidate check compares by each field's declared type
  # (query_enforced_scalar v2, SelectoUpdato.QueryEnforcement.Scalar). Only
  # `true` admits. A comparison the evaluator cannot decide in process defers
  # to verified storage where the backend has one (MySQL and MariaDB re-read
  # the stored row under the predicate inside the write transaction; SQLite
  # never reaches this check); otherwise it is refused as not evaluable.
  defp validate_candidate(operation, assignments, predicate, opts) do
    candidate =
      Map.new(assignments, fn
        %{field: field, value: {:literal, value}} -> {Core.field_id(field), value}
      end)

    columns = candidate_columns(operation, opts)

    case evaluate_candidate(predicate, candidate, columns) do
      {:ok, true} ->
        :ok

      {:ok, result} when result in [false, :unknown] ->
        error(
          :query_rule_violation,
          "insert candidate does not satisfy the required query predicates",
          %{operation: :insert}
        )

      {:error, details} ->
        # An absent field or a column operand is refused before any DML; a
        # comparison only undecidable in process defers to verified storage.
        if Map.get(details, :reason) in @deferrable and
             storage_insert_admission_backend(operation, opts) in [:mysql, :mariadb] do
          :ok
        else
          error(
            :query_rule_not_evaluable,
            "insert candidate cannot be evaluated against the required query predicates",
            Map.put(details, :operation, :insert)
          )
        end
    end
  end

  @doc false
  # The scalar column descriptors of the operation's root fields. A column
  # whose type the catalog reported (`opts[:column_metadata]`, read by the
  # executor before any write transaction) is `:verified`; a field known only
  # by its declared domain type is `:unverified` and decides nothing in
  # process.
  def candidate_columns(%Operation{domain: domain} = operation, opts) do
    backend =
      case Keyword.get(
             opts,
             :storage_backend,
             Map.get(operation.query_enforcement || %{}, :storage_backend)
           ) do
        backend when backend in [:mysql, :mariadb] -> :mysql_family
        _ -> :other
      end

    source = map_value(domain, :source) || %{}

    table = to_string(relation(source) || "")

    catalog =
      case host_catalog(Keyword.get(opts, :column_metadata), table) do
        {:ok, columns} -> columns
        :error -> provided_catalog(Keyword.get(opts, :column_metadata_provider), table)
      end
      |> ColumnCatalog.normalize_columns()

    declared = column_types(domain)

    (Map.keys(declared) ++ Map.keys(catalog))
    |> Enum.uniq()
    |> Map.new(fn field ->
      case Map.get(catalog, field) do
        %{type: type, trust: trust, deterministic: deterministic} when is_binary(type) ->
          {field,
           Scalar.column(type, trust: trust, backend: backend, deterministic: deterministic)}

        _missing_or_malformed ->
          {field, Scalar.column(Map.get(declared, field), trust: :unverified, backend: backend)}
      end
    end)
  end

  @spec metadata(Operation.t(), term() | nil) :: map() | nil
  def metadata(%Operation{query_enforcement: nil}, _predicate), do: nil

  def metadata(%Operation{query_enforcement: evidence}, predicate) when is_map(evidence) do
    source = Map.get(evidence, :source, %{})

    %{
      source: Map.take(source, [:domain_name, :relation, :primary_key, :fingerprint]),
      applied_query_library: Map.get(evidence, :applied_query_library, %{}),
      predicate_fingerprint: fingerprint(predicate)
    }
  end

  defp validate_source(evidence, domain, contract) do
    query_source = Map.get(evidence, :source, %{})

    write_source = %{
      domain_name: map_value(domain, :name),
      relation: relation(contract.source),
      primary_key: primary_key(contract.source),
      fingerprint: contract.fingerprint
    }

    mismatches =
      [:domain_name, :relation, :primary_key, :fingerprint]
      |> Enum.filter(fn key -> incompatible?(key, query_source[key], write_source[key]) end)

    case mismatches do
      [] ->
        :ok

      fields ->
        error(
          :query_source_mismatch,
          "enforced query and write operation must target the same domain source",
          %{
            fields: fields,
            query_source: query_source,
            write_source: write_source
          }
        )
    end
  end

  defp incompatible?(:domain_name, nil, _right), do: false
  defp incompatible?(:domain_name, _left, nil), do: false
  defp incompatible?(:fingerprint, nil, _right), do: false
  defp incompatible?(:fingerprint, _left, nil), do: false

  defp incompatible?(_key, left, right),
    do: normalized_identity(left) != normalized_identity(right)

  defp normalized_identity(value) when is_atom(value), do: Atom.to_string(value)
  defp normalized_identity(value), do: value

  defp require_filters(filters) when is_list(filters) and filters != [], do: :ok

  defp require_filters(_filters) do
    error(
      :query_enforcement_requires_filter,
      "an enforced query must contain at least one predicate"
    )
  end

  @doc false
  # Compiles host-installed filters (a trusted context's required filters, a
  # host-scope query's filters) into one portable predicate, or nil when
  # there are none.
  # `domain` gives the fields' declared types: a filter compiles as the read
  # compiles it (BETWEEN on a date-like field is half-open, `>= a AND < b`).
  @spec compile_scope_filters([term()], map() | nil) :: {:ok, term() | nil} | {:error, Error.t()}
  def compile_scope_filters(filters, domain \\ nil)
  def compile_scope_filters([], _domain), do: {:ok, nil}

  def compile_scope_filters(filters, domain) when is_list(filters),
    do: compile_filter_group(filters, field_types(domain))

  # The declared columns of a domain's source, by field name, with the
  # domain's top-level `columns` settings (presentation_type, datetime and
  # epoch storage) merged over them, as Selecto's read configures a column.
  defp field_types(domain) do
    source = domain |> map_value(:source) |> map_value(:columns)
    overrides = map_value(domain, :columns)

    source
    |> by_name()
    |> Map.merge(by_name(overrides), fn _field, base, override -> Map.merge(base, override) end)
  end

  defp by_name(columns) when is_map(columns) do
    for {field, conf} <- columns, is_map(conf), into: %{}, do: {to_string(field), conf}
  end

  defp by_name(_columns), do: %{}

  # Selecto's read compiles BETWEEN on a date-like field half-open
  # (Where.plain_regular_between: `>= a AND < b`), other fields closed.
  defp between_upper(types, field) do
    conf = Map.get(types, to_string(Core.field_id(field)))

    if is_map(conf) and Selecto.Temporal.date_like_type(conf) != nil, do: :lt, else: :lte
  end

  defp compile_filter_group(filters, types) when is_list(filters) and filters != [] do
    with {:ok, predicates} <- compile_filter_list(filters, types) do
      case predicates do
        [predicate] -> {:ok, predicate}
        predicates -> {:ok, {:and, predicates}}
      end
    end
  end

  defp compile_filter({:and, filters}, types) when is_list(filters) and filters != [],
    do: compile_boolean(:and, filters, types)

  defp compile_filter({:or, filters}, types) when is_list(filters) and filters != [],
    do: compile_boolean(:or, filters, types)

  defp compile_filter({operator, filters}, _types)
       when operator in [:and, :or] and is_list(filters),
       do: invalid_filter({operator, filters})

  defp compile_filter({:not, filter}, types) do
    with {:ok, predicate} <- compile_filter(filter, types), do: {:ok, {:not, predicate}}
  end

  defp compile_filter({field, nil}, _types) when is_atom(field) or is_binary(field),
    do: {:ok, {:is_null, {:field, Core.field_id(field)}}}

  defp compile_filter({field, value}, _types)
       when (is_atom(field) or is_binary(field)) and value in [:not_null, :not_nil],
       do: {:ok, {:not_null, {:field, Core.field_id(field)}}}

  defp compile_filter({field, {:ref, _reference}} = filter, _types)
       when is_atom(field) or is_binary(field),
       do: not_a_value(filter)

  defp compile_filter({field, {:in, values}}, _types)
       when (is_atom(field) or is_binary(field)) and is_list(values) and values != [] do
    compile_in(field, values)
  end

  defp compile_filter({field, {:not_in, values}}, _types)
       when (is_atom(field) or is_binary(field)) and is_list(values) and values != [] do
    with {:ok, predicate} <- compile_in(field, values), do: {:ok, {:not, predicate}}
  end

  defp compile_filter({field, {:between, minimum, maximum}}, types)
       when is_atom(field) or is_binary(field) do
    compile_boolean(
      :and,
      [{field, {:gte, minimum}}, {field, {between_upper(types, field), maximum}}],
      types
    )
  end

  defp compile_filter({field, {operator, value}}, _types)
       when (is_atom(field) or is_binary(field)) and
              operator in [:eq, :ne, :neq, :gt, :gte, :lt, :lte] do
    compile_comparison(field, operator, value)
  end

  # A string or symbol comparator ("!=", "<>", "=", ">=", ...) compiles like
  # its atom (:neq, :eq, :gte, ...), as Selecto's own filter builder accepts it.
  defp compile_filter({field, {operator, value}} = filter, _types)
       when (is_atom(field) or is_binary(field)) and (is_binary(operator) or is_atom(operator)) do
    case normalize_comparator(operator) do
      {:ok, comparator} -> compile_comparison(field, comparator, value)
      :error -> invalid_filter(filter)
    end
  end

  defp compile_filter({field, operator_expression}, _types)
       when (is_atom(field) or is_binary(field)) and is_tuple(operator_expression),
       do: invalid_filter({field, operator_expression})

  defp compile_filter({operator, field, value}, _types)
       when operator in [:eq, :ne, :neq, :gt, :gte, :lt, :lte] and
              (is_atom(field) or is_binary(field)) do
    compile_comparison(field, operator, value)
  end

  defp compile_filter({field, operator, values}, _types)
       when (is_atom(field) or is_binary(field)) and operator in [:in, "in"] and
              is_list(values) and values != [] do
    compile_in(field, values)
  end

  defp compile_filter({field, operator, value}, _types)
       when is_atom(field) or is_binary(field) do
    case normalize_comparator(operator) do
      {:ok, comparator} -> compile_comparison(field, comparator, value)
      :error -> invalid_filter({field, operator, value})
    end
  end

  defp compile_filter({field, values}, _types)
       when (is_atom(field) or is_binary(field)) and is_list(values) and values != [] do
    compile_in(field, values)
  end

  defp compile_filter({field, value}, _types) when is_atom(field) or is_binary(field),
    do: compile_comparison(field, :eq, value)

  defp compile_filter(filter, _types), do: invalid_filter(filter)

  defp compile_boolean(operator, filters, types) do
    with {:ok, predicates} <- compile_filter_list(filters, types),
         do: {:ok, {operator, predicates}}
  end

  defp compile_filter_list(filters, types) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, predicates} ->
      case compile_filter(filter, types) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | predicates]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, predicates} -> {:ok, Enum.reverse(predicates)}
      error -> error
    end
  end

  defp compile_in(field, values) do
    cond do
      Enum.any?(values, &is_nil/1) -> invalid_filter({field, {:in, values}})
      Enum.any?(values, &is_tuple/1) -> not_a_value({field, {:in, values}})
      true -> {:ok, {:in, {:field, Core.field_id(field)}, Enum.map(values, &{:literal, &1})}}
    end
  end

  defp compile_comparison(field, operator, nil) when operator in [:ne, :neq],
    do: {:ok, {:not_null, {:field, Core.field_id(field)}}}

  defp compile_comparison(field, :eq, nil),
    do: {:ok, {:is_null, {:field, Core.field_id(field)}}}

  defp compile_comparison(_field, operator, nil) when operator in [:gt, :gte, :lt, :lte],
    do: invalid_filter({operator, nil})

  # A tuple is a reference or an expression, never a value to bind.
  defp compile_comparison(field, operator, value) when is_tuple(value),
    do: not_a_value({field, {operator, value}})

  defp compile_comparison(field, operator, value) do
    operator = if operator == :ne, do: :neq, else: operator
    {:ok, {operator, {:field, Core.field_id(field)}, {:literal, value}}}
  end

  defp normalize_comparator(value) when value in [:eq, :=, "eq", "="], do: {:ok, :eq}

  defp normalize_comparator(value) when value in [:ne, :neq, :!=, "ne", "neq", "!=", "<>"],
    do: {:ok, :neq}

  defp normalize_comparator(value) when value in [:gt, :>, "gt", ">"], do: {:ok, :gt}
  defp normalize_comparator(value) when value in [:gte, :>=, "gte", ">="], do: {:ok, :gte}
  defp normalize_comparator(value) when value in [:lt, :<, "lt", "<"], do: {:ok, :lt}
  defp normalize_comparator(value) when value in [:lte, :<=, "lte", "<="], do: {:ok, :lte}
  defp normalize_comparator(_value), do: :error

  defp validate_fields(predicate, contract) do
    declared = contract.source |> Core.relation_fields() |> MapSet.new()

    unknown =
      predicate
      |> predicate_fields()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(declared, &1))
      |> Enum.sort()

    case unknown do
      [] ->
        :ok

      fields ->
        error(
          :query_rule_unsupported_field,
          "enforced query predicates must reference root write fields",
          %{fields: fields}
        )
    end
  end

  defp predicate_fields({operator, predicates}) when operator in [:and, :or],
    do: Enum.flat_map(predicates, &predicate_fields/1)

  defp predicate_fields({:not, predicate}), do: predicate_fields(predicate)
  defp predicate_fields({:in, {:field, field}, _values}), do: [Core.field_id(field)]

  defp predicate_fields({operator, {:field, field}, _value})
       when operator in @comparison_operators,
       do: [Core.field_id(field)]

  defp predicate_fields({operator, {:field, field}}) when operator in [:is_null, :not_null],
    do: [Core.field_id(field)]

  defp column_types(domain) do
    case domain |> map_value(:source) |> map_value(:columns) do
      columns when is_map(columns) ->
        Map.new(columns, fn {field, spec} -> {Core.field_id(field), map_value(spec, :type)} end)

      _ ->
        %{}
    end
  end

  # Host `:column_metadata` keyed by table (string or atom keys); a value
  # that is not a map provides no columns.
  defp host_catalog(metadata, table) when is_map(metadata) and table != "" do
    found =
      Enum.find_value(metadata, fn {key, columns} ->
        if (is_binary(key) or (is_atom(key) and not is_nil(key))) and to_string(key) == table,
          do: {:ok, columns}
      end)

    case found do
      {:ok, columns} when is_map(columns) -> {:ok, columns}
      {:ok, _malformed} -> {:ok, %{}}
      nil -> :error
    end
  end

  defp host_catalog(_metadata, _table), do: :error

  defp provided_catalog(provider, table) when is_function(provider, 1) and table != "" do
    case provider.(table) do
      columns when is_map(columns) -> columns
      _ -> %{}
    end
  end

  defp provided_catalog(_provider, _table), do: %{}

  @doc false
  # Evaluates a compiled predicate on a candidate (field => native value)
  # with `columns` (field => Scalar.column/2 descriptor). Returns
  # `{:ok, true | false | :unknown}`, or `{:error, details}` when any leaf is
  # not decidable in process (a refusal is never turned into true or false).
  def evaluate_candidate(predicate, candidate, columns),
    do: evaluate(predicate, candidate, columns)

  defp evaluate({:and, predicates}, candidate, columns),
    do: evaluate_all(predicates, candidate, columns, true, &sql_and/2)

  defp evaluate({:or, predicates}, candidate, columns),
    do: evaluate_all(predicates, candidate, columns, false, &sql_or/2)

  defp evaluate({:not, {:in, column, values}}, candidate, columns),
    do: evaluate_scalar(:not_in, column, {:list, values}, candidate, columns)

  defp evaluate({:not, predicate}, candidate, columns) do
    with {:ok, result} <- evaluate(predicate, candidate, columns), do: {:ok, sql_not(result)}
  end

  defp evaluate({:in, column, values}, candidate, columns),
    do: evaluate_scalar(:in, column, {:list, values}, candidate, columns)

  defp evaluate({:is_null, {:field, field}}, candidate, _columns) do
    with {:ok, actual} <- candidate_value(candidate, field), do: {:ok, is_nil(actual)}
  end

  defp evaluate({:not_null, {:field, field}}, candidate, _columns) do
    with {:ok, actual} <- candidate_value(candidate, field), do: {:ok, not is_nil(actual)}
  end

  defp evaluate({operator, column, expected}, candidate, columns)
       when operator in @comparison_operators,
       do: evaluate_scalar(operator, column, expected, candidate, columns)

  defp evaluate(predicate, _candidate, _columns),
    do: {:error, %{reason: :unsupported_candidate_predicate, predicate: predicate}}

  # A column operand on the right (a column pair) is never read as a literal
  # and two candidate columns are never compared in process (wave-3 9i).
  defp evaluate_scalar(operator, {:field, field}, expected, candidate, columns) do
    field = Core.field_id(field)

    with {:ok, actual} <- candidate_value(candidate, field),
         {:ok, actual} <- bound(actual, field, :untyped_candidate_value),
         {:ok, expected} <- expected_text(expected, field) do
      column = Map.get(columns, field) || Scalar.column(nil)

      case Scalar.compare(column, operator, actual, expected) do
        :not_evaluable ->
          {:error, %{field: field, reason: :not_evaluable_in_process}}

        result ->
          {:ok, result}
      end
    end
  end

  defp evaluate_scalar(_operator, column, _expected, _candidate, _columns),
    do: {:error, %{reason: :column_operand, column: column}}

  defp expected_text({:list, values}, field) do
    Enum.reduce_while(values, {:ok, []}, fn
      {:literal, value}, {:ok, acc} ->
        case bound(value, field, :untyped_predicate_value) do
          {:ok, text} -> {:cont, {:ok, acc ++ [text]}}
          error -> {:halt, error}
        end

      other, _acc ->
        {:halt, {:error, %{field: field, reason: :column_operand, operand: other}}}
    end)
  end

  defp expected_text({:literal, value}, field), do: bound(value, field, :untyped_predicate_value)

  defp expected_text(other, field),
    do: {:error, %{field: field, reason: :column_operand, operand: other}}

  # Operands are the text the runtime binds; a native float or temporal is
  # bound by the driver's own conversion, which cannot be reproduced here.
  defp bound(value, field, reason) do
    case Scalar.bound_text(value) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, %{field: field, reason: reason}}
    end
  end

  defp evaluate_all(predicates, candidate, columns, initial, reducer) do
    Enum.reduce_while(predicates, {:ok, initial}, fn predicate, {:ok, result} ->
      case evaluate(predicate, candidate, columns) do
        {:ok, value} -> {:cont, {:ok, reducer.(result, value)}}
        {:error, _details} = error -> {:halt, error}
      end
    end)
  end

  defp candidate_value(candidate, field) do
    field = Core.field_id(field)

    case Map.fetch(candidate, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %{field: field, reason: :missing_candidate_value}}
    end
  end

  defp sql_not(true), do: false
  defp sql_not(false), do: true
  defp sql_not(:unknown), do: :unknown

  defp sql_and(false, _right), do: false
  defp sql_and(_left, false), do: false
  defp sql_and(true, right), do: right
  defp sql_and(left, true), do: left
  defp sql_and(:unknown, :unknown), do: :unknown

  defp sql_or(true, _right), do: true
  defp sql_or(_left, true), do: true
  defp sql_or(false, right), do: right
  defp sql_or(left, false), do: left
  defp sql_or(:unknown, :unknown), do: :unknown

  defp relation(source),
    do: SelectoUpdato.WriteContract.relation_name(source)

  defp primary_key(source), do: source |> map_value(:primary_key) |> Kernel.||(:id)

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp not_a_value(filter) do
    error(
      :query_rule_not_evaluable,
      "enforced queries compare a field with a value, not a reference or expression",
      %{filter: filter}
    )
  end

  defp invalid_filter(filter) do
    error(
      :query_rule_unsupported_predicate,
      "enforced queries only support root-field boolean, comparison, null, and IN predicates",
      %{filter: filter}
    )
  end

  defp error(code, message, details \\ %{}) do
    {:error, Error.new(:query_enforcement, message, details: Map.put(details, :code, code))}
  end

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil
end
