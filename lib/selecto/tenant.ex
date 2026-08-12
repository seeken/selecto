defmodule Selecto.Tenant do
  @moduledoc """
  Multi-tenant helpers for Selecto query state.

  This module provides a lightweight tenant context contract for read-path
  queries. Tenant scope is enforced by appending tenant constraints to the
  query's required filter bucket (`set.required_filters`).
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
  Attach tenant context to a Selecto query.
  """
  @spec with_tenant(Selecto.Types.t(), tenant_context() | keyword() | String.t() | atom() | nil) ::
          Selecto.Types.t()
  def with_tenant(selecto, tenant_context) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :with_tenant)
    %{selecto | tenant: normalize_context(tenant_context)}
  end

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
        not is_nil(left) and not is_nil(right) and left != right do
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
      has_prefix and is_nil(tenant_id) and required_values == [] ->
        :valid

      not is_nil(tenant_id) and required_values == [] ->
        {:invalid, "required but missing", %{code: :tenant_scope_missing}}

      required_values == [] and tenant_required?(selecto, opts) ->
        {:invalid, "required but missing", %{code: :tenant_scope_missing}}

      required_values == [] ->
        :valid

      length(Enum.uniq(required_values)) > 1 ->
        {:invalid, "ambiguous", %{code: :tenant_scope_ambiguous, filter_values: required_values}}

      not is_nil(tenant_id) and List.first(required_values) != tenant_id ->
        {:invalid, "mismatched",
         %{
           code: :tenant_scope_mismatch,
           expected_tenant_id: tenant_id,
           filter_value: List.first(required_values)
         }}

      true ->
        :valid
    end
  end

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
