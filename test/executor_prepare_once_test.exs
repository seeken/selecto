defmodule Selecto.ExecutorPrepareOnceTest do
  # Preparing a read costs one compile, and nothing that grows with the domain:
  # - the compile prepare_read needs (what the compile says of the text) is
  #   the statement execute/2 runs, compiled inside its compile span;
  # - the read is compiled for the names its text holds only when they are
  #   needed before the adapter has prepared it;
  # - the domain's relations and declared schemas come from the index
  #   Selecto.configure/3 built, unless the query's domain is no longer the
  #   one indexed;
  # - the statement's text is scanned for the relations it names only when an
  #   adapter asks for them, or the statement defines a list.

  # Counts calls with call-count tracing, which is global.
  use ExUnit.Case, async: false

  alias Selecto.Domain.Relations

  @build {Selecto.Builder.Sql, :build_iodata_with_joins, 2}

  defmodule Adapter do
    def name, do: :prepare_once_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(:execute_timeout), do: true
    def supports?(_feature), do: false

    def execute(connection, query, _params, opts) do
      send(connection.test, {:executed, query, opts})
      {:ok, %{rows: [[1, "one"]], columns: ["id", "name"]}}
    end
  end

  # Resolves the relations of the read before it compiles, as the PostgreSQL
  # adapter does for the schemas a domain declares.
  defmodule ResolvingAdapter do
    def name, do: :prepare_once_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(:execute_timeout), do: true
    def supports?(_feature), do: false

    def prepare_read(selecto, connection) do
      send(connection.test, {:relations, Selecto.Executor.domain_relations(selecto)})
      {:ok, %{selecto | set: Map.put(selecto.set, :qualified_relations, %{"items" => "app"})}}
    end

    def execute(_connection, _query, _params, _opts),
      do: {:ok, %{rows: [[1, "one"]], columns: ["id", "name"]}}
  end

  # Changes what the read compiles to before it compiles, as an adapter that
  # loads storage types does.
  defmodule RewritingAdapter do
    def name, do: :prepare_once_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(:execute_timeout), do: true
    def supports?(_feature), do: false

    def prepare_read(selecto, _connection), do: {:ok, Selecto.filter(selecto, {"id", {:lt, 9}})}

    def execute(connection, query, params, _opts) do
      send(connection.test, {:executed, query, params})
      {:ok, %{rows: [[1, "one"]], columns: ["id", "name"]}}
    end
  end

  # Refuses the read before it compiles.
  defmodule RefusingAdapter do
    def name, do: :prepare_once_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def prepare_read(_selecto, _connection),
      do: {:error, Selecto.Error.validation_error("refused before it compiles", %{})}

    def execute(_connection, _query, _params, _opts), do: raise("a refused read ran")
  end

  defp domain do
    %{
      name: "Prepare once",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :category_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          category_id: %{type: :integer}
        },
        associations: %{
          category: %{
            queryable: :categories,
            field: :category,
            owner_key: :category_id,
            related_key: :id
          }
        }
      },
      schemas: %{
        categories: %{
          source_table: "categories",
          source_schema: "catalog",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{category: %{type: :left, name: "category"}}
    }
  end

  defp query(adapter) do
    Selecto.configure(domain(), nil, validate: false)
    |> Map.put(:adapter, adapter)
    |> Map.put(:connection, %{test: self()})
    |> Selecto.select(["id", "name"])
    |> Selecto.filter({"id", {:gt, 0}})
  end

  defp builds(fun) do
    Code.ensure_loaded!(elem(@build, 0))
    1 = :erlang.trace_pattern(@build, true, [:local, :call_count])

    try do
      result = fun.()
      {:call_count, count} = :erlang.trace_info(@build, :call_count)
      {count, result}
    after
      :erlang.trace_pattern(@build, false, [:local, :call_count])
    end
  end

  describe "a read compiles once" do
    test "for its provenance and the statement it runs" do
      query = query(Adapter)
      {sql, _aliases, _params} = Selecto.gen_sql(query, [])

      assert {1, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)
      assert_received {:executed, ^sql, opts}
      assert opts[:selecto_generated] == true
      refute Keyword.has_key?(opts, :selecto_raw_sql)
    end

    test "when it joins, and no adapter asks for the relations it names" do
      query = query(Adapter) |> Selecto.select(["id", "category.name"])
      {sql, _aliases, _params} = Selecto.gen_sql(query, [])

      assert {1, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)
      assert_received {:executed, ^sql, _opts}
    end

    test "and once more when the adapter asks for the relations its text names" do
      # The domain declares a join: the relations the read names are compiled
      # for when the adapter asks, before it has prepared the statement that
      # runs.
      query = query(ResolvingAdapter)

      assert {2, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)
      # The join the read does not use is not one of its relations.
      assert_received {:relations, ["items"]}

      joined = Selecto.select(query, ["id", "category.name"])
      assert {2, {:ok, _result}} = builds(fn -> Selecto.execute(joined) end)
      assert_received {:relations, relations}
      assert Enum.sort(relations) == ["categories", "items"]
    end

    test "when the adapter changed what compiles, and runs that statement" do
      query = query(RewritingAdapter)
      {sql, _aliases, params} = query |> Selecto.filter({"id", {:lt, 9}}) |> Selecto.gen_sql([])

      assert {1, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)
      assert_received {:executed, ^sql, ^params}
    end

    test "and keeps the mark of a host fragment" do
      query = query(Adapter) |> Selecto.select([{:field, {:raw_sql, "1 + 1"}, "two"}])

      assert {1, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)
      assert_received {:executed, _sql, opts}
      assert opts[:selecto_raw_sql] == true
      refute Keyword.has_key?(opts, :selecto_generated)
    end

    test "with compiler options, the statement compiles with them" do
      query = query(Adapter)
      opts = [unique_projection_aliases: true]
      {sql, _aliases, _params} = Selecto.gen_sql(query, opts)

      assert {2, {:ok, _result}} = builds(fn -> Selecto.execute(query, opts) end)
      assert_received {:executed, ^sql, _opts}
    end
  end

  describe "the compile span" do
    # Each event with the handler's own clock and the compiles run so far, so
    # a test sees where the span sits around the compile.
    def handle_event(event, measurements, metadata, test) do
      {:call_count, compiles} = :erlang.trace_info(@build, :call_count)
      send(test, {List.last(event), measurements, metadata, System.monotonic_time(), compiles})
    end

    setup do
      handler = "prepare-once-#{System.unique_integer([:positive])}"

      events =
        for phase <- [:start, :stop, :exception], do: [:selecto, :telemetry, :compile, phase]

      :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "is emitted once per read, around the compile it runs, as it runs" do
      reads = [
        query(Adapter),
        query(Adapter) |> Selecto.select(["id", "category.name"]),
        query(ResolvingAdapter),
        query(ResolvingAdapter) |> Selecto.select(["id", "category.name"]),
        query(RewritingAdapter)
      ]

      for query <- reads do
        before = System.monotonic_time()
        assert {compiles, {:ok, _result}} = builds(fn -> Selecto.execute(query) end)

        assert_received {:start, %{monotonic_time: started_at, system_time: _}, started,
                         start_seen, compiled_at_start}

        assert_received {:stop, %{duration: duration, monotonic_time: stopped_at}, stopped,
                         stop_seen, compiled_at_stop}

        refute_received {_phase, _measurements, _metadata, _seen, _compiles}

        # The start event is emitted before the statement compiles and the
        # stop event after, each when it happens: the statement the read runs
        # is the one compile between them, and the last of the read.
        assert compiled_at_stop == compiled_at_start + 1
        assert compiled_at_stop == compiles
        assert before <= started_at and started_at <= start_seen
        assert start_seen <= stop_seen
        assert started_at <= stopped_at - duration
        assert stopped_at <= stop_seen
        assert stopped.outcome == :ok
        assert stopped.telemetry_span_context == started.telemetry_span_context
        assert stopped.operation_kind == :execute
      end
    end

    test "is not emitted for a read refused before it compiles" do
      assert {0, {:error, %Selecto.Error{}}} =
               builds(fn -> Selecto.execute(query(RefusingAdapter)) end)

      refute_received {_phase, _measurements, _metadata, _seen, _compiles}
    end
  end

  describe "the domain's relations" do
    test "are indexed at configure" do
      query = query(Adapter)

      assert %{domain: indexed, tables: tables, schemas: schemas} = query.config.domain_relations
      assert indexed == query.domain
      assert Enum.sort(tables) == ["categories", "items"]
      assert schemas == %{"categories" => "catalog"}
      assert Relations.indexed?(query)
      assert Relations.tables(query) == tables
      assert Relations.schemas(query) == schemas
    end

    test "are walked when the query's domain is not the one indexed" do
      query = query(Adapter)

      moved =
        query.domain
        |> put_in([:schemas, :categories, :source_table], "moved")
        |> put_in([:schemas, :categories, :source_schema], :archive)

      stale = %{query | domain: moved}

      refute Relations.indexed?(stale)
      assert Enum.sort(Relations.tables(stale)) == ["items", "moved"]
      assert Relations.schemas(stale) == %{"moved" => "archive"}
      assert Relations.tables(%{domain: moved}) == Relations.tables(stale)
    end

    test "a table declared with two schemas is a conflict" do
      twice =
        put_in(domain(), [:schemas, :other], %{
          source_table: "categories",
          source_schema: "elsewhere"
        })

      assert Relations.index(twice).schemas == %{"categories" => :conflict}
    end
  end

  describe "text that is not a plain name" do
    test "in the domain is found at configure" do
      query = query(Adapter)
      assert query.config.domain_text == false
      refute Selecto.Builder.Provenance.config_text?(query)

      texty = put_in(domain(), [:schemas, :categories, :source_table], "categories c")
      configured = Selecto.configure(texty, nil, validate: false)
      assert configured.config.domain_text == true
      assert Selecto.Builder.Provenance.config_text?(configured)

      # A domain replaced after configure is read itself, not the index.
      assert Selecto.Builder.Provenance.config_text?(%{query | domain: texty})
    end
  end
end
