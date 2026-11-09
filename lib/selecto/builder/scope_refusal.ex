defmodule Selecto.Builder.ScopeRefusal do
  @moduledoc false

  # Raised while compiling when a host, trusted, required or tenant
  # comparison cannot be made exact on the adapter's storage (a TIMESTAMP
  # column under a zone-dependent operator, a VARCHAR identity column under a
  # collation-following LIKE, a scope column the catalog lookup did not
  # resolve). Selecto.Error.from_reason/1 turns it into a typed
  # `query_enforcement` error (`query_rule_not_evaluable`).
  defexception [:message, :reason, :error]

  @doc false
  # Raised for a Selecto.Error the adapter returned while compiling (a SQL
  # shape it cannot render): typed through every execute entry point as that
  # error, its details carrying `reason`.
  def unsupported!(%Selecto.Error{} = error, reason \\ nil) do
    detail = Map.get(error.details || %{}, :reason)
    reason = reason || if(is_atom(detail) and detail, do: detail, else: :unsupported_feature)
    raise __MODULE__, message: error.message, reason: reason, error: error
  end
end
