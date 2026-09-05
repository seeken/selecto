defmodule Selecto.Write.DocumentMutation do
  @moduledoc """
  Portable, single-document action intent attached to `Command.metadata.document`.

  The first profile supports one identified array object and one positive integer
  increment. Paths are parsed object-key lists; positional indices and native
  expressions are not accepted. Missing, null, non-integer, or duplicate element
  matches must fail atomically. Adapters also increment the protected version and
  persist the idempotency receipt and effect records in the same document write.
  """

  alias Selecto.Write.Error
  alias Selecto.Document.ObjectId

  @capabilities [
    :document_mutations,
    :document_expected_version,
    :document_idempotency,
    :document_update_element,
    :document_effect_receipts
  ]
  @enforce_keys [
    :identity,
    :tenant,
    :version,
    :mutations,
    :action,
    :idempotency_key,
    :payload_digest,
    :scope_digest,
    :shape_version,
    :shape_digest,
    :effects
  ]
  defstruct @enforce_keys ++ [shape_features: []]

  @type t :: %__MODULE__{}

  def capabilities, do: @capabilities

  @doc "Required write capabilities include the attached release's shape refinements."
  def capabilities(%__MODULE__{shape_features: features}) do
    @capabilities ++
      if(is_list(features) and "object_id" in features,
        do: [:document_object_id],
        else: []
      ) ++
      if(is_list(features) and "object_relation" in features,
        do: [:document_object_relation],
        else: []
      ) ++
      if(is_list(features) and "scalar_array" in features,
        do: [:document_scalar_array],
        else: []
      )
  end

  @doc "Validate the portable mutation independently of adapter support."
  def validate(%__MODULE__{} = mutation) do
    with :ok <- selector(mutation.identity),
         :ok <- tenant_selector(mutation.tenant),
         :ok <- version(mutation.version),
         :ok <- validate_mutations(mutation),
         true <- valid_name?(mutation.action),
         true <- valid_name?(mutation.shape_version),
         true <- valid_name?(mutation.idempotency_key),
         true <- valid_digest?(mutation.payload_digest),
         true <- valid_digest?(mutation.scope_digest),
         true <- valid_digest?(mutation.shape_digest),
         true <-
           is_list(mutation.shape_features) and length(mutation.shape_features) <= 3 and
             Enum.sort(Enum.uniq(mutation.shape_features)) == mutation.shape_features and
             Enum.all?(
               mutation.shape_features,
               &(&1 in ["object_id", "object_relation", "scalar_array"])
             ),
         true <- not object_id_selectors?(mutation) or "object_id" in mutation.shape_features,
         true <-
           is_list(mutation.effects) and length(mutation.effects) in 1..16 and
             Enum.uniq(mutation.effects) == mutation.effects and
             Enum.all?(mutation.effects, &valid_name?/1) do
      :ok
    else
      {:error, _} = error -> error
      _ -> invalid(:invalid_document_metadata)
    end
  end

  def validate(_), do: invalid(:invalid_document_mutation)

  @doc "Validate parsed object keys without accepting textual native paths."
  def valid_path?(path), do: match?({:ok, _}, Selecto.Document.Path.parse(path))

  @doc "Stable digest of portable data; it contains no original scope values."
  def digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp selector(%{path: path, value: value}) do
    if valid_path?(path) and (is_binary(value) or is_integer(value) or ObjectId.valid?(value)) and
         value != "",
       do: :ok,
       else: invalid(:invalid_document_selector)
  end

  defp selector(_), do: invalid(:invalid_document_selector)

  # The ObjectId milestone extends document/element identities, not trusted
  # tenant types. Preserve the pre-existing string/integer tenant contract.
  defp tenant_selector(%{value: value} = selector) when is_binary(value) or is_integer(value),
    do: selector(selector)

  defp tenant_selector(_), do: invalid(:invalid_document_selector)

  defp object_id_selectors?(mutation) do
    Enum.any?(
      [mutation.identity, mutation.tenant | Enum.map(mutation.mutations, & &1.identity)],
      &ObjectId.valid?(&1.value)
    )
  end

  defp version(%{path: path, expected: expected}) do
    if valid_path?(path) and is_integer(expected) and expected in 0..9_223_372_036_854_775_806,
      do: :ok,
      else: invalid(:invalid_expected_version)
  end

  defp version(_), do: invalid(:invalid_expected_version)

  defp validate_mutations(
         %{
           mutations: [
             %{
               op: :update_element,
               path: path,
               identity: identity,
               patch: [%{op: :increment, path: field, value: amount}]
             }
           ]
         } = mutation
       ) do
    protected = [
      mutation.identity.path,
      mutation.tenant.path,
      mutation.version.path,
      ["_selecto_receipts"]
    ]

    with :ok <- selector(identity),
         true <- valid_path?(path) and valid_path?(field),
         true <- is_integer(amount) and amount > 0 and amount <= 100,
         false <- Enum.any?(protected, &overlap?(&1, path)),
         false <- overlap?(identity.path, field),
         true <- disjoint?(protected) do
      :ok
    else
      _ -> invalid(:unsupported_document_mutation)
    end
  end

  defp validate_mutations(_), do: invalid(:unsupported_document_mutation)

  defp overlap?(left, right),
    do: Enum.take(left, length(right)) == right or Enum.take(right, length(left)) == left

  defp disjoint?([]), do: true
  defp disjoint?([path | rest]), do: not Enum.any?(rest, &overlap?(path, &1)) and disjoint?(rest)

  defp valid_name?(value), do: is_binary(value) and byte_size(value) in 1..256
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp invalid(code),
    do:
      {:error,
       Error.new(:invalid_command, "Invalid portable document mutation", details: %{code: code})}
end
