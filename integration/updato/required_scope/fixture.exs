defmodule SelectoUpdato.NativeRequiredScopeFixture do
  @moduledoc false
  @path Path.join(__DIR__, "fixtures/adversarial_required_scope_v1.json")
  @sha "5e7b546a4e4c09ff0973f1be7aebea521884fc20188f64f77e75dabc3f701118"
  @keys ~w(actions allowed_ops amount associations bulk cardinality child_key columns create delete domain domain_fingerprint domain_version enabled execution expected_cardinality field fields filterable groupable id identity_fields insert insertable internal joins kind max_mutations modes name operation operations order orders owner_id ownership parent_key person_id primary_key redact_fields relationships rename require_filter required returning satisfied_by schema_version schemas scope secret_score set sortable source source_table ssn state tenant tenant_field tenant_id total type updatable update writable write writes)a
  @key_map Map.new(@keys, &{Atom.to_string(&1), &1})
  @enums ~w(integer string many owned ordered sync delta detail_action row updato update insert delete count trusted_context)a
  @enum_map Map.new(@enums, &{Atom.to_string(&1), &1})

  def load do
    bytes = File.read!(@path)

    unless Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha,
      do: raise("Native required-scope input fixture changed")

    Jason.decode!(bytes)
  end

  def variants(inputs),
    do: [%{"variant" => "baseline", "dataset" => inputs["dataset"]} | inputs["variants"]]

  def domain(inputs), do: atomize(inputs["domain"])

  def source(connection, inputs) do
    domain(inputs)
    |> Selecto.configure(connection,
      adapter: SelectoDBPostgreSQL.Adapter,
      mode: :strict,
      domain_sql: :declared
    )
    |> Selecto.with_tenant(%{
      tenant_id: inputs["trusted_tenant"],
      tenant_field: :tenant_id,
      required: true
    })
    |> Selecto.apply_tenant_scope()
    |> Selecto.filter(predicate(inputs["trusted_scope"]))
  end

  def predicate(%{"op" => "and", "args" => args}), do: {:and, Enum.map(args, &predicate/1)}
  def predicate(%{"op" => "eq", "field" => field, "value" => value}), do: {field, value}
  def predicate(%{"op" => "lt", "field" => field, "value" => value}), do: {field, {:lt, value}}

  def reset(connection, dataset) do
    cleanup(connection)

    Postgrex.query!(
      connection,
      "CREATE TABLE selecto_cert_required_people (id INT NOT NULL PRIMARY KEY, tenant_id INT, name TEXT, secret_score INT, ssn TEXT, amount INT, owner_id INT)",
      []
    )

    Postgrex.query!(
      connection,
      "CREATE TABLE selecto_cert_required_orders (id INT NOT NULL PRIMARY KEY, tenant_id INT, person_id INT, total INT, state TEXT)",
      []
    )

    for row <- dataset["people"]["rows"],
        do:
          Postgrex.query!(
            connection,
            "INSERT INTO selecto_cert_required_people VALUES ($1,$2,$3,$4,$5,$6,$7)",
            row
          )

    for row <- dataset["orders"]["rows"],
        do:
          Postgrex.query!(
            connection,
            "INSERT INTO selecto_cert_required_orders VALUES ($1,$2,$3,$4,$5)",
            row
          )

    :ok
  end

  def state(connection) do
    %{
      "people" =>
        Postgrex.query!(connection, "SELECT * FROM selecto_cert_required_people ORDER BY id", []).rows,
      "orders" =>
        Postgrex.query!(connection, "SELECT * FROM selecto_cert_required_orders ORDER BY id", []).rows
    }
  end

  def cleanup(connection) do
    Postgrex.query!(connection, "DROP TABLE IF EXISTS selecto_cert_required_orders", [])
    Postgrex.query!(connection, "DROP TABLE IF EXISTS selecto_cert_required_people", [])
    :ok
  end

  def operation(source, probe) do
    root = probe["intent"]["root"]

    filters =
      Enum.map(root["filters"], fn
        %{"field" => "id", "op" => "eq", "value" => id} -> {:id, id}
        %{"field" => "id", "op" => "in", "value" => ids} -> {:id, :in, ids}
      end)

    source.domain
    |> SelectoUpdato.new(tenant: %{tenant_id: 7})
    |> SelectoUpdato.filters(filters)
    |> SelectoUpdato.update(Map.put(root["assignments"], "orders", probe["intent"]["mutation"]))
    |> SelectoUpdato.expected_cardinality({:exactly, root["expected_count"]})
    |> SelectoUpdato.enforce_query(source)
  end

  def atomize(map),
    do: Map.new(map, fn {key, value} -> {Map.fetch!(@key_map, key), value(key, value)} end)

  defp value(_key, value) when is_map(value), do: atomize(value)

  defp value(key, values)
       when is_list(values) and key in ~w(fields redact_fields identity_fields),
       do: Enum.map(values, &Map.fetch!(@key_map, &1))

  defp value(key, values) when is_list(values) and key in ~w(allowed_ops modes satisfied_by),
    do: Enum.map(values, &Map.fetch!(@enum_map, &1))

  defp value(key, value)
       when is_binary(value) and
              key in ~w(type cardinality ownership strategy returning kind scope operation expected_cardinality),
       do: Map.fetch!(@enum_map, value)

  defp value(key, value)
       when is_binary(value) and key in ~w(primary_key tenant_field parent_key child_key field),
       do: Map.fetch!(@key_map, value)

  defp value(_key, value), do: value
end
