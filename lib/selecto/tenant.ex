defmodule Selecto.Tenant do
  @moduledoc """
  Multi-tenant helpers for Selecto query state.

  This module provides a lightweight tenant context contract for read-path
  queries. Tenant scope is enforced by appending tenant constraints to the
  query's required filter bucket (`set.required_filters`).

  An attached trusted tenant (`with_tenant/2` with a `:tenant_id`) limits every
  read, whether or not `apply_tenant_scope/2` was called: the SQL builder binds
  `tenant_field = tenant_id` onto the root, intersected with any required
  tenant conjunct (one that excludes it is `:tenant_scope_mismatch`); other
  filters are ANDed with it. It binds only the root's DECLARED tenant_field: a
  root without one, or a context naming another column, is refused with
  `:missing_tenant_scope`. `query_filters/2` carries the binding into
  query-scoped writes. Tenant relations joined across an untenanted hop of a
  scoped read are paired with the root's tenant column (by name in a
  two-column domain), or with a retarget origin's admitted values.

  `tenant_boundary/2` is the tenant boundary that public surfaces (the API
  query and write handlers, canned pages and co-domain lookups) require on a
  domain that declares `source.tenant_field`; `tenant_conjunct?/2` is its
  positive-tenant-conjunct rule.
  """

  @default_tenant_field "tenant_id"
  @default_namespace "tenant"

  @type tenant_context :: %{
          optional(:tenant_id) => term(),
          optional(:tenant_mode) => atom() | String.t(),
          optional(:tenant_field) => atom() | String.t(),
          optional(:prefix) => String.t(),
          optional(:namespace) => String.t(),
          optional(:required) => boolean(),
          optional(:required_filters) => [Selecto.Types.filter()]
        }

  @doc """
  Bind a scalar trusted tenant from the domain's declared field, or attach a
  structured prefix/advanced context while preserving existing obligations.
  """
  @spec with_tenant(
          Selecto.Types.t(),
          tenant_context() | keyword() | String.t() | number() | atom() | nil
        ) ::
          Selecto.Types.t()
  def with_tenant(selecto, tenant_id) when is_binary(tenant_id) or is_number(tenant_id) do
    field = domain_tenant_field(selecto)

    if is_nil(field), do: raise(ArgumentError, "with_tenant requires source.tenant_field")

    if is_binary(tenant_id) and String.trim(tenant_id) == "",
      do: raise(ArgumentError, "tenant identity must be nonblank")

    context = normalize_context(%{tenant_id: tenant_id, tenant_field: field, required: true})
    stored = tenant(selecto)

    context =
      if stored,
        do: Map.put(context, :namespace, Map.get(stored, :namespace, @default_namespace)),
        else: context

    ensure_context_compatible!(stored, context, :tenant)

    if Enum.any?(
         required_tenant_values(Selecto.required_filters(selecto), field),
         fn values -> not Enum.any?(values, &(&1 === tenant_id)) end
       ),
       do: raise(ArgumentError, "tenant identity conflicts with required predicates")

    selecto
    |> attach_context(merge_contexts(stored, context))
    |> apply_tenant_scope()
  end

  def with_tenant(selecto, tenant_context) do
    context = normalize_domain_context(selecto, tenant_context)
    stored = tenant(selecto)
    ensure_context_compatible!(stored, context, :tenant)
    attach_context(selecto, merge_contexts(stored, context))
  end

  defp normalize_domain_context(selecto, context) when is_map(context) do
    if Map.has_key?(context, :tenant_field) or Map.has_key?(context, "tenant_field"),
      do: normalize_context(context),
      else:
        normalize_context(
          Map.put(context, :tenant_field, domain_tenant_field(selecto) || @default_tenant_field)
        )
  end

  defp normalize_domain_context(selecto, context) when is_list(context) do
    ensure_unique_keyword_keys!(context)
    normalize_domain_context(selecto, Map.new(context))
  end

  defp normalize_domain_context(_selecto, context), do: normalize_context(context)

  defp attach_context(selecto, context) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :with_tenant)
    %{selecto | tenant: context}
  end

  defp required_tenant_values(filters, field) do
    Enum.flat_map(filters, fn
      {:and, nested} when is_list(nested) ->
        required_tenant_values(nested, field)

      {key, value} when is_atom(key) or is_binary(key) ->
        if key not in [:or, :not] and normalize_field(key) == field,
          do: tenant_value_set(value),
          else: []

      {key, op, value} when op in [:eq, :=, "=", :in, "in"] ->
        if normalize_field(key) == field, do: tenant_value_set(value), else: []

      _ ->
        []
    end)
  end

  defp tenant_value_set({op, value}) when op in [:eq, :=, "=", :in, "in"],
    do: tenant_value_set(value)

  defp tenant_value_set(values) when is_list(values), do: [values]

  defp tenant_value_set(value) when is_binary(value) or is_number(value) or is_nil(value),
    do: [[value]]

  defp tenant_value_set(_), do: []

  @doc """
  Read the tenant context from a Selecto query.
  """
  @spec tenant(Selecto.Types.t()) :: tenant_context() | nil
  def tenant(%{tenant: tenant_context}), do: tenant_context
  def tenant(_), do: nil

  @doc """
  Apply tenant scope to a query's required filter bucket.

  Options:

  - `:tenant` - explicit tenant context override
  - `:tenant_id` - explicit tenant id override
  - `:tenant_field` - explicit tenant field override
  - `:required_filters` - additional required filters
  """
  @spec apply_tenant_scope(Selecto.Types.t(), keyword()) :: Selecto.Types.t()
  def apply_tenant_scope(selecto, opts \\ []) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :apply_tenant_scope)
    ensure_unique_keyword_keys!(opts)

    stored_context = normalize_context(tenant(selecto))

    tenant_context =
      case Keyword.fetch(opts, :tenant) do
        {:ok, override} ->
          normalized_override = normalize_context(override)
          ensure_context_compatible!(stored_context, normalized_override, :tenant)
          merge_contexts(stored_context, normalized_override)

        :error ->
          if is_nil(stored_context) and Keyword.has_key?(opts, :tenant_id) do
            normalize_context(%{
              tenant_id: Keyword.fetch!(opts, :tenant_id),
              tenant_field: Keyword.get(opts, :tenant_field, @default_tenant_field)
            })
          else
            stored_context
          end
      end

    case tenant_context do
      nil ->
        selecto

      normalized_context ->
        selecto = %{selecto | tenant: normalized_context}

        additional_required =
          List.wrap(Map.get(normalized_context, :required_filters, [])) ++
            List.wrap(Keyword.get(opts, :required_filters, []))

        selecto =
          Enum.reduce(additional_required, selecto, fn filter, acc ->
            require_tenant_filter(acc, filter)
          end)

        context_field = Map.get(normalized_context, :tenant_field, @default_tenant_field)
        tenant_field = Keyword.get(opts, :tenant_field, context_field) |> normalize_field()
        ensure_override_match!(:tenant_field, context_field, tenant_field)

        context_id = Map.get(normalized_context, :tenant_id)
        tenant_id = Keyword.get(opts, :tenant_id, context_id)
        ensure_override_match!(:tenant_id, context_id, tenant_id)

        if is_nil(tenant_id) do
          selecto
        else
          require_tenant_filter(selecto, tenant_field, tenant_id)
        end
    end
  end

  @doc """
  Append a required filter to the query set.
  """
  @spec require_tenant_filter(Selecto.Types.t(), Selecto.Types.filter()) :: Selecto.Types.t()
  def require_tenant_filter(selecto, filter) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :require_tenant_filter)
    set = Map.get(selecto, :set, %{})
    current = Map.get(set, :required_filters, [])
    updated = uniq_filters(current ++ [filter])
    %{selecto | set: Map.put(set, :required_filters, updated)}
  end

  @doc """
  Append a required tenant filter from field + value.
  """
  @spec require_tenant_filter(Selecto.Types.t(), atom() | String.t(), term()) :: Selecto.Types.t()
  def require_tenant_filter(selecto, tenant_field, tenant_id) do
    require_tenant_filter(selecto, {normalize_field(tenant_field), tenant_id})
  end

  @doc """
  Return whether tenant scope is required for this query.

  Precedence:

  1. `opts[:require_tenant]`
  2. tenant context `:required` / `:require_tenant`
  3. domain `:tenant_required` / `:require_tenant`
  4. inferred true for `tenant_mode` in shared-column/shared-rls/schema modes
  """
  @spec tenant_required?(Selecto.Types.t(), keyword()) :: boolean()
  def tenant_required?(selecto, opts \\ []) do
    context = tenant(selecto) || %{}
    domain = Map.get(selecto, :domain, %{})

    cond do
      is_boolean(Keyword.get(opts, :require_tenant)) ->
        Keyword.get(opts, :require_tenant)

      is_boolean(map_get(context, :required)) ->
        map_get(context, :required)

      is_boolean(map_get(context, :require_tenant)) ->
        map_get(context, :require_tenant)

      is_boolean(map_get(domain, :tenant_required)) ->
        map_get(domain, :tenant_required)

      is_boolean(map_get(domain, :require_tenant)) ->
        map_get(domain, :require_tenant)

      true ->
        tenant_mode_requires_scope?(map_get(context, :tenant_mode))
    end
  end

  @doc """
  Validate tenant scope requirements for read and derivation paths.

  Returns `:ok` when tenant scope is optional or present. Returns structured
  validation error when tenant scope is required but missing.
  """
  @spec validate_scope(Selecto.Types.t(), keyword()) :: :ok | {:error, Selecto.Error.t()}
  def validate_scope(selecto, opts \\ []) do
    tenant_context = tenant(selecto) || %{}

    case tenant_scope_status(selecto, opts) do
      :valid ->
        :ok

      {:invalid, reason, details} ->
        {:error,
         Selecto.Error.validation_error(
           "Tenant scope is #{reason}",
           Map.merge(
             %{
               tenant_mode: map_get(tenant_context, :tenant_mode),
               tenant_field: tenant_field(selecto, opts),
               tenant_id: map_get(tenant_context, :tenant_id),
               prefix: map_get(tenant_context, :prefix)
             },
             details
           )
         )}
    end
  end

  @doc """
  Raise when tenant scope is required and missing.
  """
  @spec ensure_scope!(Selecto.Types.t(), keyword()) :: :ok
  def ensure_scope!(selecto, opts \\ []) do
    case validate_scope(selecto, opts) do
      :ok -> :ok
      {:error, error} -> raise Selecto.Error.to_exception(error)
    end
  end

  @doc """
  Return the tenant field a domain declares at `source.tenant_field`, or `nil`.

  Accepts a Selecto query or a domain map. The field is returned as a string.
  """
  @spec domain_tenant_field(Selecto.Types.t() | map()) :: String.t() | nil
  def domain_tenant_field(%Selecto{domain: domain}), do: domain_tenant_field(domain)

  def domain_tenant_field(domain) when is_map(domain) do
    case domain |> lenient_get(:source) |> lenient_get(:tenant_field) do
      nil -> nil
      field -> normalize_field(field)
    end
  end

  def domain_tenant_field(_domain), do: nil

  @doc false
  # The query's tenant conditions re-expressed on `target_field` of a relation
  # the query reads outside its own joins: a retarget target or a query member.
  #
  # Conjuncts carry by value: in a one-column domain from the root tenant
  # field, in a two-column domain only from the same-named column (lesson
  # 41c). A retargeted query whose origin is scoped carries the origin's
  # admitted values of that column as a subquery (lesson 41b). `:unscoped` when
  # the query has no scope at all; `:error` when it is scoped (or has required
  # filters) but its scope cannot be carried onto `target_field`.
  @spec carry_conditions(Selecto.Types.t(), atom() | String.t()) ::
          {:ok, [Selecto.Types.filter()]} | :unscoped | :error
  def carry_conditions(selecto, target_field) do
    target_field = normalize_field(target_field)
    required = scope_filters(selecto)

    carried =
      case source_tenant_column(selecto, target_field) do
        nil -> []
        column -> Enum.flat_map(required, &carry_conjunct(&1, column, target_field))
      end

    origin = retarget_origin(selecto)

    cond do
      carried != [] ->
        {:ok, carried}

      origin != nil and scoped?(origin) ->
        case Selecto.Retarget.origin_column_query(selecto, target_field) do
          {:ok, query} -> {:ok, [{target_field, {:subquery, :in, query}}]}
          :error -> :error
        end

      scoped?(selecto) ->
        :error

      required == [] ->
        :unscoped

      true ->
        :error
    end
  end

  @doc false
  # The root column whose values a relation's `target_field` takes: the root
  # tenant field in a one-column domain, the same-named tenant column the root
  # declares in a two-column domain, otherwise nil.
  @spec source_tenant_column(Selecto.Types.t(), atom() | String.t()) :: String.t() | nil
  def source_tenant_column(selecto, target_field) do
    target_field = normalize_field(target_field)
    root_field = domain_tenant_field(selecto)
    columns = domain_tenant_columns(selecto)

    cond do
      is_nil(root_field) -> nil
      length(columns) < 2 -> root_field
      target_field in columns and root_declares?(selecto, target_field) -> target_field
      true -> nil
    end
  end

  @doc false
  # Whether a read is tenant scoped: its root declares tenant_field and the
  # trusted engine tenant or a required positive tenant conjunct bounds one of
  # the domain's tenant columns, or it is a retarget of a scoped origin.
  @spec scoped?(Selecto.Types.t()) :: boolean()
  def scoped?(selecto) do
    filters = scope_filters(selecto)

    (not is_nil(domain_tenant_field(selecto)) and
       Enum.any?(domain_tenant_columns(selecto), &tenant_conjunct?(filters, &1))) or
      case retarget_origin(selecto) do
        nil -> false
        origin -> scoped?(origin)
      end
  end

  # The filters that scope a read: required, engine-bound and host-applied
  # filters, the same set tenant_boundary/2 accepts as a host scope (lesson
  # 41f). A request filter only ever adds binding.
  defp scope_filters(selecto) do
    set = Map.get(selecto, :set) || %{}

    uniq_filters(
      Selecto.Query.required_filters(selecto) ++
        engine_filters(selecto) ++ List.wrap(Map.get(set, :filtered, []))
    )
  end

  @doc false
  # Whether an unscoped read's filters nonetheless read a tenant column (for
  # example `tenant_id IN (7, 8)` under OR, NOT 9, or `< 9`): such a scope
  # cannot be carried across a shared hop and is refused rather than read
  # unbounded (lesson 41, N4).
  @spec unprovable_scope?(Selecto.Types.t()) :: boolean()
  def unprovable_scope?(selecto) do
    columns = domain_tenant_columns(selecto)

    columns != [] and not scoped?(selecto) and
      Enum.any?(scope_filters(selecto), &mentions_column?(&1, columns))
  end

  defp mentions_column?({key, value}, columns) when is_atom(key) or is_binary(key) do
    (key not in [:and, :or, :not] and normalize_field(key) in columns) or
      mentions_column?(value, columns)
  end

  defp mentions_column?(term, columns) when is_tuple(term),
    do: term |> Tuple.to_list() |> mentions_column?(columns)

  defp mentions_column?(terms, columns) when is_list(terms),
    do:
      Enum.any?(terms, fn
        term when is_binary(term) -> term in columns
        term -> mentions_column?(term, columns)
      end)

  defp mentions_column?(_term, _columns), do: false

  defp retarget_origin(%{set: %{retarget_state: %{origin: %Selecto{} = origin}}}), do: origin
  defp retarget_origin(_selecto), do: nil

  defp root_declares?(selecto, field) do
    selecto
    |> Selecto.domain()
    |> lenient_get(:source)
    |> lenient_get(:fields)
    |> List.wrap()
    |> Enum.any?(&(normalize_field(&1) == field))
  end

  @doc false
  # The domain's tenant columns: `source.tenant_field` and, when it differs,
  # the write scope tenant field (a two-column root). A retargeted domain keeps
  # its origin's columns under `:tenant_columns`.
  @spec domain_tenant_columns(Selecto.Types.t() | map()) :: [String.t()]
  def domain_tenant_columns(%Selecto{domain: domain}), do: domain_tenant_columns(domain)

  def domain_tenant_columns(domain) when is_map(domain) do
    case lenient_get(domain, :tenant_columns) do
      columns when is_list(columns) and columns != [] ->
        Enum.map(columns, &normalize_field/1)

      _ ->
        case domain_tenant_field(domain) do
          nil ->
            []

          field ->
            case domain_write_tenant_field(domain) do
              nil -> [field]
              ^field -> [field]
              write_field -> [field, write_field]
            end
        end
    end
  end

  def domain_tenant_columns(_domain), do: []

  @doc false
  # The engine tenant bound onto the root of every read (lesson 43): the
  # attached trusted tenant on the root's DECLARED tenant_field, when the
  # tenant context names that field. Anything else is unbindable and refused.
  @spec engine_filters(Selecto.Types.t()) :: [Selecto.Types.filter()]
  def engine_filters(selecto) do
    context = tenant(selecto) || %{}
    tenant_id = Map.get(context, :tenant_id)
    declared = domain_tenant_field(selecto)

    if defined_scalar?(tenant_id) and not is_nil(declared) and
         tenant_field(selecto, []) == declared,
       do: [{declared, tenant_id}],
       else: []
  end

  # A trusted tenant the root cannot bind: no declared tenant_field (a shared
  # root, lesson 42), or a context naming another column.
  defp unbindable_tenant?(selecto) do
    context = tenant(selecto) || %{}
    defined_scalar?(Map.get(context, :tenant_id)) and engine_filters(selecto) == []
  end

  defp carry_conjunct({:and, filters}, root_field, target_field) when is_list(filters),
    do: Enum.flat_map(filters, &carry_conjunct(&1, root_field, target_field))

  defp carry_conjunct({field, value}, root_field, target_field)
       when is_binary(field) or is_atom(field) do
    if to_string(field) == root_field and carried_value?(value),
      do: [{target_field, value}],
      else: []
  end

  defp carry_conjunct(_filter, _root_field, _target_field), do: []

  defp carried_value?(value) when is_binary(value) or is_number(value), do: true
  defp carried_value?({:in, values}) when is_list(values) and values != [], do: true

  defp carried_value?({operator, value}) when operator in [:eq, :=, "="],
    do: is_binary(value) or is_number(value)

  defp carried_value?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &(is_binary(&1) or is_number(&1)))

  defp carried_value?(_value), do: false

  @doc """
  Return whether `filters` hold a positive tenant conjunct on `tenant_field`.

  A positive tenant conjunct is an equality of the tenant field to a defined
  scalar (a string, number or boolean), or a nonempty IN list of defined
  scalars, either at the top level of the filter list or beneath `:and`.
  Conditions beneath `:or` or `:not`, `nil` values, references, subqueries and
  any other operator never count. A list of filters is read as a conjunction,
  as Selecto applies required and query filters.

  This is the query-enforced-write tenant rule, and it is the second way to
  satisfy `tenant_boundary/2`.
  """
  @spec tenant_conjunct?(Selecto.Types.filter() | [Selecto.Types.filter()], atom() | String.t()) ::
          boolean()
  def tenant_conjunct?(filters, tenant_field) when is_list(filters),
    do: Enum.any?(filters, &conjunct?(&1, normalize_field(tenant_field)))

  def tenant_conjunct?(filter, tenant_field),
    do: conjunct?(filter, normalize_field(tenant_field))

  @doc """
  Check the tenant boundary a public surface requires on a domain that declares
  `source.tenant_field` (certification specification 2.19.0).

  Public surfaces are the API query and write handlers, canned pages and
  co-domain lookups. Direct `Selecto.execute/2` reads are not public surfaces
  and remain available for trusted reads that span tenants.

  A surface has a boundary when either holds:

    1. The query carries a trusted tenant attached with `with_tenant/2` whose
       tenant field is the domain's tenant field. For writes the executor binds
       the tenant to that declared field, with or without `writes.scope.tenant`
       (on a two-column domain the scope column is not bound to it; lessons 47
       and 47a). For reads the caller ANDs the tenant into the read, as
       `require_read_boundary/2` does.
    2. The trusted host scope holds a positive tenant conjunct (see
       `tenant_conjunct?/2`). The trusted host scope is the domain and query
       required filters, the filters the host applied before handing the query
       to the surface, and any `:scope` the surface itself accepts. Request
       input never contributes to it, so call this before applying any.

  Options:

    * `:access` - `:read` (default) or `:write`.
    * `:scope` - a filter or list of filters the surface accepts from the host,
      such as a co-domain lookup scope.

  A trusted tenant attached to a read whose root cannot carry its tenant field
  (a shared root with no such field) is refused with `:missing_tenant_scope`
  rather than read unbounded or failed later as an unknown field.

  Returns `{:ok, :not_required}` when the domain declares no tenant field,
  `{:ok, {:tenant, tenant_id}}` when the trusted tenant bounds the surface,
  `{:ok, :host_scope}` when a tenant conjunct does, and otherwise an error whose
  `details.code` is `:missing_tenant_scope`.
  """
  @spec tenant_boundary(Selecto.Types.t(), keyword()) ::
          {:ok, :not_required | :host_scope | {:tenant, term()}} | {:error, Selecto.Error.t()}
  def tenant_boundary(selecto, opts \\ []) do
    access = Keyword.get(opts, :access, :read)

    unless access in [:read, :write],
      do: raise(ArgumentError, "tenant boundary access must be :read or :write")

    case domain_tenant_field(selecto) do
      nil ->
        if access == :read and unbindable_tenant?(selecto),
          do: {:error, unbindable_tenant_error(selecto)},
          else: {:ok, :not_required}

      field ->
        tenant_id = trusted_tenant(selecto, field)

        cond do
          # A trusted tenant on the declared tenant_field bounds reads and
          # writes alike; the write executor binds it (lesson 47).
          not is_nil(tenant_id) ->
            {:ok, {:tenant, tenant_id}}

          tenant_conjunct?(trusted_host_scope(selecto, opts), field) ->
            {:ok, :host_scope}

          true ->
            {:error,
             Selecto.Error.validation_error("Trusted tenant scope is required", %{
               code: :missing_tenant_scope,
               tenant_field: field
             })}
        end
    end
  end

  @doc """
  Require the read tenant boundary of `tenant_boundary/2` and AND a trusted
  tenant into the query's required filters when the tenant is the boundary.

  Returns the query to execute or the `:missing_tenant_scope` error. Accepts the
  same `:scope` option.
  """
  @spec require_read_boundary(Selecto.Types.t(), keyword()) ::
          {:ok, Selecto.Types.t()} | {:error, Selecto.Error.t()}
  def require_read_boundary(selecto, opts \\ []) do
    case tenant_boundary(selecto, Keyword.put(opts, :access, :read)) do
      {:ok, {:tenant, _tenant_id}} -> {:ok, apply_tenant_scope(selecto)}
      {:ok, _boundary} -> {:ok, selecto}
      {:error, _error} = error -> error
    end
  end

  @doc """
  Merge execution options with tenant-derived defaults.

  If no `:prefix` option is provided explicitly and tenant context includes a
  `:prefix`, the prefix is injected into execution opts.
  """
  @spec merge_execution_opts(Selecto.Types.t(), keyword()) :: keyword()
  def merge_execution_opts(selecto, opts \\ []) do
    ensure_unique_keyword_keys!(opts)
    attached_prefix = map_get(tenant(selecto) || %{}, :prefix)
    explicit_prefix = Keyword.get(opts, :prefix)

    cond do
      present_string?(attached_prefix) and present_string?(explicit_prefix) and
          attached_prefix != explicit_prefix ->
        raise ArgumentError,
              "execution prefix conflicts with attached tenant context: " <>
                "#{inspect(attached_prefix)} != #{inspect(explicit_prefix)}"

      Keyword.has_key?(opts, :prefix) ->
        opts

      present_string?(attached_prefix) ->
        Keyword.put(opts, :prefix, attached_prefix)

      true ->
        opts
    end
  end

  @doc false
  @spec set_operation_scope(Selecto.Types.t()) :: term()
  def set_operation_scope(selecto) do
    context = tenant(selecto) || %{}
    field = tenant_field(selecto, [])
    filter_values = required_filter_scope_values(selecto, field) |> Enum.uniq() |> Enum.sort()
    prefix = map_get(context, :prefix)
    attached_tenant_id = map_get(context, :tenant_id)

    row_scope = %{
      attached_id: attached_tenant_id,
      field: field,
      filter_values: filter_values
    }

    row_scope =
      if is_nil(attached_tenant_id) and filter_values == [], do: nil, else: row_scope

    prefix_scope = if present_string?(prefix), do: prefix, else: nil

    case {prefix_scope, row_scope, tenant_required?(selecto)} do
      {nil, nil, true} ->
        :required_but_unscoped

      {nil, nil, false} ->
        :unscoped

      {scope_prefix, scope_row, _required?} ->
        {:tenant_scope, %{prefix: scope_prefix, row: scope_row}}
    end
  end

  @doc """
  Normalize tenant context input into a map with atom keys.
  """
  @spec normalize_context(tenant_context() | keyword() | String.t() | atom() | nil) ::
          tenant_context() | nil
  def normalize_context(nil), do: nil

  def normalize_context(tenant_id) when is_binary(tenant_id) or is_atom(tenant_id) do
    %{
      tenant_id: to_string(tenant_id),
      tenant_field: @default_tenant_field,
      namespace: @default_namespace,
      required_filters: []
    }
  end

  def normalize_context(tenant_context) when is_list(tenant_context) do
    ensure_unique_keyword_keys!(tenant_context)

    tenant_context
    |> Enum.into(%{})
    |> normalize_context()
  end

  def normalize_context(tenant_context) when is_map(tenant_context) do
    ensure_unambiguous_aliases!(tenant_context)
    tenant_id = map_get(tenant_context, :tenant_id) || map_get(tenant_context, :id)

    tenant_field =
      tenant_context
      |> map_get(:tenant_field)
      |> normalize_field()

    %{
      tenant_id: tenant_id,
      tenant_mode: map_get(tenant_context, :tenant_mode),
      tenant_field: tenant_field,
      prefix: map_get(tenant_context, :prefix),
      namespace: map_get(tenant_context, :namespace) || @default_namespace,
      required:
        case map_get(tenant_context, :required) do
          nil -> map_get(tenant_context, :require_tenant)
          value -> value
        end,
      required_filters: List.wrap(map_get(tenant_context, :required_filters) || [])
    }
  end

  def normalize_context(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} ->
        value

      {:error, {:ok, value}} ->
        value

      {{:ok, value}, {:ok, value}} ->
        value

      {{:ok, left}, {:ok, right}} ->
        raise ArgumentError,
              "conflicting tenant context aliases #{inspect(key)} and #{inspect(Atom.to_string(key))}: " <>
                "#{inspect(left)} != #{inspect(right)}"

      {:error, :error} ->
        nil
    end
  end

  @context_keys [
    :tenant_id,
    :id,
    :tenant_mode,
    :tenant_field,
    :prefix,
    :namespace,
    :required,
    :require_tenant,
    :required_filters
  ]

  defp ensure_unambiguous_aliases!(context) do
    Enum.each(@context_keys, &map_get(context, &1))

    ensure_alias_match!(context, :tenant_id, :id)
    ensure_alias_match!(context, :required, :require_tenant)
    :ok
  end

  defp ensure_alias_match!(context, left_key, right_key) do
    left = map_get(context, left_key)
    right = map_get(context, right_key)

    if not is_nil(left) and not is_nil(right) and left != right do
      raise ArgumentError,
            "conflicting tenant context keys #{inspect(left_key)} and #{inspect(right_key)}: " <>
              "#{inspect(left)} != #{inspect(right)}"
    end
  end

  defp ensure_unique_keyword_keys!(opts) when is_list(opts) do
    duplicates =
      opts
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "duplicate tenant option keys: #{inspect(Enum.sort(duplicates))}"
    end
  end

  defp ensure_context_compatible!(nil, _override, _source), do: :ok
  defp ensure_context_compatible!(_stored, nil, _source), do: :ok

  defp ensure_context_compatible!(stored, override, source) do
    for key <- [:tenant_id, :tenant_field, :prefix],
        left = Map.get(stored, key),
        right = Map.get(override, key),
        not is_nil(left) and not is_nil(right) and left !== right do
      raise ArgumentError,
            "#{source} override conflicts with attached tenant context for #{key}: " <>
              "#{inspect(left)} != #{inspect(right)}"
    end

    :ok
  end

  defp merge_contexts(nil, override), do: override
  defp merge_contexts(stored, nil), do: stored

  defp merge_contexts(stored, override) do
    merged =
      stored
      |> Map.merge(override, fn _key, stored_value, override_value ->
        if is_nil(override_value), do: stored_value, else: override_value
      end)
      |> Map.put(
        :required,
        Map.get(stored, :required) == true or Map.get(override, :required) == true
      )
      |> Map.put(
        :required_filters,
        uniq_filters(
          List.wrap(Map.get(stored, :required_filters)) ++
            List.wrap(Map.get(override, :required_filters))
        )
      )

    Map.put_new(merged, :namespace, @default_namespace)
  end

  defp ensure_override_match!(_key, nil, _override), do: :ok
  defp ensure_override_match!(_key, current, current), do: :ok

  defp ensure_override_match!(key, current, override) do
    raise ArgumentError,
          "#{key} override conflicts with attached tenant context: " <>
            "#{inspect(current)} != #{inspect(override)}"
  end

  defp normalize_field(nil), do: @default_tenant_field
  defp normalize_field(field) when is_atom(field), do: Atom.to_string(field)
  defp normalize_field(field) when is_binary(field), do: field
  defp normalize_field(field), do: to_string(field)

  defp tenant_mode_requires_scope?(mode) do
    normalized = mode |> to_string() |> String.downcase()
    normalized in ["shared_column", "shared_rls", "schema"]
  end

  defp tenant_scope_status(selecto, opts) do
    tenant_context = tenant(selecto) || %{}
    field = tenant_field(selecto, opts)
    required_values = required_filter_scope_values(selecto, field)
    has_prefix = map_get(tenant_context, :prefix) |> present_string?()
    tenant_id = map_get(tenant_context, :tenant_id)

    cond do
      not is_nil(tenant_id) and unbindable_tenant?(selecto) ->
        {:invalid, "not bindable to the query root", %{code: :missing_tenant_scope}}

      has_prefix and is_nil(tenant_id) and required_values == [] ->
        :valid

      not is_nil(tenant_id) ->
        engine_status(selecto, field, tenant_id, required_values)

      required_values == [] and tenant_required?(selecto, opts) ->
        {:invalid, "required but missing", %{code: :tenant_scope_missing}}

      required_values == [] ->
        :valid

      length(Enum.uniq(required_values)) > 1 ->
        {:invalid, "ambiguous", %{code: :tenant_scope_ambiguous, filter_values: required_values}}

      true ->
        :valid
    end
  end

  # A trusted tenant is bound onto the root of every read (lesson 43). A
  # required tenant conjunct that excludes it is a mismatch; one that admits it
  # is intersected. Ordinary filters (host or request) are ANDed with the
  # binding in SQL, so a disagreeing one simply matches no rows.
  defp engine_status(selecto, field, tenant_id, required_values) do
    scalars = Enum.filter(required_values, &defined_scalar?/1)

    excluding =
      selecto
      |> tenant_conjunct_value_sets(field)
      |> Enum.find(&(tenant_id not in &1))

    cond do
      length(Enum.uniq(scalars)) > 1 ->
        {:invalid, "ambiguous", %{code: :tenant_scope_ambiguous, filter_values: required_values}}

      excluding != nil ->
        {:invalid, "mismatched",
         %{
           code: :tenant_scope_mismatch,
           expected_tenant_id: tenant_id,
           filter_value: if(length(excluding) == 1, do: hd(excluding), else: excluding)
         }}

      true ->
        :valid
    end
  end

  # The admitted value set of each positive required conjunct on `field`.
  defp tenant_conjunct_value_sets(selecto, field) do
    selecto
    |> Selecto.Query.required_filters()
    |> Enum.flat_map(&conjunct_value_sets(&1, field))
  end

  defp conjunct_value_sets({:and, filters}, field) when is_list(filters),
    do: Enum.flat_map(filters, &conjunct_value_sets(&1, field))

  defp conjunct_value_sets({filter_field, value}, field)
       when is_atom(filter_field) or is_binary(filter_field) do
    if normalize_field(filter_field) == field and positive_tenant_value?(value),
      do: [conjunct_values(value)],
      else: []
  end

  defp conjunct_value_sets(_filter, _field), do: []

  defp conjunct_values({:in, values}), do: values
  defp conjunct_values({_operator, value}), do: [value]
  defp conjunct_values(values) when is_list(values), do: values
  defp conjunct_values(value), do: [value]

  defp tenant_field(selecto, opts) do
    tenant_context = tenant(selecto) || %{}

    opts
    |> Keyword.get(:tenant_field, map_get(tenant_context, :tenant_field) || @default_tenant_field)
    |> normalize_field()
  end

  defp required_filter_scope_values(selecto, tenant_field) do
    set_required =
      selecto
      |> Map.get(:set, %{})
      |> Map.get(:required_filters, [])

    domain_required =
      selecto
      |> Map.get(:domain, %{})
      |> Map.get(:required_filters, [])

    (set_required ++ domain_required)
    |> Enum.flat_map(fn
      {field, value} when not is_nil(value) ->
        if normalize_field(field) == tenant_field, do: [value], else: []

      _ ->
        []
    end)
  end

  defp present_string?(value) when is_binary(value), do: byte_size(value) > 0
  defp present_string?(_), do: false

  # Boolean composition is matched before the field clauses, so an `:or` or
  # `:not` branch can never read as a field named "or" or "not".
  defp conjunct?({:and, filters}, field) when is_list(filters),
    do: Enum.any?(filters, &conjunct?(&1, field))

  defp conjunct?({operator, _filters}, _field) when operator in [:or, :not], do: false

  defp conjunct?({filter_field, value}, field)
       when is_atom(filter_field) or is_binary(filter_field),
       do: normalize_field(filter_field) == field and positive_tenant_value?(value)

  defp conjunct?(_filter, _field), do: false

  defp positive_tenant_value?({:in, values}) when is_list(values), do: defined_scalars?(values)

  defp positive_tenant_value?({operator, value}) when operator in [:eq, :=, "="],
    do: defined_scalar?(value)

  defp positive_tenant_value?(values) when is_list(values), do: defined_scalars?(values)
  defp positive_tenant_value?(value), do: defined_scalar?(value)

  defp defined_scalars?(values), do: values != [] and Enum.all?(values, &defined_scalar?/1)

  defp defined_scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp unbindable_tenant_error(selecto) do
    Selecto.Error.validation_error("Trusted tenant scope is required", %{
      code: :missing_tenant_scope,
      tenant_field: tenant_field(selecto, []),
      reason: :tenant_field_not_on_root
    })
  end

  defp trusted_tenant(selecto, field) do
    context = tenant(selecto) || %{}
    tenant_id = Map.get(context, :tenant_id)

    if defined_scalar?(tenant_id) and normalize_field(Map.get(context, :tenant_field)) == field,
      do: tenant_id
  end

  defp domain_write_tenant_field(domain) do
    tenant = domain |> lenient_get(:writes) |> lenient_get(:scope) |> lenient_get(:tenant)

    case lenient_get(tenant, :field) || lenient_get(tenant, :tenant_field) do
      nil -> nil
      field -> normalize_field(field)
    end
  end

  defp trusted_host_scope(selecto, opts) do
    Selecto.Query.required_filters(selecto) ++
      Map.get(selecto.set, :filtered, []) ++ List.wrap(Keyword.get(opts, :scope))
  end

  defp lenient_get(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp lenient_get(_map, _key), do: nil

  defp uniq_filters(filters) do
    Enum.reduce(filters, [], fn filter, acc ->
      if filter in acc do
        acc
      else
        acc ++ [filter]
      end
    end)
  end
end
