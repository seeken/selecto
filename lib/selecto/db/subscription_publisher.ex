defmodule Selecto.DB.SubscriptionPublisher do
  @moduledoc """
  Database-native source boundary for Domain Subscription publishers.

  Implementations expose a snapshot watermark and an ordered, resumable change
  feed. They do not construct wire envelopes, authorize subscriptions, or write
  to a Domain Store; those responsibilities stay with the publisher service and
  the receiving store.

  A publisher is usable only when every invariant returned by
  `publisher_capabilities/2` is `true`. This makes partial CDC support fail
  closed instead of silently creating a snapshot/change gap.
  """

  @required_invariants ~w(tenant_scope snapshot_watermark ordered_changes durable_resume postimage_or_requery)a

  @type capability_result ::
          {:ok,
           %{
             required(:backend) => atom(),
             required(:available) => boolean(),
             required(:invariants) => %{required(atom()) => boolean()},
             optional(:reason) => atom(),
             optional(:metadata) => map()
           }}
          | {:error, term()}

  @callback publisher_capabilities(connection :: term(), context :: map()) :: capability_result()
  @callback begin_snapshot(connection :: term(), source :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback snapshot_page(connection :: term(), snapshot :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback changes(connection :: term(), cursor :: term(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Returns `:ok` only for a complete publisher profile."
  @spec preflight(module(), term(), map()) :: :ok | {:error, term()}
  def preflight(adapter, connection, context \\ %{}) do
    with {:ok, profile} <- adapter.publisher_capabilities(connection, context),
         true <- profile.available,
         invariants when is_map(invariants) <- profile.invariants,
         [] <- Enum.reject(@required_invariants, &Map.get(invariants, &1, false)) do
      :ok
    else
      false -> {:error, :subscription_publisher_unavailable}
      [_ | _] = missing -> {:error, {:missing_publisher_invariants, missing}}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_publisher_capabilities}
    end
  end

  @doc "The invariant names every implementation must affirm."
  def required_invariants, do: @required_invariants

  @doc "Builds a uniform fail-closed profile while an adapter lacks a complete handoff."
  @spec unavailable(atom(), atom(), map(), map()) :: capability_result()
  def unavailable(backend, reason, affirmed \\ %{}, metadata \\ %{}) do
    invariants = Map.new(@required_invariants, &{&1, Map.get(affirmed, &1, false)})

    {:ok,
     %{
       backend: backend,
       available: false,
       reason: reason,
       invariants: invariants,
       metadata: metadata
     }}
  end
end
