defmodule SelectoUpdato.ExtensionsTest do
  use ExUnit.Case, async: true

  defmodule UpdatoMarkerExtension do
    @behaviour Selecto.Extension

    @impl true
    def updato_domain(domain, _opts) do
      Map.put(domain, :updato_marker, true)
    end
  end

  test "operation applies updato extension callbacks from domain" do
    operation =
      SelectoUpdato.new(%{
        source: nil,
        columns: %{"id" => %{type: :integer}},
        extensions: [UpdatoMarkerExtension]
      })

    assert operation.domain.updato_marker == true
    assert operation.extensions == [{UpdatoMarkerExtension, []}]
  end
end
