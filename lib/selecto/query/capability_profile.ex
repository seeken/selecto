defmodule Selecto.Query.CapabilityProfile do
  @moduledoc "Connection-aware enabled and certified source-query capabilities."
  @derive Jason.Encoder
  defstruct [
    :backend,
    :version,
    deployment: %{},
    enabled: [],
    certified: [],
    limits: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  def preflight(%__MODULE__{} = profile, plan) do
    with true <- is_binary(profile.version) and profile.version != "",
         true <- is_list(profile.enabled) and is_list(profile.certified),
         true <- is_map(profile.limits),
         true <-
           Enum.all?(
             plan.required_capabilities,
             &(&1 in profile.enabled and &1 in profile.certified)
           ),
         true <-
           Enum.all?(plan.bounds, fn {key, value} ->
             maximum = profile.limits[key]
             is_integer(maximum) and maximum >= value
           end) do
      :ok
    else
      _ ->
        {:error,
         Selecto.Error.validation_error(
           "Source capabilities or deployment limits do not satisfy the query"
         )}
    end
  end

  def preflight(_, _),
    do: {:error, Selecto.Error.validation_error("Invalid source capability profile")}
end
