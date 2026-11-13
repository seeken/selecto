defmodule SelectoUpdato.Tenant do
  @moduledoc """
  Multi-tenant helpers for SelectoUpdato operations.

  This module stores tenant metadata in `operation.opts[:tenant]`, appends
  tenant-required filters to operation filters. Schema-prefix routing is an
  adapter concern and is not represented as portable write scope.
  """

  alias SelectoUpdato.{Operation, WriteContract}

  @default_tenant_field "tenant_id"

  @type tenant_context :: %{
          optional(:tenant_id) => term(),
          optional(:tenant_field) => String.t() | atom(),
          optional(:required) => boolean(),
          optional(:required_filters) => [tuple()],
          optional(:tenant_identity_conflicts) => [map()]
        }

  @spec with_tenant(Operation.t(), tenant_context() | keyword() | String.t() | atom() | nil) ::
          Operation.t()
  def with_tenant(%Operation{} = operation, tenant_context) do
    normalized = normalize_context(tenant_context)
    opts = operation.opts || []
    %{operation | opts: Keyword.put(opts, :tenant, normalized)}
  end

  @spec tenant(Operation.t()) :: tenant_context() | nil
  def tenant(%Operation{} = operation) do
    operation.opts
    |> Kernel.||([])
    |> Keyword.get(:tenant)
  end

  @spec apply_tenant_scope(Operation.t(), keyword()) :: Operation.t()
  def apply_tenant_scope(%Operation{} = operation, opts \\ []) do
    tenant_context = tenant_context(operation, opts)

    case tenant_context do
      nil ->
        operation

      context ->
        operation = with_tenant(operation, context)

        required_filters =
          List.wrap(Map.get(context, :required_filters, [])) ++
            List.wrap(Keyword.get(opts, :required_filters, []))

        operation =
          Enum.reduce(required_filters, operation, fn filter, acc ->
            require_tenant_filter(acc, filter)
          end)

        tenant_field = tenant_field(operation, opts)

        tenant_id = Keyword.get(opts, :tenant_id, Map.get(context, :tenant_id))

        if is_nil(tenant_id) do
          operation
        else
          require_tenant_filter(operation, tenant_field, tenant_id)
        end
    end
  end

  @doc """
  Apply canonical execution-time scope from trusted host context.

  This is intentionally narrower than `apply_tenant_scope/2`: it only applies
  automatically when the domain declares `writes.scope.tenant`. Older top-level
  tenant flags continue to require explicit scoping by the host.
  """
  @spec apply_execution_scope(Operation.t(), keyword()) :: Operation.t()
  def apply_execution_scope(%Operation{} = operation, opts \\ []) do
    case canonical_tenant_scope(operation) do
      scope when is_map(scope) ->
        # The trusted tenant binds the declared tenant_field, also on a
        # two-column domain whose scope column differs (lesson 47a).
        scope =
          case declared_tenant_field(operation) do
            nil -> scope
            field -> Map.put(scope, :field, field)
          end

        operation = record_tenant_context_conflict(operation, opts)
        context = tenant_context(operation, opts)

        operation =
          case context do
            nil -> operation
            context -> with_tenant(operation, context)
          end

        operation
        |> apply_required_filters(context, opts)
        |> apply_trusted_context_filter(scope, context, opts)
        |> put_applied_scope(applied_tenant_scope(scope, context))

      _other ->
        # Without writes.scope.tenant there is no tenant to bind, but a
        # trusted context's required filters still bound the write: they are
        # applied to the pre-image predicate and recorded as trusted scope
        # (post-image), never dropped. An upsert carrying them is then
        # refused like any filtered upsert.
        context = tenant_context(operation, opts)

        case trusted_required_filters(context, opts) do
          [] -> operation
          _filters -> apply_required_filters(operation, context, opts)
        end
    end
  end

  @doc false
  # Every trusted required filter the operation's tenant context and the
  # execution options (`required_filters:`, `context: %{required_filters:}`)
  # carry.
  @spec requested_required_filters(Operation.t(), keyword()) :: [term()]
  def requested_required_filters(%Operation{} = operation, opts) when is_list(opts) do
    operation |> tenant_context(opts) |> trusted_required_filters(opts) |> Enum.uniq()
  end

  @doc false
  # Trusted required filters the operation or its options carry that
  # apply_execution_scope/2 has not applied (a direct compile that skipped
  # it). The compiler refuses such a write rather than drop them.
  @spec unapplied_required_filters(Operation.t(), keyword()) :: [term()]
  def unapplied_required_filters(%Operation{} = operation, opts) when is_list(opts) do
    applied = Keyword.get(operation.opts || [], :trusted_required_filters, [])

    operation
    |> tenant_context(opts)
    |> trusted_required_filters(opts)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in applied))
  end

  @doc false
  # The trusted required filters a context and its options carry, as one value
  # however they are spelled: a planned action's grant binds them
  # (ActionAuthorization.authorization_context/2), at issue and at use.
  @spec trusted_filter_binding(map() | nil, keyword()) :: [tuple()]
  def trusted_filter_binding(context, opts) do
    context
    |> trusted_required_filters(opts)
    |> Enum.map(&filter_key/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp trusted_required_filters(context, opts) do
    List.wrap(map_get(context, :required_filters)) ++
      List.wrap(Keyword.get(opts, :required_filters, [])) ++
      List.wrap(map_get(Keyword.get(opts, :context) || %{}, :required_filters))
  end

  @doc """
  Return the execution scope metadata applied to the operation.
  """
  @spec applied_scope(Operation.t()) :: map() | nil
  def applied_scope(%Operation{} = operation) do
    operation.opts
    |> Kernel.||([])
    |> Keyword.get(:applied_scope)
  end

  @doc false
  @spec context_conflict(Operation.t()) :: map() | nil
  def context_conflict(%Operation{} = operation) do
    operation.opts
    |> Kernel.||([])
    |> Keyword.get(:tenant_context_conflict)
  end

  @doc false
  @spec resolve_trusted_context(Operation.t(), map()) :: {:ok, map()} | {:error, map()}
  def resolve_trusted_context(%Operation{} = operation, execution_context)
      when is_map(execution_context) do
    operation_context = operation |> tenant() |> normalize_context()
    context_tenant = tenant_context_from_map(execution_context)

    conflicts =
      List.wrap(context_conflict(operation)) ++
        tagged_identity_conflicts(:operation, operation_context) ++
        tagged_identity_conflicts(:context, context_tenant) ++
        cross_context_conflicts(operation_context, context_tenant)

    case Enum.uniq(conflicts) do
      [] ->
        tenant_context = merge_tenant_context(operation_context, context_tenant)
        {:ok, canonicalize_execution_context(execution_context, tenant_context)}

      conflicts ->
        {:error, %{source_conflicts: conflicts}}
    end
  end

  def resolve_trusted_context(%Operation{} = operation, _execution_context),
    do: resolve_trusted_context(operation, %{})

  @spec require_tenant_filter(Operation.t(), tuple()) :: Operation.t()
  def require_tenant_filter(%Operation{} = operation, filter)
      when is_tuple(filter) and tuple_size(filter) in [2, 3] do
    current = operation.filters || []

    # A filter the operation already carries, naming the field as an atom where
    # the trusted one names it as a string, is the same predicate: adding the
    # second would refuse as a duplicate identifier.
    if Enum.any?(current, &(filter_key(&1) == filter_key(filter))),
      do: operation,
      else: %{operation | filters: uniq_filters(current ++ [filter])}
  end

  defp filter_key({field, value}) when is_atom(field) or is_binary(field),
    do: {normalize_field(field), value}

  defp filter_key({field, comparator, value}) when is_atom(field) or is_binary(field),
    do: {normalize_field(field), comparator, value}

  defp filter_key(filter), do: filter

  @spec require_tenant_filter(Operation.t(), String.t() | atom(), term()) :: Operation.t()
  def require_tenant_filter(%Operation{} = operation, tenant_field, tenant_id) do
    tenant_field = normalize_field(tenant_field)
    current = operation.filters || []

    if Enum.any?(current, fn
         {field, value} -> normalize_field(field) == tenant_field and value == tenant_id
         _filter -> false
       end) do
      operation
    else
      require_tenant_filter(operation, {tenant_field, tenant_id})
    end
  end

  @spec tenant_required?(Operation.t(), keyword()) :: boolean()
  def tenant_required?(%Operation{} = operation, opts \\ []) do
    context = tenant(operation) || %{}
    canonical_scope = canonical_tenant_scope(operation)

    cond do
      is_boolean(Keyword.get(opts, :require_tenant)) ->
        Keyword.get(opts, :require_tenant)

      is_boolean(map_get(canonical_scope, :required)) ->
        map_get(canonical_scope, :required)

      is_boolean(map_get(context, :required)) ->
        map_get(context, :required)

      is_boolean(map_get(context, :require_tenant)) ->
        map_get(context, :require_tenant)

      is_boolean(map_get(operation.domain, :tenant_required)) ->
        map_get(operation.domain, :tenant_required)

      is_boolean(map_get(operation.domain, :require_tenant)) ->
        map_get(operation.domain, :require_tenant)

      true ->
        false
    end
  end

  @spec validate_scope(Operation.t(), keyword()) :: :ok | {:error, SelectoUpdato.Error.t()}
  def validate_scope(%Operation{} = operation, opts \\ []) do
    if tenant_required?(operation, opts) and not has_tenant_scope?(operation, opts) do
      context = tenant(operation) || %{}

      {:error,
       SelectoUpdato.Error.new(
         :missing_tenant_scope,
         "Tenant scope is required for this write operation",
         details: %{
           operation: operation.type,
           tenant_field: tenant_field(operation, opts),
           tenant_id: map_get(context, :tenant_id)
         }
       )}
    else
      :ok
    end
  end

  @spec ensure_scope!(Operation.t(), keyword()) :: :ok
  def ensure_scope!(%Operation{} = operation, opts \\ []) do
    case validate_scope(operation, opts) do
      :ok -> :ok
      {:error, error} -> raise RuntimeError, message: error.message
    end
  end

  @spec normalize_context(map() | keyword() | String.t() | atom() | nil) ::
          tenant_context() | nil
  def normalize_context(nil), do: nil

  def normalize_context(tenant_id) when is_binary(tenant_id) or is_atom(tenant_id) do
    %{tenant_id: to_string(tenant_id), tenant_field: @default_tenant_field, required_filters: []}
  end

  def normalize_context(tenant_context) when is_list(tenant_context) do
    normalized = tenant_context |> Enum.into(%{}) |> normalize_context()

    add_identity_conflicts(normalized, keyword_identity_conflicts(tenant_context))
  end

  def normalize_context(tenant_context) when is_map(tenant_context) do
    tenant_id_sources =
      map_identity_sources(tenant_context, :tenant_id) ++
        map_identity_sources(tenant_context, :id)

    tenant_field_sources =
      tenant_context
      |> map_identity_sources(:tenant_field)
      |> Enum.map(fn {source, value} -> {source, normalize_field(value)} end)

    normalized = %{
      tenant_id: first_source_value(tenant_id_sources),
      tenant_field: tenant_field_sources |> first_source_value() |> normalize_field(),
      required:
        case map_get(tenant_context, :required) do
          nil -> map_get(tenant_context, :require_tenant)
          value -> value
        end,
      required_filters: List.wrap(map_get(tenant_context, :required_filters) || [])
    }

    conflicts =
      List.wrap(map_get(tenant_context, :tenant_identity_conflicts)) ++
        source_conflicts(:tenant_id, tenant_id_sources) ++
        source_conflicts(:tenant_field, tenant_field_sources)

    add_identity_conflicts(normalized, conflicts)
  end

  def normalize_context(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp map_get(_map, _key), do: nil

  defp tenant_context(%Operation{} = operation, opts) when is_list(opts) do
    operation
    |> tenant()
    |> normalize_context()
    |> merge_tenant_context(normalize_context(tenant_context_from_opts(opts)))
  end

  defp tenant_context_from_opts(opts) when is_list(opts) do
    tenant_contexts =
      opts
      |> Keyword.get_values(:tenant)
      |> Enum.map(&normalize_context/1)

    direct_context =
      opts
      |> Keyword.take([:tenant_id, :tenant_field, :required_filters])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> case do
        [] -> nil
        context -> normalize_context(context)
      end

    (tenant_contexts ++ List.wrap(direct_context))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn context, accumulated ->
      merge_tenant_context(accumulated, context)
    end)
  end

  defp tenant_context_from_map(context) when is_map(context) do
    nested_contexts =
      context
      |> map_identity_sources(:tenant)
      |> Enum.map(fn {_source, tenant_context} -> normalize_context(tenant_context) end)

    direct_context =
      context
      |> Map.take([:tenant_id, "tenant_id", :tenant_field, "tenant_field"])
      |> case do
        empty when map_size(empty) == 0 -> nil
        tenant_context -> normalize_context(tenant_context)
      end

    (nested_contexts ++ List.wrap(direct_context))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(nil, fn tenant_context, accumulated ->
      merge_tenant_context(accumulated, tenant_context)
    end)
  end

  defp record_tenant_context_conflict(%Operation{} = operation, opts) do
    operation_context = operation |> tenant() |> normalize_context()
    execution_context = opts |> tenant_context_from_opts() |> normalize_context()

    operation_tenant = tenant_identity(operation_context)
    execution_tenant = tenant_identity(execution_context)

    source_conflicts =
      tagged_identity_conflicts(:operation, operation_context) ++
        tagged_identity_conflicts(:execution, execution_context) ++
        cross_context_conflicts(operation_context, execution_context)

    conflict =
      cond do
        operation_tenant && execution_tenant && operation_tenant != execution_tenant ->
          %{
            operation_tenant: operation_tenant,
            execution_tenant: execution_tenant
          }
          |> maybe_put_source_conflicts(source_conflicts)

        source_conflicts != [] ->
          %{
            operation_tenant: operation_tenant,
            execution_tenant: execution_tenant,
            source_conflicts: source_conflicts
          }

        true ->
          nil
      end

    put_context_conflict(operation, conflict)
  end

  defp tenant_identity(nil), do: nil

  defp tenant_identity(context) when is_map(context) do
    case map_get(context, :tenant_id) do
      nil ->
        nil

      tenant_id ->
        %{
          tenant_id: tenant_id,
          tenant_field: context |> map_get(:tenant_field) |> normalize_field()
        }
    end
  end

  defp merge_tenant_context(nil, nil), do: nil
  defp merge_tenant_context(nil, override), do: override
  defp merge_tenant_context(base, nil), do: base

  defp merge_tenant_context(base, override) when is_map(base) and is_map(override) do
    required_filters =
      (List.wrap(map_get(base, :required_filters)) ++
         List.wrap(map_get(override, :required_filters)))
      |> Enum.uniq()

    conflicts =
      identity_conflicts(base) ++
        identity_conflicts(override) ++ cross_context_conflicts(base, override)

    base
    |> Map.merge(reject_nil_values(override))
    |> Map.put(:required_filters, required_filters)
    |> add_identity_conflicts(conflicts)
  end

  defp map_identity_sources(map, key) do
    [
      {{key, :atom}, Map.get(map, key)},
      {{key, :string}, Map.get(map, Atom.to_string(key))}
    ]
    |> Enum.reject(fn {_source, value} -> is_nil(value) end)
  end

  defp keyword_identity_conflicts(keyword) do
    tenant_id_sources =
      [:tenant_id, :id]
      |> Enum.flat_map(fn key ->
        keyword
        |> Keyword.get_values(key)
        |> Enum.with_index()
        |> Enum.map(fn {value, index} -> {{key, index}, value} end)
      end)

    tenant_field_sources =
      keyword
      |> Keyword.get_values(:tenant_field)
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> {{:tenant_field, index}, normalize_field(value)} end)

    source_conflicts(:tenant_id, tenant_id_sources) ++
      source_conflicts(:tenant_field, tenant_field_sources)
  end

  defp source_conflicts(field, sources) do
    if sources |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1 do
      [%{field: field, sources: sources}]
    else
      []
    end
  end

  defp first_source_value([]), do: nil
  defp first_source_value([{_source, value} | _rest]), do: value

  defp identity_conflicts(context), do: List.wrap(map_get(context, :tenant_identity_conflicts))

  defp tagged_identity_conflicts(_origin, nil), do: []

  defp tagged_identity_conflicts(origin, context) do
    Enum.map(identity_conflicts(context), &Map.put(&1, :origin, origin))
  end

  defp cross_context_conflicts(nil, _right), do: []
  defp cross_context_conflicts(_left, nil), do: []

  defp cross_context_conflicts(left, right) do
    [
      {:tenant_id, map_get(left, :tenant_id), map_get(right, :tenant_id)},
      {:tenant_field, map_get(left, :tenant_field), map_get(right, :tenant_field)}
    ]
    |> Enum.flat_map(fn
      {_field, nil, _right} ->
        []

      {_field, _left, nil} ->
        []

      {_field, value, value} ->
        []

      {field, left_value, right_value} ->
        [%{field: field, sources: [left: left_value, right: right_value]}]
    end)
  end

  defp add_identity_conflicts(context, []), do: context

  defp add_identity_conflicts(context, conflicts) do
    Map.put(context, :tenant_identity_conflicts, Enum.uniq(conflicts))
  end

  defp maybe_put_source_conflicts(conflict, []), do: conflict

  defp maybe_put_source_conflicts(conflict, conflicts),
    do: Map.put(conflict, :source_conflicts, conflicts)

  defp put_context_conflict(operation, nil), do: operation

  defp put_context_conflict(operation, conflict) do
    operation_opts =
      operation.opts
      |> Kernel.||([])
      |> Keyword.put_new(:tenant_context_conflict, conflict)

    %{operation | opts: operation_opts}
  end

  defp canonicalize_execution_context(execution_context, nil) do
    Map.drop(execution_context, [
      :tenant,
      "tenant",
      :tenant_id,
      "tenant_id",
      :tenant_field,
      "tenant_field"
    ])
  end

  defp canonicalize_execution_context(execution_context, tenant_context) do
    canonical_tenant =
      Map.take(tenant_context, [:tenant_id, :tenant_field, :required, :required_filters])

    original_tenant = map_get(execution_context, :tenant)

    tenant_value =
      if is_nil(original_tenant), do: canonical_tenant.tenant_id, else: original_tenant

    execution_context
    |> canonicalize_execution_context(nil)
    |> Map.merge(canonical_tenant)
    |> Map.put(:tenant, tenant_value)
  end

  defp reject_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp apply_required_filters(%Operation{} = operation, context, opts) do
    required_filters = Enum.uniq(trusted_required_filters(context, opts))
    before = operation.filters || []

    operation =
      Enum.reduce(required_filters, operation, fn filter, acc ->
        require_tenant_filter(acc, filter)
      end)

    # Trusted required filters may pin a two-column domain's sites (lesson
    # 47b); caller filters on the operation never do.
    trusted =
      Keyword.get(operation.opts || [], :trusted_required_filters, []) ++ required_filters

    # The filters the scope added, which a planned action's grant was issued
    # before (ActionAuthorization.operation_fingerprint/1 leaves them out).
    added =
      Keyword.get(operation.opts || [], :scope_filters, []) ++
        Enum.reject(operation.filters || [], &(&1 in before))

    opts =
      (operation.opts || [])
      |> Keyword.put(:trusted_required_filters, Enum.uniq(trusted))
      |> Keyword.put(:scope_filters, Enum.uniq(added))

    %{operation | opts: opts}
  end

  defp apply_trusted_context_filter(%Operation{} = operation, scope, context, opts) do
    sources = map_get(scope, :satisfied_by) || []
    tenant_id = map_get(context, :tenant_id)

    if :trusted_context in sources and not is_nil(tenant_id) do
      require_tenant_filter(operation, tenant_field(operation, opts), tenant_id)
    else
      operation
    end
  end

  defp put_applied_scope(%Operation{} = operation, nil), do: operation

  defp put_applied_scope(%Operation{} = operation, applied_scope) when is_map(applied_scope) do
    opts =
      operation.opts
      |> Kernel.||([])
      |> Keyword.put(:applied_scope, applied_scope)

    %{operation | opts: opts}
  end

  defp applied_tenant_scope(scope, context) do
    sources =
      [
        trusted_context_scope_entry(scope, context)
      ]
      |> Enum.reject(&is_nil/1)

    if sources == [] do
      nil
    else
      %{
        tenant: %{
          required: map_get(scope, :required) == true,
          field: scope |> map_get(:field) |> normalize_field(),
          sources: sources
        }
      }
    end
  end

  defp trusted_context_scope_entry(scope, context) do
    sources = map_get(scope, :satisfied_by) || []
    tenant_id = map_get(context, :tenant_id)

    if :trusted_context in sources and not is_nil(tenant_id) do
      field = scope |> map_get(:field) |> normalize_field()

      %{
        source: :trusted_context,
        field: field,
        value: tenant_id,
        filter: {field, tenant_id}
      }
    end
  end

  defp normalize_field(nil), do: @default_tenant_field
  defp normalize_field(field) when is_atom(field), do: Atom.to_string(field)
  defp normalize_field(field) when is_binary(field), do: field
  defp normalize_field(field), do: to_string(field)

  defp has_tenant_scope?(%Operation{} = operation, opts) do
    context = tenant(operation) || %{}
    sources = tenant_scope_sources(operation)

    field = tenant_field(operation, opts)
    expected_tenant_id = map_get(context, :tenant_id)

    has_filter =
      operation.filters
      |> List.wrap()
      |> Enum.any?(fn
        {filter_field, value} ->
          normalize_field(filter_field) == field and not is_nil(value) and
            (is_nil(expected_tenant_id) or value == expected_tenant_id)

        _ ->
          false
      end)

    has_id = not is_nil(map_get(context, :tenant_id))
    has_payload = payload_has_tenant_value?(operation, field)

    Enum.any?(sources, fn
      :trusted_context -> has_id
      :prefix -> false
      :filter -> has_filter
      :payload -> has_payload
      _source -> false
    end)
  end

  defp payload_has_tenant_value?(%Operation{type: type} = operation, field)
       when type in [:insert, :upsert] do
    operation.attrs |> List.wrap() |> Enum.any?(&map_has_tenant_value?(&1, field))
  end

  defp payload_has_tenant_value?(%Operation{type: :update} = operation, field) do
    map_has_tenant_value?(operation.changes, field)
  end

  defp payload_has_tenant_value?(_operation, _field), do: false

  defp map_has_tenant_value?(map, field) when is_map(map) do
    atom_value =
      try do
        Map.get(map, String.to_existing_atom(field))
      rescue
        ArgumentError -> nil
      end

    value = Map.get(map, field) || atom_value
    not is_nil(value)
  end

  defp map_has_tenant_value?(_map, _field), do: false

  defp tenant_field(%Operation{} = operation, opts) do
    context = tenant(operation) || %{}
    canonical_scope = canonical_tenant_scope(operation) || %{}

    opts
    |> Keyword.get(
      :tenant_field,
      declared_tenant_field(operation) || map_get(canonical_scope, :field) ||
        map_get(context, :tenant_field) || @default_tenant_field
    )
    |> normalize_field()
  end

  # The domain's declared source.tenant_field, which a trusted tenant binds on
  # writes (lessons 47 and 47a).
  defp declared_tenant_field(%Operation{domain: %{} = domain}) do
    domain
    |> map_get_lenient(:source)
    |> map_get_lenient(:tenant_field)
  end

  defp declared_tenant_field(_operation), do: nil

  defp map_get_lenient(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_get_lenient(_map, _key), do: nil

  defp canonical_tenant_scope(%Operation{} = operation) do
    case operation.domain do
      %{} = domain -> WriteContract.tenant_scope(domain)
      _other -> nil
    end
  end

  defp tenant_scope_sources(%Operation{} = operation) do
    case canonical_tenant_scope(operation) do
      %{satisfied_by: sources} when is_list(sources) and sources != [] ->
        sources

      _other ->
        [:trusted_context, :prefix, :filter, :payload]
    end
  end

  defp uniq_filters(filters) do
    Enum.reduce(filters, [], fn filter, acc ->
      if filter in acc, do: acc, else: acc ++ [filter]
    end)
  end
end
