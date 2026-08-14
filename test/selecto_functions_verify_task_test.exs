defmodule Mix.Tasks.Selecto.Functions.VerifyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Selecto.Functions.Verify

  defmodule Support do
    def selecto(adapter) do
      Selecto.configure(domain(), self(), adapter: adapter, validate: false)
    end

    defp domain do
      %{
        name: "Task verification",
        source: %{
          source_table: "items",
          primary_key: :id,
          fields: [:id],
          redact_fields: [],
          columns: %{id: %{type: :integer}},
          associations: %{}
        },
        schemas: %{},
        joins: %{},
        functions: %{
          "answer" => %{
            kind: :scalar,
            sql_name: "public.answer",
            args: [],
            returns: :integer,
            allowed_in: [:select]
          }
        }
      }
    end
  end

  defmodule ResolvedAdapter do
    def name, do: :task_resolved
    def connect(connection), do: {:ok, connection}
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false

    def verify_function(_connection, _request, _opts) do
      {:ok,
       %{
         status: :database_resolved,
         resolved_identity: "public.answer()",
         evidence: %{function_executed: false},
         diagnostics: []
       }}
    end
  end

  defmodule MissingAdapter do
    def name, do: :task_missing
    def connect(connection), do: {:ok, connection}
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false

    def verify_function(_connection, _request, _opts) do
      {:ok,
       %{
         status: :missing_function,
         evidence: %{},
         diagnostics: [%{code: :function_not_found}]
       }}
    end
  end

  defmodule SuccessfulProvider do
    def selecto, do: Mix.Tasks.Selecto.Functions.VerifyTest.Support.selecto(ResolvedAdapter)
  end

  defmodule FailingProvider do
    def selecto, do: Mix.Tasks.Selecto.Functions.VerifyTest.Support.selecto(MissingAdapter)
  end

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      Mix.Task.reenable("app.start")
      Mix.Task.reenable("selecto.functions.verify")
    end)

    :ok
  end

  test "writes byte-stable JSON with an explicit proof boundary" do
    first_path = temporary_path("first")
    second_path = temporary_path("second")
    on_exit(fn -> File.rm(first_path) end)
    on_exit(fn -> File.rm(second_path) end)

    Verify.run([
      "--domain",
      provider_name(SuccessfulProvider),
      "--strict",
      "--output",
      first_path
    ])

    Verify.run([
      "--domain",
      provider_name(SuccessfulProvider),
      "--strict",
      "--output",
      second_path
    ])

    assert File.read!(first_path) == File.read!(second_path)

    artifact = first_path |> File.read!() |> Jason.decode!()
    assert artifact["format"] == "selecto.function_verification"
    assert artifact["strict_passed?"] == true
    refute Map.has_key?(artifact, "generated_at")
    assert artifact["proof_boundary"]["runtime_argument_values_transmitted"] == false
    assert get_in(artifact, ["results", Access.at(0), "status"]) == "database_resolved"
  end

  test "warn mode reports finite failure evidence without raising" do
    assert :ok = Verify.run(["--domain", provider_name(FailingProvider)])
    assert_received {:mix_shell, :info, [line]}
    assert line =~ "MISSING_FUNCTION answer[0]"
  end

  test "strict mode writes the artifact before returning a non-zero Mix failure" do
    path = temporary_path("strict-failure")
    on_exit(fn -> File.rm(path) end)

    assert_raise Mix.Error, ~r/failed in strict mode/, fn ->
      Verify.run([
        "--domain",
        provider_name(FailingProvider),
        "--strict",
        "--output",
        path
      ])
    end

    assert File.exists?(path)
    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["strict_passed?"] == false
    assert get_in(artifact, ["results", Access.at(0), "status"]) == "missing_function"
  end

  test "rejects missing and unknown provider modules with stable usage errors" do
    assert_raise Mix.Error, ~r/usage: mix selecto.functions.verify/, fn ->
      Verify.run([])
    end

    assert_raise Mix.Error, ~r/domain provider module Not.Loaded is not loaded/, fn ->
      Verify.run(["--domain", "Not.Loaded"])
    end
  end

  defp provider_name(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp temporary_path(label) do
    Path.join(
      System.tmp_dir!(),
      "selecto-functions-#{label}-#{System.unique_integer([:positive])}.json"
    )
  end
end
