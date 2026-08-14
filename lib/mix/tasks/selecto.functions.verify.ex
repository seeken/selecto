defmodule Mix.Tasks.Selecto.Functions.Verify do
  use Mix.Task

  @shortdoc "Verifies registered database-function signatures"

  @moduledoc """
  Verifies every registered function signature exposed by a domain provider.

      mix selecto.functions.verify --domain MyApp.SelectoDomain
      mix selecto.functions.verify --domain MyApp.SelectoDomain --strict
      mix selecto.functions.verify --domain MyApp.SelectoDomain \
        --strict --output tmp/selecto-functions.json

  The provider module must export `selecto/0` and return a configured
  `%Selecto{}` (or `{:ok, %Selecto{}}`). Alternatively it may export `domain/0`
  and `connection/0`; optional `configure_options/0` supplies the keyword
  options passed to `Selecto.configure/3`.

  Text output is always printed. `--output` additionally writes deterministic
  JSON without a timestamp. `--strict` raises after the artifact is written if
  any signature status is not `:database_resolved`. Without `--strict`, finite
  unsupported or failure evidence is reported without changing the exit status.
  """

  alias Selecto.FunctionVerification.Suite

  @switches [domain: :string, output: :string, strict: :boolean]
  @usage "mix selecto.functions.verify --domain MODULE [--strict] [--output PATH]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] or not is_binary(opts[:domain]) do
      Mix.raise("usage: #{@usage}")
    end

    Mix.Task.run("app.start")

    provider = provider_module!(opts[:domain])
    selecto = configured_selecto!(provider)
    artifact = Suite.verify(selecto)

    print_artifact(artifact)
    maybe_write(artifact, opts[:output])

    if opts[:strict] == true and not artifact.strict_passed? do
      Mix.raise("database function verification failed in strict mode")
    end

    :ok
  end

  defp provider_module!(name) do
    module_name = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name

    module =
      try do
        String.to_existing_atom(module_name)
      rescue
        ArgumentError -> Mix.raise("domain provider module #{name} is not loaded")
      end

    if Code.ensure_loaded?(module) do
      module
    else
      Mix.raise("domain provider module #{name} is not available")
    end
  end

  defp configured_selecto!(provider) do
    result =
      cond do
        function_exported?(provider, :selecto, 0) ->
          apply(provider, :selecto, [])

        function_exported?(provider, :domain, 0) and
            function_exported?(provider, :connection, 0) ->
          options =
            if function_exported?(provider, :configure_options, 0),
              do: apply(provider, :configure_options, []),
              else: []

          Selecto.configure(
            apply(provider, :domain, []),
            apply(provider, :connection, []),
            options
          )

        true ->
          Mix.raise(
            "domain provider #{inspect(provider)} must export selecto/0 or domain/0 plus connection/0"
          )
      end

    case result do
      %Selecto{} = selecto ->
        selecto

      {:ok, %Selecto{} = selecto} ->
        selecto

      _result ->
        Mix.raise("domain provider #{inspect(provider)} did not return a configured Selecto")
    end
  rescue
    error in Mix.Error ->
      reraise(error, __STACKTRACE__)

    _exception ->
      Mix.raise(
        "domain provider #{inspect(provider)} failed while building Selecto configuration"
      )
  end

  defp print_artifact(artifact) do
    Enum.each(artifact.results, fn result ->
      status = result.status |> Atom.to_string() |> String.upcase()
      identity = result.resolved_identity || result.sql_name || "unresolved"

      Mix.shell().info(
        "#{status} #{result.function_id}[#{result.signature_index}] #{identity} " <>
          "proof=#{result.proof_level}"
      )

      Enum.each(result.diagnostics, fn diagnostic ->
        Mix.shell().info("  diagnostic=#{diagnostic_code(diagnostic)}")
      end)
    end)

    counts =
      artifact.summary.status_counts
      |> Enum.sort_by(fn {status, _count} -> Atom.to_string(status) end)
      |> Enum.map_join(", ", fn {status, count} -> "#{status}=#{count}" end)

    Mix.shell().info(
      "Function verification: #{artifact.summary.signature_count} signatures " <>
        "across #{artifact.summary.function_count} functions (#{counts})"
    )

    Mix.shell().info(
      "Proof boundary: #{artifact.proof_boundary.proves}; does not prove " <>
        artifact.proof_boundary.does_not_prove
    )
  end

  defp diagnostic_code(diagnostic) do
    Map.get(diagnostic, :code) || Map.get(diagnostic, "code") || :unknown
  end

  defp maybe_write(_artifact, nil), do: :ok

  defp maybe_write(artifact, path) do
    expanded_path = Path.expand(path)
    File.mkdir_p!(Path.dirname(expanded_path))

    json = Jason.encode_to_iodata!(artifact, pretty: true)
    File.write!(expanded_path, [json, "\n"])
    Mix.shell().info("Wrote function verification artifact to #{expanded_path}")
  end
end
