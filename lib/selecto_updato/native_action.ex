defmodule SelectoUpdato.NativeAction do
  @moduledoc """
  Engine-bound action draft. Each inspection or execution plans and authorizes
  again through the native action boundary. The built-in adapter supports flat
  governed writes; collection and event-stream actions require an explicitly
  supplied host `:action_execution_adapter`.
  """
  alias SelectoUpdato.{ActionExecutionAdapter, Error, Operation}

  @enforce_keys [:engine, :name]
  defstruct [:engine, :name, :target, inputs: %{}]

  def new(%Selecto{} = engine, name) when is_atom(name) or is_binary(name),
    do: %__MODULE__{engine: engine, name: name}

  def inputs(%__MODULE__{} = action, values) when is_map(values), do: %{action | inputs: values}
  def target(%__MODULE__{} = action, value), do: %{action | target: value}

  def preview(action, opts), do: dispatch(action, opts, :dry_run)
  def execute(action, opts), do: dispatch(action, opts, :execute)

  defp dispatch(%__MODULE__{} = action, opts, phase) do
    with {:ok, context} <- bound_context(action.engine, opts),
         {:ok, plan} <-
           SelectoUpdato.plan_domain_action(
             required_scope(action.engine),
             %{
               action: action.name,
               target: action.target,
               inputs: action.inputs
             },
             trusted_context: context
           ) do
      adapter = Keyword.get(opts, :action_execution_adapter, __MODULE__)
      apply(ActionExecutionAdapter, phase, [adapter, plan, context, opts])
    end
  end

  # Optional read filters are not action authority. Preserve the bound tenant
  # and required host predicates before the native plan is sealed.
  defp required_scope(engine) do
    set = engine.set |> Map.put(:filtered, []) |> Map.put(:post_retarget_filters, [])
    %{engine | set: set}
  end

  defp bound_context(engine, opts) do
    context = Keyword.get(opts, :context, %{})
    tenant = Selecto.tenant(engine)
    identities = [context, Map.new(Keyword.take(opts, [:tenant, :tenant_id, :tenant_field]))]

    if Enum.any?(identities, &conflicting_identity?(&1, tenant)) or
         (Map.has_key?(context, :query_target) and context.query_target !== engine) do
      {:error, Error.new(:tenant_mismatch, "Action context conflicts with its bound engine")}
    else
      context = Map.put(context, :query_target, engine)

      context =
        if tenant,
          do:
            Map.merge(context, %{
              tenant: tenant,
              tenant_id: tenant.tenant_id,
              tenant_field: tenant.tenant_field
            }),
          else: context

      {:ok, context}
    end
  end

  defp conflicting_identity?(_context, nil), do: false

  defp conflicting_identity?(context, tenant) do
    supplied = value(context, :tenant)
    supplied = if is_nil(supplied), do: nil, else: Selecto.Tenant.normalize_context(supplied)

    Enum.any?([:tenant_id, :tenant_field], fn key ->
      expected = Map.get(tenant, key)

      Enum.any?([value(context, key), supplied && Map.get(supplied, key)], fn given ->
        not is_nil(given) and given !== expected
      end)
    end)
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @behaviour SelectoUpdato.ActionExecutionAdapter
  @impl true
  def execute_action(plan, context, opts), do: invoke_write(plan, context, opts, :execute)
  @impl true
  def dry_run_action(plan, context, opts), do: invoke_write(plan, context, opts, :preview)

  defp invoke_write(
         %{operation_builder: %Operation{} = operation, collection_operations: collections},
         context,
         opts,
         phase
       )
       when collections == %{} do
    apply(SelectoUpdato, phase, [
      operation,
      context.query_target,
      Keyword.put(opts, :context, context)
    ])
  end

  defp invoke_write(_plan, _context, _opts, _phase),
    do:
      {:error,
       Error.new(
         :unsupported_action_execution_adapter,
         "This action requires a host execution adapter"
       )}
end
