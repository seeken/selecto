defmodule SelectoUpdato.CapabilityDecision do
  @moduledoc """
  Normalized policy decision for capability-gated Updato actions.

  Host applications may answer capability checks with this struct, with atoms
  such as `:enabled` / `:disabled` / `:hidden`, or with small maps. Updato
  normalizes those shapes before previewing or executing a domain action.

  Status classification is delegated to the shared ecosystem kernel
  `Selecto.Capabilities.parse_decision/1`; this module layers Updato's
  write-phase vocabulary (`:enabled` / `:disabled` / `:hidden`) and its own
  error-tuple policy on top of it. A legacy fallback keeps normalization
  working against pinned selecto revisions that predate the kernel.
  """

  @statuses [:enabled, :disabled, :hidden]

  @type status :: :enabled | :disabled | :hidden

  @type t :: %__MODULE__{
          status: status(),
          capability: term(),
          reason: String.t() | nil,
          code: atom() | nil,
          audit: map(),
          metadata: map()
        }

  defstruct status: :enabled,
            capability: nil,
            reason: nil,
            code: nil,
            audit: %{},
            metadata: %{}

  @doc """
  Returns true when a decision allows the requested action phase.
  """
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{status: :enabled}), do: true
  def enabled?(_decision), do: false

  @doc """
  Converts a decision into a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    %{
      status: decision.status,
      capability: decision.capability,
      reason: decision.reason,
      code: decision.code,
      audit: decision.audit,
      metadata: decision.metadata
    }
  end

  @doc false
  @spec normalize(term(), term()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = decision, capability) do
    {:ok, %{decision | capability: decision.capability || capability}}
  end

  def normalize(input, capability) do
    case classify(input) do
      {:ok, {canonical_status, visibility}} ->
        {:ok,
         %__MODULE__{
           status: updato_status(canonical_status, visibility),
           capability: shape_value(input, :capability) || capability,
           reason: shape_reason(input),
           code: shape_value(input, :code),
           audit: shape_value(input, :audit) || %{},
           metadata: shape_value(input, :metadata) || %{}
         }}

      :error ->
        {:error, {:invalid_capability_decision, input}}
    end
  end

  defp classify(input) do
    # Code.ensure_loaded?/1 handles a cold VM where the module is not loaded
    # yet, and apply/3 avoids compile-time references that would fail a
    # warnings-as-errors build against selecto revisions lacking the kernel.
    kernel = Selecto.Capabilities

    if Code.ensure_loaded?(kernel) and function_exported?(kernel, :parse_decision, 1) do
      apply(kernel, :parse_decision, [input])
    else
      legacy_parse_decision(input)
    end
  end

  defp legacy_parse_decision(status) when status in [:enabled, "enabled", :allow],
    do: {:ok, {:allow, :enabled}}

  defp legacy_parse_decision(status) when status in [:disabled, "disabled", :deny],
    do: {:ok, {:deny, :disabled}}

  defp legacy_parse_decision(status) when status in [:hidden, "hidden"],
    do: {:ok, {:deny, :hidden}}

  defp legacy_parse_decision(true), do: {:ok, {:allow, :enabled}}
  defp legacy_parse_decision(false), do: {:ok, {:deny, :disabled}}

  defp legacy_parse_decision({status, reason}) when is_binary(reason) do
    case legacy_parse_decision(status) do
      {:ok, _pair} = ok -> ok
      :error -> :error
    end
  end

  defp legacy_parse_decision(%{} = map) do
    status = map_value(map, :status)

    case status do
      :enabled -> {:ok, {:allow, :enabled}}
      :allow -> {:ok, {:allow, :enabled}}
      :disabled -> {:ok, {:deny, :disabled}}
      :deny -> {:ok, {:deny, :disabled}}
      :hidden -> {:ok, {:deny, :hidden}}
      _other -> :error
    end
  end

  defp legacy_parse_decision(_input), do: :error

  defp updato_status(:allow, _visibility), do: :enabled
  defp updato_status(:deny, :hidden), do: :hidden
  defp updato_status(:deny, _visibility), do: :disabled
  defp updato_status(:conditional, _visibility), do: :disabled
  defp updato_status(:not_applicable, _visibility), do: :hidden

  defp shape_value(%{} = map, key), do: map_value(map, key)
  defp shape_value(_input, _key), do: nil

  defp shape_reason({status, reason}) when is_binary(reason) and status in @statuses, do: reason
  defp shape_reason(%{} = map), do: map_value(map, :reason)
  defp shape_reason(_input), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
