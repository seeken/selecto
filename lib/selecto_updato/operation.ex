defmodule SelectoUpdato.Operation do
  @moduledoc """
  Struct representing a write operation (insert, update, upsert, delete).

  The operation is built incrementally using the SelectoUpdato API functions,
  then compiled into portable intent for a configured Selecto adapter.
  """

  alias SelectoUpdato.DomainInput

  defstruct [
    :domain,
    :engine,
    :type,
    :attrs,
    :changes,
    :filters,
    :conflict_target,
    :returning,
    :expected_cardinality,
    :action_policy,
    :query_enforcement,
    :opts,
    :extensions
  ]

  @type operation_type :: :insert | :update | :upsert | :delete

  @type t :: %__MODULE__{
          domain: map() | nil,
          engine: Selecto.t() | nil,
          type: operation_type() | nil,
          attrs: map() | nil,
          changes: map() | nil,
          filters: [tuple()] | nil,
          conflict_target: [atom() | String.t()] | nil,
          returning: list() | atom() | nil,
          expected_cardinality:
            :many
            | {:exactly, non_neg_integer()}
            | {:at_most, non_neg_integer()}
            | {:at_least, non_neg_integer()}
            | {:between, non_neg_integer(), non_neg_integer()}
            | nil,
          action_policy: map() | nil,
          query_enforcement: map() | nil,
          opts: keyword() | nil,
          extensions: [{module(), keyword()}] | nil
        }

  @doc """
  Create a new operation for the given domain.
  """
  @spec new(map(), keyword()) :: t()
  def new(domain, opts \\ []) do
    domain = DomainInput.canonical_domain(domain)
    {domain, extension_specs} = SelectoUpdato.Extensions.apply_domain_extensions(domain)

    %__MODULE__{
      domain: domain,
      filters: [],
      opts: opts,
      extensions: extension_specs
    }
  end

  @doc """
  Add a filter condition to the operation.
  """
  @spec filter(t(), tuple()) :: t()
  def filter(%__MODULE__{filters: filters} = op, condition) do
    %{op | filters: filters ++ [condition]}
  end

  @doc """
  Add multiple filter conditions.
  """
  @spec filters(t(), [tuple()]) :: t()
  def filters(%__MODULE__{filters: existing} = op, conditions) do
    %{op | filters: existing ++ conditions}
  end

  @doc """
  Copy filters from a Selecto query.
  """
  @spec filter_from_selecto(t(), Selecto.t()) :: t()
  def filter_from_selecto(%__MODULE__{} = op, %Selecto{} = selecto) do
    filters(op, Selecto.query_filters(selecto))
  end

  @doc """
  Require this operation to remain eligible under a Selecto query.

  For updates and deletes, the query predicates are added atomically to the
  write predicate. For inserts, they are evaluated against the final candidate
  values before a command is dispatched. Projection, ordering, limit, and
  offset do not affect write enforcement.
  """
  @spec enforce_query(t(), Selecto.t(), keyword()) :: t()
  def enforce_query(%__MODULE__{} = op, %Selecto{} = selecto, opts \\ []) do
    evidence = SelectoUpdato.QueryEnforcement.capture(selecto, opts)

    # Query evidence never adds tenant authority. Only a host's trusted scope
    # (`host_scope: true`) may pin a two-column domain's sites (lesson 47b).
    evidence =
      if Keyword.get(opts, :host_scope) == true,
        do: Map.put(evidence, :host_scope, true),
        else: evidence

    %{op | query_enforcement: evidence}
  end

  @doc """
  Set the returning clause.

  The adapter validates and compiles the portable returning specification.
  """
  @spec returning(t(), list() | atom()) :: t()
  def returning(%__MODULE__{} = op, fields) do
    %{op | returning: fields}
  end

  @doc """
  Set the cardinality that the adapter must enforce atomically.

  Action planning uses this for concrete bulk targets so an adapter can roll
  back when the selected set and the affected set differ.
  """
  @spec expected_cardinality(t(), term()) :: t()
  def expected_cardinality(%__MODULE__{} = op, expected) do
    %{op | expected_cardinality: expected}
  end

  @doc false
  @spec put_action_policy(t(), map()) :: t()
  def put_action_policy(%__MODULE__{} = op, policy) when is_map(policy) do
    %{op | action_policy: policy}
  end

  @doc """
  Check if the operation has filters.
  """
  @spec has_filters?(t()) :: boolean()
  def has_filters?(%__MODULE__{filters: filters}) do
    length(filters) > 0
  end
end
