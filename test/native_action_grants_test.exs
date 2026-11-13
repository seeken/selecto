# Native adapters stay outside this portable package's dependency graph.
if runtime = System.get_env("SELECTO_ACTION_GRANT_RUNTIME_PATH") do
  for app <- [:db_connection, :postgrex, :selecto_db_postgresql] do
    path = Path.join([runtime, Atom.to_string(app), "ebin"])
    unless File.dir?(path), do: raise("Missing native action-grant host runtime: #{app}")
    Code.prepend_path(path)
  end

  {:ok, _} = Application.ensure_all_started(:selecto_db_postgresql)
  Code.require_file("../integration/updato/action_grants/fixture.exs", __DIR__)
  Code.require_file("../integration/updato/action_grants/suite.exs", __DIR__)
end
