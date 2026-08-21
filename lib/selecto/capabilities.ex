defmodule Selecto.Capabilities do
  @moduledoc """
  Shared capability request and decision helpers.

  Selecto owns the shape of capability questions and answers, but host
  applications remain responsible for policy truth. These helpers are small
  value constructors for adapters, components, write paths, and API layers that
  need to ask the same kind of question.
  """

  alias Selecto.Capabilities.{Decision, Request}

  @type capability_id :: atom() | String.t()
  @type operation :: atom() | String.t()
  @type target :: map()
  @type context :: map()
  @type resolver ::
          module()
          | (Request.t() -> term())
          | (Request.t(), map() -> term())
          | {module(), atom()}

  @doc """
  Builds a capability request.
  """
  @spec request(map() | keyword()) :: Request.t()
  def request(attrs), do: Request.new(attrs)

  @doc """
  Resolves one capability request through a host resolver.

  Supported resolver shapes are:

  - a one-arity function receiving the request
  - a two-arity function receiving the request and resolver context
  - a module implementing the `Selecto.Capabilities.Resolver` behaviour
  - `{module, function}` where the function has arity 2

  Resolver return values are normalized to `Selecto.Capabilities.Decision`.
  """
  @spec decide(resolver() | nil, Request.t(), keyword() | map()) :: Decision.t()
  def decide(resolver, %Request{} = request, opts \\ []) do
    context = resolver_context(opts)

    resolver
    |> invoke_decide(request, context)
    |> normalize_decision()
  end

  @doc """
  Resolves many capability requests.

  Module resolvers can implement `decide_many/2` for a true batch path. Other
  resolver shapes fall back to `decide/3` for each request while preserving
  request order.
  """
  @spec decide_many(resolver() | nil, [Request.t()], keyword() | map()) :: [Decision.t()]
  def decide_many(resolver, requests, opts \\ []) when is_list(requests) do
    context = resolver_context(opts)

    case invoke_decide_many(resolver, requests, context) do
      :fallback ->
        Enum.map(requests, &decide(resolver, &1, opts))

      result ->
        normalize_decisions(result, length(requests))
    end
  end

  @doc """
  Builds an allow decision.
  """
  @spec allow(atom() | String.t(), map() | keyword()) :: Decision.t()
  def allow(reason_code \\ :allowed, attrs \\ []) do
    Decision.allow(reason_code, attrs)
  end

  @doc """
  Builds a deny decision.
  """
  @spec deny(atom() | String.t(), map() | keyword()) :: Decision.t()
  def deny(reason_code \\ :denied, attrs \\ []) do
    Decision.deny(reason_code, attrs)
  end

  @doc """
  Builds a hidden deny decision.
  """
  @spec hidden(atom() | String.t(), map() | keyword()) :: Decision.t()
  def hidden(reason_code \\ :hidden, attrs \\ []) do
    Decision.hidden(reason_code, attrs)
  end

  @doc """
  Builds a conditional preview-only decision.
  """
  @spec preview_only(atom() | String.t(), map() | keyword()) :: Decision.t()
  def preview_only(reason_code \\ :preview_only, attrs \\ []) do
    Decision.preview_only(reason_code, attrs)
  end

  @doc """
  Builds a not-applicable decision.
  """
  @spec not_applicable(atom() | String.t(), map() | keyword()) :: Decision.t()
  def not_applicable(reason_code \\ :not_applicable, attrs \\ []) do
    Decision.not_applicable(reason_code, attrs)
  end

  @doc """
  Shared normalization kernel for loose host-provided capability answers.

  Classifies a decision shape of any supported spelling into its canonical
  `{status, visibility}` pair:

  - booleans (`true` -> allow/enabled, `false` -> deny/disabled)
  - canonical atoms (`:allow`, `:deny`, `:hidden`, `:conditional`,
    `:preview_only`, `:not_applicable`)
  - write-phase shorthand atoms (`:enabled`, `:disabled`) and their string
    spellings
  - `{status, reason}` tuples where the reason is a binary
  - atom- or string-keyed maps carrying a `status`, `decision`, or
    `visibility` key, with an optional independent `visibility` override

  Returns `{:ok, {status, visibility}}` or `:error` when the shape carries no
  recognizable status. Callers layer their own policy on top of `:error`
  (this module fails closed; `SelectoUpdato.CapabilityDecision` returns an
  error tuple).

  This is the single vocabulary mapping shared across the Selecto ecosystem;
  adapters and sibling libraries should normalize through it rather than
  maintaining parallel status tables.
  """
  @spec parse_decision(term()) :: {:ok, {Decision.status(), Decision.visibility()}} | :error
  def parse_decision(%Decision{} = decision),
    do: {:ok, {decision.status, decision.visibility}}

  def parse_decision(true), do: {:ok, {:allow, :enabled}}
  def parse_decision(false), do: {:ok, {:deny, :disabled}}

  for {canonical, visibility, spellings} <- [
        {:allow, :enabled, [:allow, :enabled]},
        {:deny, :disabled, [:deny, :disabled]},
        {:deny, :hidden, [:hidden]},
        {:conditional, :preview_only, [:conditional, :preview_only]},
        {:not_applicable, :hidden, [:not_applicable]}
      ] do
    def parse_decision(status) when status in unquote(spellings),
      do: {:ok, {unquote(canonical), unquote(visibility)}}

    def parse_decision(status)
        when is_binary(status) and status in unquote(spellings ++ Enum.map(spellings, &Atom.to_string/1)),
        do: {:ok, {unquote(canonical), unquote(visibility)}}
  end

  def parse_decision({status, reason}) when is_binary(reason) do
    case parse_decision(status) do
      {:ok, _pair} = ok -> ok
      :error -> :error
    end
  end

  def parse_decision(%{} = attrs) do
    # `status` / `decision` classify the decision. A bare `visibility`
    # spelling classifies only when no status key is present at all; a
    # status key that is present but unrecognized fails closed.
    raw_status = get_attr(attrs, :status) || get_attr(attrs, :decision)

    case {raw_status, classify_status(raw_status)} do
      {_present_or_nil, {:ok, {status, implied_visibility}}} ->
        {:ok,
         {status,
          override_visibility(get_attr(attrs, :visibility), implied_visibility)}}

      {nil, :error} ->
        classify_status(get_attr(attrs, :visibility))

      {_unrecognized, :error} ->
        :error
    end
  end

  def parse_decision(_shape), do: :error

  defp override_visibility(raw_visibility, default_visibility) do
    case parse_decision(raw_visibility) do
      {:ok, {_status, visibility}} -> visibility
      :error -> default_visibility
    end
  end

  @doc """
  Normalizes any loose resolver answer into a canonical `Decision`.

  Accepts everything `parse_decision/1` accepts (plus `Decision` structs,
  `{:ok, decision}` / `{:error, reason}` tuples, and maps with extra fields
  such as `effects` or `obligations`). Invalid shapes fail closed to a deny
  decision rather than raising.
  """
  @spec normalize_decision(term()) :: Decision.t()
  def normalize_decision({:ok, decision}), do: normalize_decision(decision)

  def normalize_decision({:error, reason}) do
    deny(:resolver_error,
      user_message: inspect(reason),
      metadata: %{reason: reason}
    )
  end

  def normalize_decision(%Decision{} = decision), do: decision

  def normalize_decision(nil), do: allow(:no_decision)

  def normalize_decision(shape) do
    case parse_decision(shape) do
      {:ok, {status, visibility}} ->
        build_normalized_decision(shape, status, visibility)

      :error when is_map(shape) ->
        # Unrecognized or missing status spelling: fail closed while keeping
        # whatever context the resolver provided. Never raise on policy data.
        shape
        |> Map.put(:status, :deny)
        |> force_valid_visibility()
        |> copy_parsed_attrs(shape)
        |> Decision.new()

      :error ->
        deny(:invalid_decision)
    end
  end

  defp force_valid_visibility(attrs) do
    case parse_decision(get_attr(attrs, :visibility)) do
      {:ok, {_status, visibility}} -> Map.put(attrs, :visibility, visibility)
      :error -> Map.put(attrs, :visibility, :disabled)
    end
  end

  defp build_normalized_decision(%{} = attrs, status, visibility) do
    # `visibility` from parse/1 already accounts for any valid explicit
    # override; overwrite so an invalid spelling cannot reach Decision.new.
    attrs
    |> Map.put(:status, status)
    |> Map.put(:visibility, visibility)
    |> copy_parsed_attrs(attrs)
    |> Decision.new()
  end

  defp build_normalized_decision(shape, status, visibility) do
    case {status, shape} do
      {_status, {status, reason}} when is_binary(reason) ->
        Decision.new(
          status: status,
          visibility: visibility,
          user_message: reason
        )

      {status, _} ->
        Decision.new(status: status, visibility: visibility)
    end
  end

  defp copy_parsed_attrs(target, source) do
    user_message = get_attr(source, :user_message) || get_attr(source, :reason)
    reason_code = get_attr(source, :reason_code) || get_attr(source, :code)

    target
    |> maybe_put_attr(:user_message, user_message)
    |> maybe_put_attr(:reason_code, reason_code)
    |> maybe_put_attr(:metadata, get_attr(source, :metadata))
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put_new(attrs, key, value)

  defp classify_status(raw_status) do
    # Preserve the visibility implied by the matched spelling (e.g. `hidden`
    # implies deny + hidden); an explicit `visibility` attr may still override.
    case parse_decision(raw_status) do
      {:ok, {status, visibility}} -> {:ok, {status, visibility}}
      :error -> :error
    end
  end

  defp invoke_decide(nil, _request, _context), do: allow(:no_resolver)

  defp invoke_decide(resolver, request, _context) when is_function(resolver, 1),
    do: resolver.(request)

  defp invoke_decide(resolver, request, context) when is_function(resolver, 2),
    do: resolver.(request, context)

  defp invoke_decide({module, function}, request, context)
       when is_atom(module) and is_atom(function) do
    apply(module, function, [request, context])
  end

  defp invoke_decide(module, request, context) when is_atom(module) do
    if function_exported?(module, :decide, 2) do
      module.decide(request, context)
    else
      deny(:resolver_missing_decide,
        user_message: "Capability resolver does not implement decide/2.",
        metadata: %{resolver: inspect(module)}
      )
    end
  end

  defp invoke_decide(_resolver, _request, _context) do
    deny(:invalid_resolver, user_message: "Capability resolver is invalid.")
  end

  defp invoke_decide_many(module, requests, context) when is_atom(module) do
    cond do
      function_exported?(module, :decide_many, 2) ->
        module.decide_many(requests, context)

      function_exported?(module, :decide, 2) ->
        :fallback

      true ->
        {:error, :resolver_missing_decide}
    end
  end

  defp invoke_decide_many(_resolver, _requests, _context), do: :fallback

  defp normalize_decisions({:ok, decisions}, expected_count),
    do: normalize_decisions(decisions, expected_count)

  defp normalize_decisions({:error, reason}, expected_count) do
    List.duplicate(
      deny(:resolver_error,
        user_message: inspect(reason),
        metadata: %{reason: reason}
      ),
      expected_count
    )
  end

  defp normalize_decisions(decisions, expected_count) when is_list(decisions) do
    decisions
    |> Enum.map(&normalize_decision/1)
    |> case do
      normalized when length(normalized) == expected_count ->
        normalized

      normalized ->
        normalized ++
          List.duplicate(
            deny(:resolver_result_count_mismatch,
              user_message: "Capability resolver returned the wrong number of decisions."
            ),
            max(expected_count - length(normalized), 0)
          )
    end
    |> Enum.take(expected_count)
  end

  defp normalize_decisions(decision, expected_count) do
    List.duplicate(normalize_decision(decision), expected_count)
  end

  defp resolver_context(opts) when is_list(opts) do
    opts
    |> Keyword.get(:resolver_context, Keyword.get(opts, :context, %{}))
    |> map_or_empty()
  end

  defp resolver_context(%{} = opts) do
    opts
    |> Map.get(:resolver_context, Map.get(opts, "resolver_context", Map.get(opts, :context, %{})))
    |> map_or_empty()
  end

  defp resolver_context(_opts), do: %{}

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp get_attr(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
