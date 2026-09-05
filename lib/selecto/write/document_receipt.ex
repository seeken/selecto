defmodule Selecto.Write.DocumentReceipt do
  @moduledoc """
  Normalized receipt and durable effect identities for a document action.

  Adapters must persist these facts atomically with the mutation. A replay uses
  the previously stored receipt unchanged. Effect records are durable intent;
  their presence does not promise external delivery or exactly-once publication.
  """

  alias Selecto.Write.DocumentMutation

  def new(%DocumentMutation{} = mutation, adapter_evidence) when is_map(adapter_evidence) do
    receipt_id =
      DocumentMutation.digest(
        {mutation.action, mutation.identity, mutation.scope_digest, mutation.idempotency_key}
      )

    effects =
      Enum.map(mutation.effects, fn name ->
        %{
          id: DocumentMutation.digest({receipt_id, name}),
          name: name,
          receipt_id: receipt_id,
          target: mutation.identity.value,
          version: mutation.version.expected + 1
        }
      end)

    %{
      id: receipt_id,
      action: mutation.action,
      shape_version: mutation.shape_version,
      shape_digest: mutation.shape_digest,
      target: mutation.identity.value,
      scope_digest: mutation.scope_digest,
      payload_digest: mutation.payload_digest,
      matched: 1,
      modified: 1,
      created: 0,
      deleted: 0,
      version: mutation.version.expected + 1,
      effects: effects,
      adapter: adapter_evidence
    }
  end
end
