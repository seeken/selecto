defmodule Selecto.PostgreSQLBoundaryScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/check_postgresql_boundary.sh", __DIR__)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "selecto-boundary-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "lib/selecto/domain/contract"))
    File.mkdir_p!(Path.join(directory, "lib/selecto/builder"))
    File.mkdir_p!(Path.join(directory, "lib/selecto/sql"))
    File.mkdir_p!(Path.join(directory, "tools"))
    File.ln_s!(System.find_executable("grep"), Path.join(directory, "tools/grep"))
    File.write!(Path.join(directory, "mix.exs"), "{:postgrex, \"~> 0.22\", only: :test}\n")
    File.write!(Path.join(directory, "lib/selecto/sql/functions.ex"), "")
    File.write!(Path.join(directory, "lib/selecto/sql/formatter.ex"), "")

    File.write!(
      Path.join(directory, "lib/selecto/json.ex"),
      "      %{type: type} when type in [:json, :jsonb] -> true\n"
    )

    File.write!(
      Path.join(directory, "lib/selecto/domain/contract/computed_values.ex"),
      "      t when t in ~w(utc_datetime datetime naive_datetime timestamp timestamptz) -> :datetime\n      t when t in ~w(jsonb json) -> :json\n"
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp scan(directory, fallback?) do
    options = [cd: directory, stderr_to_stdout: true]

    options =
      if fallback?,
        do: Keyword.put(options, :env, [{"PATH", Path.join(directory, "tools")}]),
        else: options

    System.cmd("/bin/bash", [@script], options)
  end

  test "exact input aliases are allowed with either scanner", %{directory: directory} do
    for fallback? <- [false, true] do
      assert {"selecto PostgreSQL production boundary: clean\n", 0} = scan(directory, fallback?)
    end
  end

  test "an allowed alias does not exempt native SQL elsewhere in its file", %{
    directory: directory
  } do
    File.write!(
      Path.join(directory, "lib/selecto/json.ex"),
      "      %{type: type} when type in [:json, :jsonb] -> true\n      sql = \"CAST(value AS JSONB)\"\n"
    )

    for fallback? <- [false, true] do
      assert {output, 1} = scan(directory, fallback?)
      assert output =~ "CAST(value AS JSONB)"
    end
  end

  test "alias exemptions reject altered lines and other locations", %{directory: directory} do
    File.write!(
      Path.join(directory, "lib/selecto/json.ex"),
      "      %{type: type} when type in [:json, :jsonb] -> true # changed\n"
    )

    File.write!(
      Path.join(directory, "lib/other.ex"),
      "      t when t in ~w(jsonb json) -> :json\n"
    )

    for fallback? <- [false, true] do
      assert {output, 1} = scan(directory, fallback?)
      assert output =~ "# changed"
      assert output =~ "lib/other.ex"
    end
  end

  test "native placeholders and production drivers remain forbidden", %{directory: directory} do
    File.write!(Path.join(directory, "lib/selecto/builder/native.ex"), "\"SELECT $1\"\n")
    File.write!(Path.join(directory, "mix.exs"), "{:postgrex, \"~> 0.22\"}\n")

    for fallback? <- [false, true] do
      assert {output, 1} = scan(directory, fallback?)
      assert output =~ "SELECT $1"
      assert output =~ "{:postgrex,"
    end
  end

  test "a prefix containing a colon cannot masquerade as an exact alias", %{directory: directory} do
    File.write!(
      Path.join(directory, "lib/selecto/json.ex"),
      "some_jsonb_call(); # comment:      %{type: type} when type in [:json, :jsonb] -> true\n"
    )

    for fallback? <- [false, true] do
      assert {output, 1} = scan(directory, fallback?)
      assert output =~ "some_jsonb_call()"
    end
  end
end
