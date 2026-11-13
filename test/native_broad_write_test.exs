if runtime = System.get_env("SELECTO_ADVERSARIAL_RUNTIME_PATH") do
  for app <- [:db_connection, :postgrex, :selecto_db_postgresql, :selecto_api] do
    path = Path.join([runtime, Atom.to_string(app), "ebin"])
    unless File.dir?(path), do: raise("Missing native broad-write host runtime: #{app}")
    Code.prepend_path(path)
  end

  {:ok, _} = Application.ensure_all_started(:selecto_db_postgresql)
  Code.require_file("../integration/updato/broad_writes/fixture.exs", __DIR__)
  Code.require_file("../integration/updato/broad_writes/suite.exs", __DIR__)
end
