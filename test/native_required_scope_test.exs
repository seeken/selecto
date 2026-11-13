# Native adapters stay outside this portable package's dependency graph.
if runtime = System.get_env("SELECTO_ADVERSARIAL_RUNTIME_PATH") do
  for app <- [:db_connection, :postgrex, :selecto_db_postgresql, :selecto_api] do
    path = Path.join([runtime, Atom.to_string(app), "ebin"])
    unless File.dir?(path), do: raise("Missing native required-scope host runtime: #{app}")
    Code.prepend_path(path)
  end

  {:ok, _} = Application.ensure_all_started(:selecto_db_postgresql)
  Code.require_file("../integration/updato/required_scope/fixture.exs", __DIR__)
  Code.require_file("../integration/updato/required_scope/suite.exs", __DIR__)
end
