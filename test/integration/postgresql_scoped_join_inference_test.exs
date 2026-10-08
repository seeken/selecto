defmodule Selecto.Integration.PostgreSQLScopedJoinInferenceTest do
  @moduledoc """
  Executes the bounded dirty-reference fixture through Postgrex. Direct joined
  selection, correlated JSON/count/filter, ordering and counts preserve the literal tenant
  model, including explicit author scopes and a genuinely tenantless lookup.
  """

  use ExUnit.Case, async: true

  @moduletag :requires_db
  @fixture Path.expand("../fixtures/adversarial_joins_v1.json", __DIR__)
  @terminal_fixture Path.expand("../fixtures/adversarial_terminal_multihop_v1.json", __DIR__)
  @terminal_model Path.expand(
                    "../fixtures/adversarial_terminal_multihop_literal_model_v1.json",
                    __DIR__
                  )
  @terminal_fixture_sha "272773ff13ea265290100887606ccd6ca67b52a2402112a1fcf6e4f4df96d49e"
  @terminal_model_sha "95124f1fc3082af91c6cae99dc9dcc88876011f17247d11f010b72923cf9fcd7"
  @terminal_tables %{
    "roots" => "selecto_adv_terminal_roots",
    "middles" => "selecto_adv_terminal_middles",
    "hubs" => "selecto_adv_terminal_hubs",
    "terminals" => "selecto_adv_terminal_terminals",
    "decoys" => "selecto_adv_terminal_decoys"
  }
  @tables %{
    "people" => "selecto_cert_join_people",
    "accounts" => "selecto_cert_join_accounts",
    "lookups" => "selecto_cert_join_lookups"
  }
  @atoms Map.new(
           [
             :schema_version,
             :name,
             :domain_version,
             :domain_fingerprint,
             :source,
             :schemas,
             :joins,
             :source_table,
             :primary_key,
             :fields,
             :redact_fields,
             :columns,
             :associations,
             :tenant_field,
             :id,
             :tenant_id,
             :account_id,
             :lookup_id,
             :organization_id,
             :secret_score,
             :ssn,
             :type,
             :internal,
             :account,
             :lookup,
             :queryable,
             :owner_key,
             :related_key,
             :cardinality,
             :source_scope_key,
             :target_scope_key,
             :integer,
             :string,
             :left,
             :one,
             :many,
             :middle_id,
             :root_id,
             :target_id,
             :route_id,
             :mid_ref,
             :bucket,
             :root_bucket,
             :segment,
             :secret,
             :workspace_id,
             :company_id,
             :middles,
             :hubs,
             :terminals,
             :decoys,
             :bridges,
             :customer,
             :members,
             :shared_middle,
             :links,
             :items,
             :via,
             :bridge_alias
           ],
           &{Atom.to_string(&1), &1}
         )
  @account_rows %{
    "joined-select" => [
      [1, "root own beta", "Account Beta"],
      [2, "root dirty foreign", nil],
      [3, "root own alpha", "Account Alpha"],
      [4, "root null", nil],
      [5, "root missing", nil]
    ],
    "own-alpha-filter" => [[3]],
    "foreign-only-filter" => [],
    "foreign-collision-filter" => [],
    "sort-joined-asc" => [[3], [1], [2], [4], [5]],
    "sort-joined-desc" => [[2], [4], [5], [1], [3]],
    "joined-name-count" => [[2]],
    "own-filter-count" => [[1]],
    "foreign-filter-count" => [[0]],
    "root-positive-control" => [
      [1, "root own beta"],
      [2, "root dirty foreign"],
      [3, "root own alpha"],
      [4, "root null"],
      [5, "root missing"]
    ]
  }
  @lookup_rows %{
    "tenantless-shared-select" => [
      [1, "Shared One"],
      [2, "Shared Two"],
      [3, "Shared One"],
      [4, nil],
      [5, nil]
    ],
    "tenantless-shared-filter" => [[2]],
    "tenantless-shared-sort" => [[1], [3], [2], [4], [5]],
    "tenantless-shared-count" => [[3]]
  }

  setup do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
        port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
        username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
        password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
        database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test"),
        pool_size: 1
      )

    Postgrex.query!(conn, "SET statement_timeout = '5s'", [])

    for sql <- [
          "CREATE TEMP TABLE selecto_cert_join_people (id BIGINT PRIMARY KEY, tenant_id BIGINT NOT NULL, name TEXT, account_id BIGINT, lookup_id BIGINT, secret_score BIGINT, ssn TEXT, UNIQUE(tenant_id,id))",
          "CREATE TEMP TABLE selecto_cert_join_accounts (id BIGINT NOT NULL, organization_id BIGINT NOT NULL, name TEXT, secret_score BIGINT, ssn TEXT, UNIQUE(organization_id,id))",
          "CREATE TEMP TABLE selecto_cert_join_lookups (id BIGINT PRIMARY KEY, name TEXT)"
        ] do
      Postgrex.query!(conn, sql, [])
    end

    on_exit(fn -> Process.exit(conn, :normal) end)
    {:ok, conn: conn, inputs: @fixture |> File.read!() |> Jason.decode!()}
  end

  for case_id <- ~w(AJN001 AJN002 AJN003) do
    test "#{case_id}: exact joined rows and complete state survive paired perturbations", ctx do
      verify_case(ctx.conn, ctx.inputs, unquote(case_id))
    end

    test "#{case_id}: correlated rows and counts preserve scope across perturbations", ctx do
      case_id = unquote(case_id)
      domain = atomize(ctx.inputs["case_domains"][case_id] || ctx.inputs["domain"])
      target = if case_id == "AJN003", do: :lookup, else: :account

      children =
        if target == :lookup do
          [[10, "Shared One"], [20, "Shared Two"], [10, "Shared One"], nil, nil]
        else
          [[101, "Account Beta"], nil, [102, "Account Alpha"], nil, nil]
        end

      for definition <- [%{"dataset" => ctx.inputs["dataset"]} | ctx.inputs["variants"]] do
        seed(ctx.conn, definition["dataset"])
        complete_state = state(ctx.conn)

        source =
          domain
          |> Selecto.configure(ctx.conn)
          |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
          |> Selecto.apply_tenant_scope()
          |> Selecto.select(["id"])
          |> Selecto.order_by([{:asc, "id"}])

        for kind <- [:json_agg, :count, :filtered] do
          config = %{
            fields: ["id", "name"],
            target_schema: target,
            format: if(kind == :count, do: :count, else: :json_agg),
            alias: if(kind == :count, do: "matched", else: "items"),
            join_path: [target],
            order_by: [{:asc, "id"}, {:asc, "name"}],
            filters: if(kind == :filtered, do: [{"name", "Foreign Only"}], else: [])
          }

          expected =
            children
            |> Enum.with_index(1)
            |> Enum.map(fn {child, id} ->
              value =
                case {kind, child} do
                  {:filtered, _} -> nil
                  {:count, nil} -> 0
                  {:count, _} -> 1
                  {_, nil} -> nil
                  {_, [child_id, name]} -> [%{"id" => child_id, "name" => name}]
                end

              [id, value]
            end)

          columns = ["id", config.alias]
          assert state(ctx.conn) == complete_state

          assert {:ok, {^expected, ^columns, ["id"]}} =
                   source |> Selecto.subselect([config]) |> Selecto.execute()

          assert state(ctx.conn) == complete_state
        end
      end
    end
  end

  for parent_scope <- [:inferred, :explicit_identity] do
    test "#{parent_scope}: nested child scope follows the actual parent through an alias", ctx do
      parent_scope = unquote(parent_scope)
      original = atomize(ctx.inputs["domain"])
      association = original.source.associations.account

      association =
        if parent_scope == :explicit_identity do
          Map.merge(association, %{source_scope_key: :account_id, target_scope_key: :id})
        else
          association
        end

      domain =
        original
        |> update_in([:source, :associations], fn associations ->
          associations |> Map.delete(:account) |> Map.put(:customer, association)
        end)
        |> update_in([:joins], fn joins ->
          joins |> Map.delete(:account) |> Map.put(:customer, %{type: :left})
        end)
        |> put_in([:schemas, :children], Map.put(original.source, :associations, %{}))
        |> put_in([:schemas, :account, :associations], %{
          members: %{
            queryable: :children,
            owner_key: :id,
            related_key: :account_id,
            cardinality: :many
          }
        })

      for definition <- [%{"dataset" => ctx.inputs["dataset"]} | ctx.inputs["variants"]] do
        dataset =
          update_in(definition["dataset"], ["people", "rows"], fn rows ->
            rows ++
              [
                [6, 7, "own second child", 101, nil, 66, "own:ssn:6"],
                [10, 8, "foreign child", 101, nil, 100, "foreign:ssn:10"]
              ]
          end)

        seed(ctx.conn, dataset)
        complete_state = state(ctx.conn)

        query =
          domain
          |> Selecto.configure(ctx.conn)
          |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
          |> Selecto.apply_tenant_scope()
          |> Selecto.select(["id"])
          |> Selecto.order_by([{:asc, "id"}])
          |> Selecto.subselect([
            %{
              fields: ["id", "name"],
              target_schema: :account,
              format: :json_agg,
              alias: "items",
              join_path: [:customer],
              filters: if(parent_scope == :explicit_identity, do: [{"id", 201}], else: []),
              order_by: [{:asc, "id"}, {:asc, "name"}],
              nested: [
                %{
                  key: "children",
                  fields: ["id", "name"],
                  target_schema: :children,
                  format: :json_agg,
                  join_path: [:customer, :members],
                  order_by: [{:asc, "id"}, {:asc, "name"}]
                }
              ]
            }
          ])

        expected = nested_literal_rows(dataset, parent_scope)
        assert {:ok, {^expected, ["id", "items"], ["id"]}} = Selecto.execute(query)
        assert state(ctx.conn) == complete_state
      end
    end
  end

  for case_id <- ~w(TFM001 TFM002 TFM003 TFM004 TFM005 TFM006 TFM007) do
    test "#{case_id}: flattened terminal path matches the independent model and complete state",
         ctx do
      verify_terminal_case(ctx.conn, unquote(case_id))
    end
  end

  defp verify_terminal_case(conn, case_id) do
    inputs = pinned_json(@terminal_fixture, @terminal_fixture_sha)
    model = pinned_json(@terminal_model, @terminal_model_sha)
    assert model["fixture_sha256"] == @terminal_fixture_sha
    assert model["prepared_before_native_execution"] == true
    assert model["native_execution"] == false
    assert inputs["trusted_tenant"] == 7
    assert inputs["table_names"] == @terminal_tables
    case_input = Map.fetch!(inputs["cases"], case_id)
    expected = Map.fetch!(model["cases"], case_id)
    assert expected["tenant_O1_claim"] == case_id not in ["TFM005", "TFM006"]

    for {name, columns} <- [
          {"roots",
           "id BIGINT PRIMARY KEY,tenant_id BIGINT NOT NULL,middle_id BIGINT,name TEXT,bucket BIGINT,secret TEXT"},
          {"middles",
           "id BIGINT NOT NULL,organization_id BIGINT NOT NULL,route_id BIGINT,root_id BIGINT,target_id BIGINT,name TEXT,root_bucket BIGINT,segment BIGINT,secret TEXT,UNIQUE(organization_id,id)"},
          {"hubs",
           "id BIGINT NOT NULL,company_id BIGINT NOT NULL,route_id BIGINT,mid_ref BIGINT,name TEXT,segment BIGINT,secret TEXT,UNIQUE(company_id,id)"},
          {"terminals",
           "id BIGINT NOT NULL,workspace_id BIGINT NOT NULL,mid_ref BIGINT,name TEXT,segment BIGINT,secret TEXT,UNIQUE(workspace_id,id)"},
          {"decoys",
           "id BIGINT NOT NULL,workspace_id BIGINT NOT NULL,mid_ref BIGINT,name TEXT,segment BIGINT,secret TEXT,UNIQUE(workspace_id,id)"}
        ] do
      Postgrex.query!(
        conn,
        "CREATE TEMP TABLE " <> Map.fetch!(@terminal_tables, name) <> " (" <> columns <> ")",
        []
      )
    end

    definitions = [
      %{"variant" => "baseline", "dataset" => inputs["dataset"]} | inputs["variants"]
    ]

    assert length(definitions) == 3
    assert length(expected["variants"]) == 3
    assert length(case_input["probes"]) == 6

    results =
      Enum.zip(definitions, expected["variants"])
      |> Map.new(fn {definition, wanted} ->
        assert definition["variant"] == wanted["variant"]
        assert length(wanted["responses"]) == 6
        dataset = definition["dataset"]
        declared_state = Map.new(dataset, fn {name, data} -> {name, Enum.sort(data["rows"])} end)
        assert declared_state == wanted["state"]
        terminal_seed(conn, dataset)
        assert terminal_state(conn) == declared_state

        source =
          case_input["domain"]
          |> atomize()
          |> Selecto.configure(conn)
          |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
          |> Selecto.apply_tenant_scope()
          |> Selecto.select(["id"])
          |> Selecto.order_by([{:asc, "id"}])

        responses =
          Enum.zip(case_input["probes"], wanted["responses"])
          |> Enum.map(fn {probe, step} ->
            assert probe["id"] == step["probe"]
            assert terminal_state(conn) == declared_state

            query =
              Selecto.subselect(source, [
                %{
                  fields: probe["fields"],
                  target_schema: Map.fetch!(@atoms, case_input["target_schema"]),
                  join_path: Enum.map(case_input["join_path"], &Map.fetch!(@atoms, &1)),
                  format:
                    Map.fetch!(%{"json_agg" => :json_agg, "count" => :count}, probe["format"]),
                  alias: String.replace(probe["id"], "-", "_"),
                  filters: Enum.map(probe["filters"], fn [field, value] -> {field, value} end),
                  order_by: [{:asc, "id"}, {:asc, "workspace_id"}, {:asc, "name"}]
                }
              ])

            {native, calls, receipts} =
              terminal_driver_observation(conn, fn -> Selecto.execute(query) end)

            if case_id == "TFM007" do
              assert step["expected"] == "pre_io_validation_refusal"
              assert step["expected_driver_returns"] == 0
              assert {:raised, %ArgumentError{} = error} = native

              assert Exception.message(error) ==
                       "Cannot build correlation condition for subselect: Join path terminates at terminals, which does not match target schema decoys"

              assert calls == 0
              assert receipts == []
            else
              assert step["expected_native_driver_returns"] == 1
              columns = step["logical_columns"]
              aliases = ["id"]
              rows = terminal_native_rows(step["rows"], probe["format"])
              assert {:returned, {:ok, {^rows, ^columns, ^aliases}}} = native
              assert calls == 1

              assert [
                       {:ok,
                        %Postgrex.Result{
                          command: :select,
                          rows: ^rows,
                          columns: ^columns,
                          num_rows: 7
                        }}
                     ] = receipts
            end

            assert terminal_state(conn) == declared_state
            native
          end)

        assert terminal_state(conn) == declared_state
        {definition["variant"], responses}
      end)

    assert results["baseline"] == results["secrets_changed"]

    if expected["tenant_O1_claim"] do
      assert results["baseline"] == results["out_of_scope_changed"]
    else
      # Authored non-tenant keys and genuine tenantless intermediates retain
      # legitimate foreign visibility. Their expected effects are independently
      # modeled above; do not manufacture an O1 tenant-equality claim.
      refute results["baseline"] == results["out_of_scope_changed"]
    end
  end

  defp pinned_json(path, expected_sha) do
    bytes = File.read!(path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected_sha
    Jason.decode!(bytes)
  end

  defp terminal_native_rows(rows, "count"), do: rows

  defp terminal_native_rows(rows, "json_agg") do
    Enum.map(rows, fn
      [id, []] -> [id, nil]
      row -> row
    end)
  end

  defp terminal_seed(conn, dataset) do
    for {name, table} <- @terminal_tables do
      Postgrex.query!(conn, "DELETE FROM " <> table, [])

      for row <- dataset[name]["rows"] do
        params = Enum.map_join(1..length(row), ",", &("$" <> Integer.to_string(&1)))
        Postgrex.query!(conn, "INSERT INTO " <> table <> " VALUES (" <> params <> ")", row)
      end
    end
  end

  defp terminal_state(conn) do
    Map.new(@terminal_tables, fn {name, table} ->
      {name, Postgrex.query!(conn, "SELECT * FROM " <> table <> " ORDER BY 1,2", []).rows}
    end)
  end

  # Isolated OTP trace sessions observe original Postgrex calls and return
  # structs on this owned connection, including executor children. They neither
  # replace the adapter nor share global trace patterns with parallel tests.
  defp terminal_driver_observation(conn, fun) do
    collector = spawn(fn -> terminal_trace_collect(0, []) end)
    session = :trace.session_create(__MODULE__, collector, [])

    try do
      :trace.function(
        session,
        {Postgrex, :query, 4},
        [{[conn, :_, :_, :_], [], [{:return_trace}]}],
        [:local]
      )

      :trace.process(session, :all, true, [:call])

      native =
        try do
          {:returned, fun.()}
        rescue
          error -> {:raised, error}
        end

      marker = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^marker}, 5_000
      request = make_ref()
      send(collector, {:collect, self(), request})
      assert_receive {^request, calls, receipts}, 5_000
      {native, calls, receipts}
    after
      :trace.session_destroy(session)
      Process.exit(collector, :kill)
    end
  end

  defp terminal_trace_collect(calls, receipts) do
    receive do
      {:trace, _pid, :call, {Postgrex, :query, _args}} ->
        terminal_trace_collect(calls + 1, receipts)

      {:trace, _pid, :return_from, {Postgrex, :query, 4}, result} ->
        terminal_trace_collect(calls, [result | receipts])

      {:collect, parent, request} ->
        send(parent, {request, calls, Enum.reverse(receipts)})
        terminal_trace_collect(0, [])
    end
  end

  defp nested_literal_rows(dataset, parent_scope) do
    people = dataset["people"]["rows"]

    people
    |> Enum.filter(&(Enum.at(&1, 1) == 7))
    |> Enum.sort_by(&hd/1)
    |> Enum.map(fn person ->
      parents =
        dataset["accounts"]["rows"]
        |> Enum.filter(fn account ->
          Enum.at(person, 3) == hd(account) and
            if(parent_scope == :explicit_identity,
              do: hd(account) == 201,
              else: Enum.at(person, 1) == Enum.at(account, 1)
            )
        end)
        |> Enum.sort_by(&{hd(&1), Enum.at(&1, 2)})
        |> Enum.map(fn account ->
          children =
            people
            |> Enum.filter(fn child ->
              Enum.at(child, 3) == hd(account) and Enum.at(child, 1) == Enum.at(account, 1)
            end)
            |> Enum.sort_by(&hd/1)
            |> Enum.map(&%{"id" => hd(&1), "name" => Enum.at(&1, 2)})

          %{"id" => hd(account), "name" => Enum.at(account, 2), "children" => children}
        end)

      [hd(person), if(parents == [], do: nil, else: parents)]
    end)
  end

  defp verify_case(conn, inputs, case_id) do
    domain = atomize(inputs["case_domains"][case_id] || inputs["domain"])
    expected = if case_id == "AJN003", do: @lookup_rows, else: @account_rows

    for definition <- [%{"dataset" => inputs["dataset"]} | inputs["variants"]] do
      dataset = definition["dataset"]
      seed(conn, dataset)
      complete_state = Map.new(dataset, fn {key, value} -> {key, Enum.sort(value["rows"])} end)
      assert state(conn) == complete_state

      scoped =
        domain
        |> Selecto.configure(conn)
        |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
        |> Selecto.apply_tenant_scope()

      for probe <- inputs["cases"][case_id] do
        assert state(conn) == complete_state

        query =
          Enum.reduce(probe["intent"]["filters"], scoped, fn filter, query ->
            Selecto.filter(query, {filter["field"], filter["value"]})
          end)
          |> Selecto.select(Enum.map(probe["intent"]["select"], &selection/1))
          |> Selecto.order_by(
            Enum.map(probe["intent"]["order_by"], fn order ->
              {if(order["direction"] == "asc", do: :asc, else: :desc), order["field"]}
            end)
          )

        {columns, aliases} = expected_columns(probe["intent"]["select"])
        assert {:ok, {rows, ^columns, ^aliases}} = Selecto.execute(query)
        assert rows == Map.fetch!(expected, probe["id"])
        assert state(conn) == complete_state
      end
    end
  end

  defp selection(field) when is_binary(field), do: field

  defp selection(%{"aggregate" => "count", "field" => field, "alias" => alias_name}),
    do: Selecto.Expr.as(Selecto.Expr.count(field), alias_name)

  defp selection(%{"aggregate" => "count", "alias" => alias_name}),
    do: Selecto.Expr.as(Selecto.Expr.count(), alias_name)

  defp expected_columns([%{"aggregate" => "count", "alias" => alias_name}]),
    do: {["count"], [alias_name]}

  defp expected_columns(fields) do
    columns = Enum.map(fields, &(String.split(&1, ".") |> List.last()))
    {columns, columns}
  end

  defp seed(conn, dataset) do
    for {key, table} <- @tables do
      Postgrex.query!(conn, "DELETE FROM " <> table, [])

      for row <- dataset[key]["rows"] do
        placeholders = Enum.map_join(1..length(row), ",", &("$" <> Integer.to_string(&1)))
        Postgrex.query!(conn, "INSERT INTO " <> table <> " VALUES (" <> placeholders <> ")", row)
      end
    end
  end

  defp state(conn),
    do:
      Map.new(@tables, fn {key, table} ->
        {key, Postgrex.query!(conn, "SELECT * FROM " <> table <> " ORDER BY 1,2", []).rows}
      end)

  defp atomize(map),
    do:
      Map.new(map, fn {key, value} ->
        {Map.fetch!(@atoms, key), atomize_value(key, value)}
      end)

  defp atomize_value(key, values) when key in ["fields", "redact_fields"],
    do: Enum.map(values, &Map.fetch!(@atoms, &1))

  defp atomize_value(key, value)
       when key in [
              "type",
              "primary_key",
              "tenant_field",
              "queryable",
              "owner_key",
              "related_key",
              "source_scope_key",
              "target_scope_key"
            ],
       do: Map.fetch!(@atoms, value)

  defp atomize_value(_key, value) when is_map(value), do: atomize(value)
  defp atomize_value(_key, value), do: value
end
