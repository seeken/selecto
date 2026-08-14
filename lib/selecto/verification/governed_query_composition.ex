defmodule Selecto.Verification.GovernedQueryComposition do
  @moduledoc """
  Bounded event-trace verification of governed query composition.

  The finite model crosses strict and permissive policies with required row and
  schema-prefix tenant scopes. It composes queries through public APIs for
  declared joins, named CTEs, named subqueries, named laterals, and the three
  set operations. Once a set operation exists, the model also proves that
  structural query composition is rejected rather than silently ignored;
  further set-operation chaining remains supported. Strict-only attack traces
  attempt the corresponding ad-hoc sources and a mixed-policy set operation.

  A passing report proves closure only for the declared domain, event set, and
  two-event depth in this module. It is not a proof for arbitrary query member
  callbacks, SQL semantics, or unlimited composition depth.
  """

  alias Selecto.PolicyViolation
  alias Selecto.Verification.BoundedTraceModel

  @safe_forms [
    :declared_join,
    :named_cte,
    :named_subquery,
    :named_lateral,
    :union,
    :intersect,
    :except
  ]
  @set_forms [:union, :intersect, :except]

  @unsafe_forms [
    :ad_hoc_join,
    :ad_hoc_cte,
    :ad_hoc_subquery,
    :ad_hoc_lateral,
    :mixed_policy_union,
    :mixed_row_tenant_union,
    :mixed_prefix_tenant_union,
    :mixed_compound_tenant_union,
    :mixed_attached_tenant_union
  ]

  @doc "Runs the built-in governed query-composition event model."
  @spec verify() :: BoundedTraceModel.report()
  def verify do
    BoundedTraceModel.check(
      "selecto.governed_query_composition.v1",
      initial_states(),
      events(),
      invariants(),
      max_depth: 2,
      state_key: &state_key/1,
      trace_state: &trace_state/1,
      include_trace_coverage: true
    )
  end

  defp initial_states do
    closure_states =
      for policy_mode <- [:permissive, :strict], tenant_mode <- [:row, :prefix] do
        initial_state(:closure, policy_mode, tenant_mode)
      end

    rejection_states =
      for tenant_mode <- [:row, :prefix] do
        initial_state(:strict_rejection, :strict, tenant_mode)
      end

    closure_states ++ rejection_states
  end

  defp initial_state(scenario, policy_mode, tenant_mode) do
    %{
      scenario: scenario,
      policy_mode: policy_mode,
      tenant_mode: tenant_mode,
      query: base_query(policy_mode, tenant_mode),
      used: [],
      attempt: nil
    }
  end

  defp events do
    Enum.map(@safe_forms, &{&1, safe_event(&1)}) ++
      Enum.map(@unsafe_forms, &{&1, unsafe_event(&1)})
  end

  defp safe_event(form) do
    fn state ->
      cond do
        state.scenario != :closure ->
          :disabled

        form in state.used ->
          :disabled

        terminal_set_mutation?(state, form) ->
          attempt_terminal_set_mutation(form, state)

        true ->
          query = apply_safe_form(form, state)

          {:next, %{state | query: query, used: state.used ++ [form], attempt: nil},
           %{form: form}}
      end
    end
  end

  defp terminal_set_mutation?(state, form) do
    form not in @set_forms and Enum.any?(state.used, &(&1 in @set_forms))
  end

  defp attempt_terminal_set_mutation(form, state) do
    try do
      query = apply_safe_form(form, state)

      {:next,
       %{
         state
         | query: query,
           used: state.used ++ [form],
           attempt: %{
             boundary: :terminal_set,
             form: form,
             outcome: :accepted,
             query_unchanged?: query == state.query
           }
       }, %{form: form, boundary: :terminal_set, outcome: :accepted}}
    rescue
      error in ArgumentError ->
        {:next,
         %{
           state
           | used: state.used ++ [form],
             attempt: %{
               boundary: :terminal_set,
               form: form,
               outcome: :rejected,
               query_unchanged?: true,
               message: Exception.message(error)
             }
         },
         %{
           form: form,
           boundary: :terminal_set,
           outcome: :rejected,
           message: Exception.message(error)
         }}
    end
  end

  defp unsafe_event(form) do
    fn state ->
      if state.scenario == :strict_rejection and state.used == [] do
        try do
          query = apply_unsafe_form(form, state)

          {:next,
           %{
             state
             | query: query,
               used: [form],
               attempt: %{form: form, outcome: :accepted}
           }, %{form: form, outcome: :accepted}}
        rescue
          error in PolicyViolation ->
            {:next,
             %{
               state
               | used: [form],
                 attempt: %{form: form, outcome: :rejected, type: error.type}
             }, %{form: form, outcome: :rejected, type: error.type}}
        end
      else
        :disabled
      end
    end
  end

  defp apply_safe_form(:declared_join, state), do: Selecto.join(state.query, :team)
  defp apply_safe_form(:named_cte, state), do: Selecto.with_cte(state.query, :scoped_accounts)

  defp apply_safe_form(:named_subquery, state),
    do: Selecto.with_subquery(state.query, :scoped_accounts)

  defp apply_safe_form(:named_lateral, state),
    do: Selecto.with_lateral(state.query, :bounded_series)

  defp apply_safe_form(operation, state) when operation in @set_forms do
    right =
      state.policy_mode
      |> base_query(state.tenant_mode)
      |> Selecto.filter({"name", "Grace"})

    apply(Selecto, operation, [state.query, right])
  end

  defp apply_unsafe_form(:ad_hoc_join, state) do
    Selecto.join(state.query, :audit_log,
      source: "audit_log",
      owner_key: :id,
      related_key: :account_id,
      fields: %{id: %{type: :integer}}
    )
  end

  defp apply_unsafe_form(:ad_hoc_cte, state) do
    Selecto.with_cte(state.query, "manual_accounts", fn ->
      base_query(:permissive, state.tenant_mode)
    end)
  end

  defp apply_unsafe_form(:ad_hoc_subquery, state) do
    Selecto.join_subquery(
      state.query,
      :manual_accounts,
      base_query(:strict, state.tenant_mode),
      on: [%{left: "id", right: "id"}]
    )
  end

  defp apply_unsafe_form(:ad_hoc_lateral, state) do
    Selecto.with_lateral(state.query, {:function, :bounded_row_source, [1, 2]},
      as: "manual_series",
      join_type: :inner
    )
  end

  defp apply_unsafe_form(:mixed_policy_union, state) do
    Selecto.union(state.query, base_query(:permissive, state.tenant_mode))
  end

  defp apply_unsafe_form(:mixed_row_tenant_union, state) do
    Selecto.union(state.query, base_query(state.policy_mode, :row, "tenant-b"))
  end

  defp apply_unsafe_form(:mixed_prefix_tenant_union, state) do
    Selecto.union(state.query, base_query(state.policy_mode, :prefix, "tenant_b"))
  end

  defp apply_unsafe_form(:mixed_compound_tenant_union, state) do
    left = ensure_compound_scope(state.query, "tenant-a")
    right = ensure_compound_scope(state.query, "tenant-b")
    Selecto.union(left, right)
  end

  defp apply_unsafe_form(:mixed_attached_tenant_union, state) do
    left = Selecto.with_tenant(state.query, %{tenant_id: "tenant-a", required: false})
    right = Selecto.with_tenant(state.query, %{tenant_id: "tenant-b", required: false})
    Selecto.union(left, right)
  end

  defp ensure_compound_scope(query, tenant_id) do
    query
    |> Selecto.with_tenant(
      Map.merge(Selecto.tenant(query) || %{}, %{tenant_id: tenant_id, required: true})
    )
    |> Selecto.apply_tenant_scope()
  end

  defp invariants do
    [
      {"tenant_scope_is_closed_under_supported_composition", &tenant_scope_closed/1},
      {"required_filters_are_closed_under_supported_composition", &required_filters_closed/1},
      {"strict_policy_is_closed_under_supported_composition", &strict_policy_closed/1},
      {"composed_scope_reaches_parameterized_sql", &parameterized_sql/1},
      {"post_set_structural_composition_fails_closed", &terminal_set_rejections/1},
      {"strict_mode_rejects_ad_hoc_composition", &strict_rejections/1}
    ]
  end

  defp tenant_scope_closed(%{scenario: :closure} = state) do
    state.query
    |> query_branches()
    |> Enum.reduce_while(:ok, fn query, :ok ->
      case Selecto.validate_tenant_scope(query) do
        :ok -> {:cont, :ok}
        other -> {:halt, {:error, %{invalid_scope: other, used: state.used}}}
      end
    end)
  end

  defp tenant_scope_closed(_state), do: :ok

  defp required_filters_closed(%{scenario: :closure} = state) do
    expected =
      [{"active", true}] ++
        if(state.tenant_mode == :row, do: [{"tenant_id", "tenant-a"}], else: [])

    missing =
      state.query
      |> query_branches()
      |> Enum.flat_map(fn query ->
        filters = Selecto.query_filters(query)
        Enum.map(expected -- filters, &%{query: query_summary(query), filter: &1})
      end)

    if missing == [], do: :ok, else: {:error, %{missing_required_filters: missing}}
  end

  defp required_filters_closed(_state), do: :ok

  defp strict_policy_closed(%{scenario: :closure} = state) do
    queries = query_branches(state.query)

    expected_policy? = state.policy_mode == :strict
    mismatched = Enum.reject(queries, &(Selecto.Policy.strict?(&1) == expected_policy?))

    cond do
      mismatched != [] ->
        {:error, %{policy_mismatches: Enum.map(mismatched, &query_summary/1)}}

      Selecto.Policy.validate_query!(state.query) == :ok ->
        :ok
    end
  end

  defp strict_policy_closed(_state), do: :ok

  defp parameterized_sql(%{scenario: :closure} = state) do
    {sql, params} = Selecto.to_sql(state.query)
    protected_branch_count = protected_branch_count(successful_forms(state))
    active_filter_count = Enum.count(params, &(&1 == true))
    tenant_param_count = Enum.count(params, &(&1 == "tenant-a"))

    cond do
      active_filter_count != protected_branch_count ->
        {:error,
         %{
           expected_required_filter_count: protected_branch_count,
           actual_required_filter_count: active_filter_count,
           sql: sql,
           params: params,
           used: state.used
         }}

      state.tenant_mode == :row and tenant_param_count != protected_branch_count ->
        {:error,
         %{
           expected_tenant_param_count: protected_branch_count,
           actual_tenant_param_count: tenant_param_count,
           sql: sql,
           params: params,
           used: state.used
         }}

      state.tenant_mode == :row and String.contains?(sql, "tenant-a") ->
        {:error, %{tenant_value_interpolated_into_sql: state.used}}

      state.tenant_mode == :prefix and tenant_param_count != 0 ->
        {:error, %{unexpected_row_tenant_params: params, used: state.used}}

      state.tenant_mode == :prefix and
          Selecto.Tenant.merge_execution_opts(state.query)[:prefix] != "tenant_a" ->
        {:error, %{tenant_prefix_lost: state.used}}

      true ->
        :ok
    end
  end

  defp parameterized_sql(_state), do: :ok

  defp protected_branch_count(used) do
    1 +
      Enum.count(used, &(&1 in [:named_cte, :named_subquery])) +
      Enum.count(used, &(&1 in @set_forms))
  end

  defp successful_forms(%{attempt: %{boundary: :terminal_set, outcome: :rejected}, used: used}),
    do: Enum.drop(used, -1)

  defp successful_forms(%{used: used}), do: used

  defp terminal_set_rejections(%{scenario: :closure, attempt: nil}), do: :ok

  defp terminal_set_rejections(%{
         scenario: :closure,
         attempt: %{
           boundary: :terminal_set,
           form: form,
           outcome: :rejected,
           query_unchanged?: true,
           message: message
         }
       }) do
    expected_operation = terminal_operation(form)

    if String.starts_with?(
         message,
         "#{expected_operation} cannot be applied after a set operation"
       ) do
      :ok
    else
      {:error,
       %{form: form, expected_operation: expected_operation, unexpected_rejection: message}}
    end
  end

  defp terminal_set_rejections(%{scenario: :closure, attempt: attempt}) do
    {:error, %{post_set_composition_did_not_fail_closed: attempt}}
  end

  defp terminal_set_rejections(_state), do: :ok

  defp terminal_operation(:declared_join), do: :join
  defp terminal_operation(:named_cte), do: :with_cte
  defp terminal_operation(:named_subquery), do: :with_subquery
  defp terminal_operation(:named_lateral), do: :with_lateral

  defp strict_rejections(%{scenario: :strict_rejection, attempt: nil}), do: :ok

  defp strict_rejections(%{
         scenario: :strict_rejection,
         attempt: %{form: form, outcome: :rejected, type: type}
       }) do
    expected = expected_rejection_type(form)

    if type == expected,
      do: :ok,
      else: {:error, %{form: form, expected: expected, actual: type}}
  end

  defp strict_rejections(%{scenario: :strict_rejection, attempt: attempt}) do
    {:error, %{strict_composition_was_not_rejected: attempt}}
  end

  defp strict_rejections(_state), do: :ok

  defp expected_rejection_type(:ad_hoc_join), do: :ad_hoc_join_forbidden
  defp expected_rejection_type(:ad_hoc_cte), do: :ad_hoc_source_forbidden
  defp expected_rejection_type(:ad_hoc_subquery), do: :ad_hoc_join_forbidden
  defp expected_rejection_type(:ad_hoc_lateral), do: :ad_hoc_source_forbidden
  defp expected_rejection_type(:mixed_policy_union), do: :mixed_query_policies
  defp expected_rejection_type(:mixed_row_tenant_union), do: :mixed_tenant_scopes
  defp expected_rejection_type(:mixed_prefix_tenant_union), do: :mixed_tenant_scopes
  defp expected_rejection_type(:mixed_compound_tenant_union), do: :mixed_tenant_scopes
  defp expected_rejection_type(:mixed_attached_tenant_union), do: :mixed_tenant_scopes

  defp query_branches(query) do
    nested =
      query.set
      |> Map.get(:set_operations, [])
      |> Enum.flat_map(fn spec ->
        query_branches(spec.left_query) ++ query_branches(spec.right_query)
      end)

    [query | nested]
  end

  defp base_query(policy_mode, tenant_mode), do: base_query(policy_mode, tenant_mode, "tenant-a")

  defp base_query(policy_mode, tenant_mode, tenant_identity) do
    opts = if policy_mode == :strict, do: [mode: :strict], else: []

    adapter = Selecto.Verification.QuerySafety.Adapter

    runtime = Selecto.Runtime.Context.new(adapter, :compile_only)

    domain()
    |> Selecto.configure(runtime, opts)
    |> Selecto.select(["id", "name"])
    |> attach_tenant(tenant_mode, tenant_identity)
  end

  defp attach_tenant(query, :row, tenant_id) do
    query
    |> Selecto.with_tenant(%{tenant_id: tenant_id, required: true})
    |> Selecto.apply_tenant_scope()
  end

  defp attach_tenant(query, :prefix, prefix) do
    normalized_prefix = if prefix == "tenant-a", do: "tenant_a", else: prefix
    Selecto.with_tenant(query, %{prefix: normalized_prefix, required: true})
  end

  defp domain do
    %{
      name: "Governed verification accounts",
      tenant_required: true,
      source: %{
        source_table: "accounts",
        primary_key: :id,
        fields: [:id, :name, :active, :tenant_id, :team_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          active: %{type: :boolean},
          tenant_id: %{type: :string},
          team_id: %{type: :integer}
        },
        associations: %{
          team: %{queryable: :team, field: :team, owner_key: :team_id, related_key: :id}
        }
      },
      schemas: %{
        team: %{
          source_table: "teams",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{team: %{name: "Team", type: :left, display_field: :name}},
      required_filters: [{"active", true}],
      query_members: %{
        ctes: %{
          scoped_accounts: %{
            query: &nested_query/1
          }
        },
        subqueries: %{
          scoped_accounts: %{
            query: &nested_query/1,
            type: :inner,
            on: [%{left: "id", right: "id"}]
          }
        },
        laterals: %{
          bounded_series: %{
            source: {:function, :bounded_row_source, [1, 2]},
            as: "bounded_series",
            join_type: :inner
          }
        },
        values: %{},
        unnests: %{}
      }
    }
  end

  defp nested_query(outer) do
    policy_mode = if Selecto.Policy.strict?(outer), do: :strict, else: :permissive

    tenant_mode =
      case Selecto.tenant(outer) do
        %{prefix: prefix} when is_binary(prefix) and prefix != "" -> :prefix
        _tenant -> :row
      end

    base_query(policy_mode, tenant_mode)
  end

  defp state_key(state) do
    {state.scenario, state.policy_mode, state.tenant_mode, state.used, state.attempt}
  end

  defp trace_state(state) do
    Map.take(state, [:scenario, :policy_mode, :tenant_mode, :used, :attempt])
  end

  defp query_summary(query) do
    %{
      strict?: Selecto.Policy.strict?(query),
      tenant: Selecto.tenant(query),
      required_filters: Selecto.required_filters(query)
    }
  end
end
