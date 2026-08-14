defmodule Selecto.Domain.Ref do
  @moduledoc """
  Opaque provenance for a domain resolved through a trusted registry.

  The reference intentionally contains no authored domain map. It is safe to
  pass between server-owned Selecto consumers that can resolve it again through
  the named registry.
  """

  @enforce_keys [:id, :registry]
  defstruct [:id, :registry, :version, :fingerprint, metadata: %{}]

  @type id :: atom() | String.t()
  @type t :: %__MODULE__{
          id: id(),
          registry: module(),
          version: term() | nil,
          fingerprint: String.t() | nil,
          metadata: map()
        }

  @spec new(id(), module(), keyword()) :: t()
  def new(id, registry, opts \\ []) do
    %__MODULE__{
      id: id,
      registry: registry,
      version: Keyword.get(opts, :version),
      fingerprint: Keyword.get(opts, :fingerprint),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
