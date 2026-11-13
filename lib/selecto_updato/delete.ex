defmodule SelectoUpdato.Delete do
  @moduledoc """
  Portable delete operation building for SelectoUpdato.

  Deletion safety comes from the domain-owned predicate, trusted scope, and
  expected cardinality compiled into the command. A soft delete is an ordinary
  domain-enabled update that explicitly assigns the domain's archival field.
  """

  alias SelectoUpdato.Operation

  @doc """
  Mark the operation as a delete.

  The portable compiler rejects an update or delete with no governed predicate.
  """
  @spec delete(Operation.t()) :: Operation.t()
  def delete(%Operation{} = op) do
    %{op | type: :delete}
  end
end
