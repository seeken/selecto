defmodule SelectoUpdato do
  @moduledoc """
  Domain-governed portable write intent for Selecto domains.

  Updato validates an operation against the explicit `writes.*` contract and
  compiles portable `Selecto.Write.Command` data. It does not choose a driver,
  open a connection, emit SQL, or accept a repository target. The adapter
  configured on `%Selecto{}` owns preview, execution, and transactions.

  Updato is the governed entry point for writes. Every `execute/3` and `run/3`
  revalidates the operation against its domain's contract and passes the
  adapter a single-use `Selecto.Write.Authorization` for exactly the compiled
  command, batch, or graph; adapters refuse writes without one. A domain that
  declares no `writes.operations`, or no `writes.fields` for anything but a
  delete, fails with `:write_policy_missing`. An atomic `multi` may span
  domains; each operation is governed against its own domain, under one
  shared trusted context.

  The portable surface supports `insert`, `update`, `upsert`, and `delete`,
  atomic nested graphs, `multi` composition, and domain-enabled bulk actions
  over concrete selected ids. Nested graphs require authored owned-relationship
  policy; changesets, audit callbacks, and implicit cascades remain outside the
  portable compiler.
  """

  alias SelectoUpdato.{Error, Operation, PlannedOperation, Tenant}

  @new_option_keys [
    :timeout,
    :tenant,
    :choice_source_domain,
    :choice_source_membership_resolver,
    :choice_source_context,
    :choice_source_filters
  ]
  @new_options_schema [
    timeout: [type: :non_neg_integer],
    tenant: [type: :any],
    choice_source_domain: [type: :map],
    choice_source_membership_resolver: [type: {:fun, 1}],
    choice_source_context: [type: :map],
    choice_source_filters: [type: {:list, :any}]
  ]
  @execute_option_keys [:result, :context, :committed_effect_sink, :candidate_state_provider]
  @execute_options_schema [
    result: [type: {:in, [:envelope, :raw]}],
    context: [type: :map],
    committed_effect_sink: [type: {:fun, 3}],
    candidate_state_provider: [type: {:fun, 1}]
  ]

  # Compiled once here: NimbleOptions.validate!/2 with a keyword schema
  # revalidates the schema itself on every call.
  @compiled_new_options_schema NimbleOptions.new!(@new_options_schema)
  @compiled_execute_options_schema NimbleOptions.new!(@execute_options_schema)

  @type t :: Operation.t()
  @type result :: {:ok, term()} | {:error, term()}

  @spec validate_domain(map()) :: :ok | {:error, SelectoUpdato.Error.t()}
  def validate_domain(domain) when is_map(domain),
    do: SelectoUpdato.WriteContract.validate_writes_shape(domain)

  @spec validate_domain!(map()) :: :ok
  def validate_domain!(domain) when is_map(domain) do
    case validate_domain(domain) do
      :ok ->
        :ok

      {:error, error} ->
        raise ArgumentError, "invalid SelectoUpdato domain contract: #{error.message}"
    end
  end

  @spec domain_contract(term()) :: SelectoUpdato.DomainContract.result()
  def domain_contract(input), do: SelectoUpdato.DomainContract.build(input)

  @spec validate_domain_intent(term(), map(), keyword()) ::
          SelectoUpdato.DomainContract.IntentValidator.result()
  def validate_domain_intent(input, intent, opts \\ []),
    do: SelectoUpdato.DomainContract.validate_intent(input, intent, opts)

  @spec plan_domain_action(term(), map(), keyword()) :: SelectoUpdato.ActionPlanner.result()
  def plan_domain_action(input, intent, opts \\ []),
    do: SelectoUpdato.ActionPlanner.plan(input, intent, opts)

  @spec authorize_domain_action(
          SelectoUpdato.ActionPlan.t(),
          :preview | :execute,
          map(),
          keyword()
        ) ::
          {:ok, SelectoUpdato.CapabilityDecision.t()} | {:error, term()}
  def authorize_domain_action(plan, phase, context \\ %{}, opts \\ []),
    do: SelectoUpdato.CapabilityResolver.authorize_action(plan, phase, context, opts)

  @spec new(map(), keyword()) :: t()
  def new(domain, opts \\ [])

  def new(%Selecto{} = engine, opts) do
    operation = new(engine.domain, opts)
    required = engine_required_filters(engine)

    operation =
      if required == [], do: operation, else: enforce_engine_scope(operation, engine, required)

    %{operation | engine: engine}
  end

  def new(domain, opts) do
    validate_known_options!(opts, @new_option_keys, @compiled_new_options_schema)

    operation = Operation.new(domain, opts)

    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant_context} -> Tenant.with_tenant(operation, tenant_context)
      :error -> operation
    end
  end

  @doc false
  def engine_required_filters(engine) do
    tenant = Selecto.tenant(engine) || %{}
    field = Selecto.Tenant.domain_tenant_field(engine)

    Enum.reject(Selecto.required_filters(engine), fn
      {key, value} when is_atom(key) or is_binary(key) ->
        to_string(key) == field and value === Map.get(tenant, :tenant_id) and not is_nil(value)

      _ ->
        false
    end)
  end

  defp enforce_engine_scope(operation, engine, required) do
    evidence =
      SelectoUpdato.QueryEnforcement.capture(engine)
      |> Map.put(:filters, required)
      |> Map.put(:host_scope, true)

    %{operation | query_enforcement: evidence}
  end

  @doc "Start an engine-bound named action using native planning and authorization."
  def action(%Selecto{} = engine, name), do: SelectoUpdato.NativeAction.new(engine, name)
  defdelegate inputs(action, values), to: SelectoUpdato.NativeAction
  defdelegate target(action, value), to: SelectoUpdato.NativeAction

  @doc "Preview an engine-bound write or action without repeating its engine."
  def preview(%Operation{engine: %Selecto{} = engine} = operation),
    do: preview(operation, engine, [])

  def preview(%SelectoUpdato.NativeAction{} = action),
    do: SelectoUpdato.NativeAction.preview(action, [])

  @doc "Execute an engine-bound write or action without repeating its engine."
  def execute(%Operation{engine: %Selecto{} = engine} = operation),
    do: execute(operation, engine, [])

  def execute(%SelectoUpdato.NativeAction{} = action),
    do: SelectoUpdato.NativeAction.execute(action, [])

  defdelegate insert(operation, attrs), to: SelectoUpdato.Insert
  defdelegate update(operation, changes), to: SelectoUpdato.Update
  defdelegate upsert(operation, attrs), to: SelectoUpdato.Upsert
  defdelegate conflict_target(operation, target), to: SelectoUpdato.Upsert
  defdelegate delete(operation), to: SelectoUpdato.Delete
  defdelegate filter(operation, condition), to: Operation
  defdelegate filters(operation, conditions), to: Operation
  defdelegate enforce_query(operation, selecto, opts \\ []), to: Operation
  defdelegate returning(operation, fields), to: Operation
  defdelegate expected_cardinality(operation, expected), to: Operation
  defdelegate with_tenant(operation, tenant_context), to: SelectoUpdato.Tenant
  defdelegate tenant(operation), to: SelectoUpdato.Tenant
  defdelegate apply_tenant_scope(operation, opts \\ []), to: SelectoUpdato.Tenant
  defdelegate apply_execution_scope(operation, opts \\ []), to: SelectoUpdato.Tenant
  defdelegate applied_scope(operation), to: SelectoUpdato.Tenant
  defdelegate tenant_required?(operation, opts \\ []), to: SelectoUpdato.Tenant

  defdelegate validate_tenant_scope(operation, opts \\ []),
    to: SelectoUpdato.Tenant,
    as: :validate_scope

  defdelegate ensure_tenant_scope!(operation, opts \\ []),
    to: SelectoUpdato.Tenant,
    as: :ensure_scope!

  @spec require_tenant_filter(t(), tuple()) :: t()
  @spec require_tenant_filter(t(), atom() | String.t(), term()) :: t()
  def require_tenant_filter(operation, {_, _} = filter),
    do: SelectoUpdato.Tenant.require_tenant_filter(operation, filter)

  def require_tenant_filter(operation, tenant_field, tenant_id),
    do: SelectoUpdato.Tenant.require_tenant_filter(operation, tenant_field, tenant_id)

  @spec execute(t() | PlannedOperation.t(), Selecto.t(), keyword()) :: result()
  def execute(%SelectoUpdato.NativeAction{} = action, opts) when is_list(opts),
    do: SelectoUpdato.NativeAction.execute(action, opts)

  def execute(%Operation{engine: %Selecto{} = engine} = operation, opts) when is_list(opts),
    do: execute(operation, engine, opts)

  def execute(%PlannedOperation{}, _target), do: opaque_planned_operation_error()
  def execute(operation, %Selecto{} = selecto), do: execute(operation, selecto, [])

  def execute(operation, _target),
    do: SelectoUpdato.Executor.execute(operation, :invalid_selecto, [])

  def execute(%PlannedOperation{}, _target, _opts), do: opaque_planned_operation_error()

  def execute(operation, %Selecto{} = selecto, opts) do
    validate_known_options!(opts, @execute_option_keys, @compiled_execute_options_schema)
    SelectoUpdato.Executor.execute(operation, selecto, opts)
  end

  def execute(operation, _target, _opts),
    do: SelectoUpdato.Executor.execute(operation, :invalid_selecto, [])

  @spec preview(t() | PlannedOperation.t(), Selecto.t(), keyword()) ::
          {:ok, Selecto.Write.Preview.t()} | {:error, SelectoUpdato.Error.t()}
  def preview(operation, selecto, opts \\ [])

  def preview(%SelectoUpdato.NativeAction{} = action, opts, []) when is_list(opts),
    do: SelectoUpdato.NativeAction.preview(action, opts)

  def preview(%Operation{engine: %Selecto{} = engine} = operation, opts, []) when is_list(opts),
    do: preview(operation, engine, opts)

  def preview(%PlannedOperation{}, _target, _opts), do: opaque_planned_operation_error()

  def preview(operation, %Selecto{} = selecto, opts) do
    validate_known_options!(opts, @execute_option_keys, @compiled_execute_options_schema)
    SelectoUpdato.Executor.preview(operation, selecto, opts)
  end

  @spec dry_run(t() | PlannedOperation.t(), Selecto.t()) ::
          {:ok, Selecto.Write.Preview.t()} | {:error, term()}
  def dry_run(%PlannedOperation{}, _target), do: opaque_planned_operation_error()
  def dry_run(operation, selecto), do: SelectoUpdato.Executor.dry_run(operation, selecto)

  @spec multi() :: term()
  def multi, do: SelectoUpdato.Multi.multi()

  def multi_insert(multi, name, domain, attrs),
    do: SelectoUpdato.Multi.multi_insert(multi, name, domain, attrs)

  def multi_update(multi, name, domain, opts),
    do: SelectoUpdato.Multi.multi_update(multi, name, domain, opts)

  def run(multi, selecto, opts \\ []), do: SelectoUpdato.Multi.run(multi, selecto, opts)

  defp opaque_planned_operation_error do
    {:error,
     Error.new(:authorization, "Planned actions must execute through ActionExecutionAdapter",
       details: %{code: :opaque_planned_operation}
     )}
  end

  # Neither schema has a required option, so no options at all is always
  # valid.
  defp validate_known_options!([], _keys, _schema), do: :ok

  defp validate_known_options!(opts, keys, schema) when is_list(opts) do
    opts |> Keyword.take(keys) |> NimbleOptions.validate!(schema)
    :ok
  end
end
