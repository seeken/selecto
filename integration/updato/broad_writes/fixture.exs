defmodule SelectoUpdato.NativeBroadWriteFixture do
  @moduledoc false
  @path Path.join(__DIR__, "fixtures/adversarial_broad_writes_v1.json")
  @sha "48a92d46d40b33b8e6d21f49eec9d4555eddef54b68fe6b00d8af1831dadde15"
  @keys ~w(actions allowed_ops amount associations bulk cardinality child_key columns create delete domain domain_fingerprint domain_version enabled execution expected_cardinality field fields filterable groupable id identity_fields insert insertable internal joins kind conflict_targets max_mutations modes name operation operations order orders owner_id ownership parent_key person_id primary_key redact_fields relationships rename require_filter required returning satisfied_by schema_version schemas scope secret_score set sortable source source_table ssn state tenant tenant_field tenant_id total type updatable update upsert writable write writes)a
  @key_map Map.new(@keys, &{Atom.to_string(&1), &1})
  @enums ~w(integer string many owned ordered sync delta detail_action row updato update insert delete count all trusted_context)a
  @enum_map Map.new(@enums, &{Atom.to_string(&1), &1})

  def load do
    bytes = File.read!(@path)

    unless Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha,
      do: raise("Native broad-write input fixture changed")

    Jason.decode!(bytes)
  end

  def variants(inputs),
    do: [%{"variant" => "baseline", "dataset" => inputs["dataset"]} | inputs["variants"]]

  def domain(inputs, key \\ nil),
    do: atomize(if(key, do: inputs["case_domains"][key], else: inputs["domain"]))

  def source(connection, inputs, key \\ nil) do
    domain(inputs, key)
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
  end

  def predicate(%{"op" => "and", "args" => args}), do: {:and, Enum.map(args, &predicate/1)}
  def predicate(%{"op" => "eq", "field" => field, "value" => value}), do: {field, value}
  def predicate(%{"op" => "lt", "field" => field, "value" => value}), do: {field, {:lt, value}}

  def reset(connection, dataset) do
    cleanup(connection)

    Postgrex.query!(
      connection,
      "CREATE TABLE selecto_cert_adv_people (id INT NOT NULL PRIMARY KEY, tenant_id INT, name TEXT, secret_score INT, ssn TEXT, amount INT)",
      []
    )

    Postgrex.query!(
      connection,
      "CREATE TABLE selecto_cert_adv_orders (id INT NOT NULL PRIMARY KEY, tenant_id INT, person_id INT, total INT, state TEXT)",
      []
    )

    for row <- dataset["people"]["rows"],
        do:
          Postgrex.query!(
            connection,
            "INSERT INTO selecto_cert_adv_people VALUES ($1,$2,$3,$4,$5,$6)",
            row
          )

    for row <- dataset["orders"]["rows"],
        do:
          Postgrex.query!(
            connection,
            "INSERT INTO selecto_cert_adv_orders VALUES ($1,$2,$3,$4,$5)",
            row
          )

    :ok
  end

  def state(connection) do
    %{
      "people" =>
        Postgrex.query!(connection, "SELECT * FROM selecto_cert_adv_people ORDER BY id", []).rows,
      "orders" =>
        Postgrex.query!(connection, "SELECT * FROM selecto_cert_adv_orders ORDER BY id", []).rows
    }
  end

  def cleanup(connection) do
    Postgrex.query!(connection, "DROP TABLE IF EXISTS selecto_cert_adv_orders", [])
    Postgrex.query!(connection, "DROP TABLE IF EXISTS selecto_cert_adv_people", [])
    :ok
  end

  def batch(source, probe) do
    built =
      Enum.reduce(
        Enum.with_index(probe["intent"]["commands"]),
        SelectoUpdato.multi(),
        fn {command, index}, multi ->
          name = Enum.at([:first, :second, :third], index)

          SelectoUpdato.multi_update(multi, name, source.domain,
            filters: filters(command["filters"]),
            changes: command["assignments"]
          )
        end
      )

    operations =
      Enum.zip(built.operations, probe["intent"]["commands"])
      |> Enum.map(fn {{name, operation}, command} ->
        {name,
         operation
         |> SelectoUpdato.expected_cardinality({:exactly, command["expected_count"]})
         |> SelectoUpdato.returning(command["returning"])}
      end)

    %{built | operations: operations}
  end

  def filters(values),
    do:
      Enum.map(values, fn
        %{"field" => field, "op" => "eq", "value" => value} -> {field, value}
        %{"field" => field, "op" => "in", "value" => values} -> {field, :in, values}
      end)

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
