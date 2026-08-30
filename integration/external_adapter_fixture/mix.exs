defmodule SelectoExternalAdapterFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :selecto_external_adapter_fixture,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Synthetic out-of-tree Selecto adapter fixture",
      deps: deps(),
      package: [
        files: ~w(lib mix.exs),
        licenses: ["MIT"],
        links: %{"Selecto" => "https://github.com/seeken/selecto"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    case System.get_env("SELECTO_EXTERNAL_CORE_PATH") do
      path when is_binary(path) and path != "" -> [{:selecto, path: path}]
      _ -> [{:selecto, "~> 0.5"}]
    end
  end
end
