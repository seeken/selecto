defmodule AcmeSelectoAdapter do
  @moduledoc false

  @behaviour Selecto.DB.Adapter

  @impl true
  def adapter_contract_version, do: Selecto.DB.Adapter.contract_version()

  @impl true
  def name, do: :acme_external_fixture

  @impl true
  def connect(connection), do: {:ok, connection}

  @impl true
  def execute(:external_fixture_connection, _sql, params, _opts) do
    {:ok, %{rows: [[length(params) + 41]], columns: ["id"]}}
  end

  @impl true
  def placeholder(index), do: "@acme#{index}"

  @impl true
  def quote_identifier(identifier), do: "<#{identifier}>"

  @impl true
  def supports?(:external_adapter_fixture), do: true

  def supports?(_feature), do: false
end
