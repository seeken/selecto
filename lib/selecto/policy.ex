defmodule Selecto.Policy do
  @moduledoc """
  Governance policy for configured Selecto queries.

  Strict mode seals the fully composed domain at configuration time, rejects
  query-authored SQL escape hatches, and limits runtime joins and row sources to
  capabilities declared by the domain.
  """

  alias Selecto.PolicyViolation

  @modes [:permissive, :strict]
  @domain_sql_modes [:declared, :forbid]
  @raw_sql_heads [
    :raw_sql,
    :raw_sql_filter,
    :custom_sql,
    "raw_sql",
    "raw_sql_filter",
    "custom_sql"
  ]
  @domain_sql_keys [
    :select,
    :sql,
    :on,
    :join_condition,
    :raw_sql,
    :raw_sql_filter,
    :custom_sql,
    "select",
    "sql",
    "on",
    "join_condition",
    "raw_sql",
    "raw_sql_filter",
    "custom_sql"
  ]
  @member_groups [:ctes, :laterals, :subqueries, :values, :unnests]
  @internal_origin_key :__selecto_policy_origin__

  defstruct mode: :permissive,
            domain_sql: :declared,
            domain_seal: nil,
            config_seal: nil,
            base_column_ids: [],
            base_join_ids: []

  @type mode :: :permissive | :strict
  @type domain_sql_mode :: :declared | :forbid

  @type t :: %__MODULE__{
          mode: mode(),
          domain_sql: domain_sql_mode(),
          domain_seal: String.t() | nil,
          config_seal: String.t() | nil,
          base_column_ids: [term()],
          base_join_ids: [term()]
        }

  @spec ensure_configuration_options!(keyword()) :: :ok
  def ensure_configuration_options!(opts) do
    if Keyword.get(opts, :mode, :permissive) == :strict and
         Keyword.get(opts, :validate, true) == false do
      violation!(
        :validation_required,
        "strict mode requires domain validation; remove validate: false"
      )
    end

    :ok
  end

  @spec new!(map(), map(), keyword()) :: t()
  def new!(domain, config, opts) do
    mode = Keyword.get(opts, :mode, :permissive)
    domain_sql = Keyword.get(opts, :domain_sql, :declared)

    unless mode in @modes do
      raise ArgumentError,
            "invalid Selecto mode #{inspect(mode)}; expected one of #{@modes |> inspect()}"
    end

    unless domain_sql in @domain_sql_modes do
      raise ArgumentError,
            "invalid domain_sql policy #{inspect(domain_sql)}; expected one of #{inspect(@domain_sql_modes)}"
    end

    if mode == :strict and Keyword.get(opts, :validate, true) == false do
      violation!(
        :validation_required,
        "strict mode requires domain validation; remove validate: false"
      )
    end

    if mode == :strict and domain_sql == :forbid do
      ensure_domain_sql_forbidden!(domain)
    end

    base_column_ids = config |> Map.get(:columns, %{}) |> Map.keys()
    base_join_ids = config |> Map.get(:joins, %{}) |> Map.keys()

    %__MODULE__{
      mode: mode,
      domain_sql: domain_sql,
      domain_seal: seal(domain),
      config_seal: seal(config_authority(config, base_column_ids, base_join_ids)),
      base_column_ids: base_column_ids,
      base_join_ids: base_join_ids
    }
  end

  @spec strict?(Selecto.t() | t() | term()) :: boolean()
  def strict?(%Selecto{policy: %__MODULE__{mode: :strict}}), do: true
  def strict?(%__MODULE__{mode: :strict}), do: true
  def strict?(_), do: false

  @spec validate_query!(Selecto.t()) :: :ok
  def validate_query!(%Selecto{} = selecto) do
    if strict?(selecto) do
      ensure_domain_sealed!(selecto)
      ensure_config_sealed!(selecto)
      ensure_query_term_allowed!(selecto, selecto.set, [:set])
      ensure_dynamic_joins_declared!(selecto)
      ensure_recorded_sources!(selecto)
    end

    :ok
  end

  @spec ensure_query_term_allowed!(Selecto.t(), term(), [term()]) :: :ok
  def ensure_query_term_allowed!(%Selecto{} = selecto, term, path \\ []) do
    if strict?(selecto) do
      case find_unsafe_query_term(term, path, selecto) do
        nil -> :ok
        {type, unsafe_path, description} -> violation!(type, description, unsafe_path)
      end
    else
      :ok
    end
  end

  @spec ensure_join_allowed!(Selecto.t(), atom() | String.t(), keyword()) :: :ok
  def ensure_join_allowed!(%Selecto{} = selecto, join_id, options) do
    if strict?(selecto) do
      origin = origin_from_options(options)
      public_options = strip_internal_options(options)

      cond do
        valid_member_origin?(selecto, origin) ->
          :ok

        Map.has_key?(Map.get(selecto.config, :joins, %{}), join_id) and public_options == [] ->
          :ok

        Map.has_key?(Map.get(selecto.config, :joins, %{}), join_id) ->
          violation!(
            :join_override_forbidden,
            "strict mode may enable domain join #{inspect(join_id)}, but may not override its structure"
          )

        true ->
          violation!(
            :ad_hoc_join_forbidden,
            "strict mode prohibits join #{inspect(join_id)} because it is not declared by the domain"
          )
      end
    else
      :ok
    end
  end

  @spec ensure_parameterized_join_allowed!(Selecto.t(), atom(), keyword()) :: :ok
  def ensure_parameterized_join_allowed!(%Selecto{} = selecto, join_id, structural_options) do
    if strict?(selecto) and structural_options != [] do
      violation!(
        :join_override_forbidden,
        "strict mode allows parameters declared by domain join #{inspect(join_id)}, but not structural overrides"
      )
    end

    :ok
  end

  @spec ensure_subquery_join_allowed!(Selecto.t(), atom(), keyword()) :: :ok
  def ensure_subquery_join_allowed!(%Selecto{} = selecto, join_id, options) do
    if strict?(selecto) and not valid_member_origin?(selecto, origin_from_options(options)) do
      violation!(
        :ad_hoc_join_forbidden,
        "strict mode prohibits direct subquery join #{inspect(join_id)}; declare and apply a named domain query member"
      )
    end

    :ok
  end

  @spec ensure_ad_hoc_source_allowed!(Selecto.t(), atom()) :: :ok
  def ensure_ad_hoc_source_allowed!(%Selecto{} = selecto, kind) do
    if strict?(selecto) do
      violation!(
        :ad_hoc_source_forbidden,
        "strict mode prohibits direct #{kind} sources; declare and apply a named domain query member"
      )
    end

    :ok
  end

  @spec ensure_source_origin_allowed!(Selecto.t(), atom(), keyword()) :: :ok
  def ensure_source_origin_allowed!(%Selecto{} = selecto, kind, options) do
    if strict?(selecto) and not valid_member_origin?(selecto, origin_from_options(options)) do
      violation!(
        :ad_hoc_source_forbidden,
        "strict mode prohibits direct #{kind} sources; declare and apply a named domain query member"
      )
    end

    :ok
  end

  @spec ensure_named_member_allowed!(Selecto.t(), atom(), String.t(), keyword(), [atom()]) :: :ok
  def ensure_named_member_allowed!(
        selecto,
        kind,
        member_name,
        overrides,
        allowed_override_keys \\ []
      ) do
    if strict?(selecto) do
      unless declared_member?(selecto, kind, member_name) do
        violation!(
          :undeclared_query_member,
          "strict mode requires #{kind} member #{inspect(member_name)} to be declared by the domain"
        )
      end

      rejected_keys = Keyword.keys(overrides) -- allowed_override_keys

      if rejected_keys != [] do
        violation!(
          :query_member_override_forbidden,
          "strict mode prohibits structural overrides #{inspect(Enum.uniq(rejected_keys))} for named #{kind} member #{inspect(member_name)}"
        )
      end
    end

    :ok
  end

  @spec record_named_member(Selecto.t(), atom(), String.t()) :: Selecto.t()
  def record_named_member(%Selecto{} = selecto, kind, member_name) do
    if strict?(selecto) do
      entries = Map.get(selecto.set, :policy_members, [])
      put_in(selecto.set[:policy_members], Enum.uniq(entries ++ [{kind, to_string(member_name)}]))
    else
      selecto
    end
  end

  @spec member_origin(atom(), String.t()) :: tuple()
  def member_origin(kind, member_name), do: {:domain_member, kind, to_string(member_name)}

  @spec put_member_origin(keyword(), atom(), String.t()) :: keyword()
  def put_member_origin(options, kind, member_name) do
    Keyword.put(options, @internal_origin_key, member_origin(kind, member_name))
  end

  @spec origin_from_options(keyword()) :: term()
  def origin_from_options(options), do: Keyword.get(options, @internal_origin_key)

  @spec strip_internal_options(keyword()) :: keyword()
  def strip_internal_options(options), do: Keyword.delete(options, @internal_origin_key)

  @spec annotate_origin(map(), keyword()) :: map()
  def annotate_origin(config, options) do
    case origin_from_options(options) do
      nil -> config
      origin -> Map.put(config, :policy_origin, origin)
    end
  end

  @spec ensure_set_operation_compatible!(Selecto.t(), Selecto.t()) :: :ok
  def ensure_set_operation_compatible!(left, right) do
    if strict?(left) != strict?(right) do
      violation!(
        :mixed_query_policies,
        "set operations cannot mix strict and permissive Selecto queries"
      )
    end

    :ok
  end

  @spec ensure_nested_query_allowed!(Selecto.t(), Selecto.t(), atom(), String.t()) :: :ok
  def ensure_nested_query_allowed!(outer, nested, kind, member_name) do
    if strict?(outer) and not strict?(nested) do
      violation!(
        :mixed_query_policies,
        "strict named #{kind} member #{inspect(member_name)} returned a permissive nested query"
      )
    end

    validate_query!(nested)
  end

  defp ensure_domain_sealed!(%Selecto{domain: domain, policy: policy}) do
    if seal(domain) != policy.domain_seal do
      violation!(
        :domain_modified_after_configuration,
        "the configured domain changed after strict mode sealed it"
      )
    end
  end

  defp ensure_config_sealed!(%Selecto{config: config, policy: policy}) do
    authority = config_authority(config, policy.base_column_ids, policy.base_join_ids)

    if seal(authority) != policy.config_seal do
      violation!(
        :domain_config_modified_after_configuration,
        "the compiled domain configuration changed after strict mode sealed it"
      )
    end
  end

  defp config_authority(config, column_ids, join_ids) do
    config
    |> Map.take([
      :source,
      :source_table,
      :primary_key,
      :filters,
      :functions,
      :domain_data,
      :extensions,
      :rollup_sort_fix
    ])
    |> Map.put(:columns, Map.take(Map.get(config, :columns, %{}), column_ids))
    |> Map.put(:joins, Map.take(Map.get(config, :joins, %{}), join_ids))
  end

  defp ensure_dynamic_joins_declared!(selecto) do
    selecto.set
    |> Map.get(:dynamic_joins, %{})
    |> Enum.each(fn {join_id, join_config} ->
      origin = Map.get(join_config, :policy_origin)
      base_join = Map.get(join_config, :base_join)

      unless valid_member_origin?(selecto, origin) or
               Map.has_key?(Map.get(selecto.config, :joins, %{}), join_id) or
               (not is_nil(base_join) and
                  Map.has_key?(Map.get(selecto.config, :joins, %{}), base_join)) do
        violation!(
          :ad_hoc_join_forbidden,
          "strict query state contains undeclared dynamic join #{inspect(join_id)}",
          [:set, :dynamic_joins, join_id]
        )
      end
    end)
  end

  defp ensure_recorded_sources!(selecto) do
    recorded = Map.get(selecto.set, :policy_members, [])

    for {set_key, kind} <- [
          {:ctes, :ctes},
          {:lateral_joins, :laterals},
          {:values_clauses, :values},
          {:unnest, :unnests}
        ],
        Map.get(selecto.set, set_key, []) != [],
        not Enum.any?(recorded, fn {recorded_kind, _name} -> recorded_kind == kind end) do
      violation!(
        :ad_hoc_source_forbidden,
        "strict query state contains an unrecorded #{kind} source",
        [:set, set_key]
      )
    end
  end

  defp declared_member?(selecto, kind, member_name) when kind in @member_groups do
    selecto.domain
    |> Map.get(:query_members, %{})
    |> Map.get(kind, %{})
    |> Map.keys()
    |> Enum.any?(&(to_string(&1) == to_string(member_name)))
  end

  defp declared_member?(_selecto, _kind, _member_name), do: false

  defp valid_member_origin?(selecto, {:domain_member, kind, member_name}),
    do: declared_member?(selecto, kind, member_name)

  defp valid_member_origin?(_selecto, _origin), do: false

  defp find_unsafe_query_term(%Selecto{} = nested, path, _root) do
    validate_query!(nested)
    find_nested_policy_mismatch(nested, path)
  end

  defp find_unsafe_query_term(term, path, _selecto)
       when is_tuple(term) and tuple_size(term) > 0 and elem(term, 0) in @raw_sql_heads do
    head = elem(term, 0)

    {:raw_sql_forbidden, path,
     "strict mode prohibits query-authored #{inspect(head)} expressions"}
  end

  defp find_unsafe_query_term({:subquery, sql, _params}, path, _selecto)
       when is_binary(sql) or is_list(sql) do
    {:raw_sql_forbidden, path, "strict mode prohibits raw SQL subquery expressions"}
  end

  defp find_unsafe_query_term(%_{} = struct, path, selecto) do
    struct
    |> Map.from_struct()
    |> find_unsafe_query_term(path, selecto)
  end

  defp find_unsafe_query_term(map, path, selecto) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      find_unsafe_query_term(value, path ++ [key], selecto)
    end)
  end

  defp find_unsafe_query_term(list, path, selecto) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} ->
      find_unsafe_query_term(value, path ++ [index], selecto)
    end)
  end

  defp find_unsafe_query_term(tuple, path, selecto) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> find_unsafe_query_term(path, selecto)
  end

  defp find_unsafe_query_term(_term, _path, _selecto), do: nil

  defp find_nested_policy_mismatch(nested, path) do
    if strict?(nested) do
      nil
    else
      {:mixed_query_policies, path,
       "strict queries may only contain strict nested Selecto queries"}
    end
  end

  defp ensure_domain_sql_forbidden!(domain) do
    case find_domain_sql(domain, []) do
      nil -> :ok
      path -> violation!(:domain_sql_forbidden, "domain_sql: :forbid rejected declared SQL", path)
    end
  end

  defp find_domain_sql(term, path)
       when is_tuple(term) and tuple_size(term) > 0 and elem(term, 0) in @raw_sql_heads,
       do: path

  defp find_domain_sql(map, path) when is_map(map) do
    Enum.find_value(map, fn
      {key, value}
      when key in @domain_sql_keys and (is_binary(value) or is_list(value)) ->
        path ++ [key]

      {key, value} ->
        find_domain_sql(value, path ++ [key])
    end)
  end

  defp find_domain_sql(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> find_domain_sql(value, path ++ [index]) end)
  end

  defp find_domain_sql(tuple, path) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> find_domain_sql(path)

  defp find_domain_sql(_term, _path), do: nil

  defp seal(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec violation!(atom(), String.t()) :: no_return()
  @spec violation!(atom(), String.t(), list()) :: no_return()
  defp violation!(type, message, path \\ []) do
    raise PolicyViolation, type: type, message: message, path: path
  end
end
