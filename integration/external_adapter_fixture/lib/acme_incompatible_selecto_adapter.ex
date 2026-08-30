defmodule AcmeIncompatibleSelectoAdapter do
  @moduledoc false

  @behaviour Selecto.DB.Adapter

  @impl true
  def adapter_contract_version, do: 2

  @impl true
  def name, do: :acme_incompatible_external_fixture

  @impl true
  def connect(_connection), do: raise("incompatible adapter was initialized")

  @impl true
  def execute(_connection, _sql, _params, _opts), do: {:error, :not_reached}

  @impl true
  def placeholder(index), do: "@incompatible#{index}"

  @impl true
  def quote_identifier(identifier), do: identifier

  @impl true
  def supports?(_feature), do: false
end
