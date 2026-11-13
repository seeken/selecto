defmodule Mix.Tasks.SelectoUpdato.Verify do
  use Mix.Task

  @shortdoc "Runs SelectoUpdato bounded formal-verification suites"
  @requirements ["app.start"]

  @moduledoc """
  Runs the SelectoUpdato bounded formal-verification suites.

      mix selecto_updato.verify
      mix selecto_updato.verify --output tmp/updato-verification.json

  Exit status is non-zero if any suite produces a counterexample.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix selecto_updato.verify [--output PATH]")
    end

    reports = [
      SelectoUpdato.Verification.WriteSafety.verify(),
      SelectoUpdato.Verification.PortableCommandSafety.verify(),
      SelectoUpdato.Verification.NestedGraphSafety.verify(),
      SelectoUpdato.Verification.NestedCompositionSafety.verify(),
      SelectoUpdato.Verification.ActionSafety.verify(),
      SelectoUpdato.Verification.TrustBoundarySafety.verify(),
      SelectoUpdato.Verification.AuthorizationLifecycleSafety.verify(),
      SelectoUpdato.Verification.TenantNonInterferenceSafety.verify(),
      SelectoUpdato.Verification.MultiAtomicitySafety.verify()
    ]

    artifact = artifact(reports)

    Enum.each(reports, &print_report/1)
    maybe_write(artifact, opts[:output])

    unless artifact.proved? do
      Mix.raise("SelectoUpdato formal verification found counterexamples")
    end
  end

  defp artifact(reports) do
    %{
      format: "selecto.formal_verification_suite",
      format_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      proved?: Enum.all?(reports, & &1.proved?),
      reports: reports
    }
  end

  defp print_report(report) do
    status = if report.proved?, do: "PROVED", else: "FAILED"

    Mix.shell().info(
      "#{status} #{report.model}: #{report.check_count} checks " <>
        "(#{report.state_count} states x #{report.invariant_count} invariants, " <>
        "proof=#{report.proof_level})"
    )

    Enum.each(report.counterexamples, fn counterexample ->
      Mix.shell().error("counterexample: #{inspect(counterexample, pretty: true)}")
    end)
  end

  defp maybe_write(_artifact, nil), do: :ok

  defp maybe_write(artifact, path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(artifact, pretty: true))
    Mix.shell().info("Wrote verification artifact to #{path}")
  end
end
