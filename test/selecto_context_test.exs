defmodule Selecto.ContextTest do
  use ExUnit.Case, async: true

  alias Selecto.Context
  alias Selecto.Write.Result

  defmodule Adapter do
    @behaviour Selecto.DB.Adapter

    @impl true
    def name, do: :context_test

    @impl true
    def connect(connection), do: {:ok, connection}

    @impl true
    def execute(:all, _query, _params, _opts) do
      {:ok, %{rows: [[1, "Alpha"], [2, "Beta"]], columns: ["id", "name"]}}
    end

    def execute(:one, _query, _params, _opts) do
      {:ok, %{rows: [[1, "Alpha"]], columns: ["id", "name"]}}
    end

    def execute(:empty, _query, _params, _opts) do
      {:ok, %{rows: [], columns: ["id", "name"]}}
    end

    def execute(:error, _query, _params, _opts), do: {:error, :database_unavailable}

    @impl true
    def placeholder(index), do: "$#{index}"

    @impl true
    def quote_identifier(identifier), do: ~s("#{identifier}")

    @impl true
    def supports?(_feature), do: false
  end

  describe "all/2 and one/2" do
    test "return atom-safe maps for context reads" do
      assert {:ok, [%{id: 1, name: "Alpha"}, %{id: 2, name: "Beta"}]} =
               Context.all(selecto(:all), analyze_complexity: false)

      assert {:ok, [%{"id" => 1, "name" => "Alpha"}, %{"id" => 2, "name" => "Beta"}]} =
               Context.all(selecto(:all), keys: :strings, analyze_complexity: false)
    end

    test "distinguishes one, none, and multiple records" do
      assert {:ok, %{id: 1, name: "Alpha"}} =
               Context.one(selecto(:one), analyze_complexity: false)

      assert {:error, :not_found} = Context.one(selecto(:empty), analyze_complexity: false)
      assert {:error, :multiple_results} = Context.one(selecto(:all), analyze_complexity: false)
    end

    test "preserves normalized query errors" do
      assert {:error, %Selecto.Error{type: :query_error}} =
               Context.all(selecto(:error), analyze_complexity: false)
    end
  end

  describe "take_attrs/2" do
    test "normalizes allowed atom and string keys and ignores unknown fields" do
      attrs = %{
        "name" => "string value",
        "status" => "active",
        "admin" => true,
        name: "atom value"
      }

      assert Context.take_attrs(attrs, [:name, :status]) == %{
               name: "atom value",
               status: "active"
             }
    end

    test "never interns unknown input keys" do
      unknown = "context_input_#{System.unique_integer([:positive])}"
      refute_existing_atom(unknown)

      assert Context.take_attrs(%{unknown => "value"}, [:name]) == %{}
      refute_existing_atom(unknown)
    end

    test "requires an atom allowlist" do
      assert_raise ArgumentError, ~r/allowed context fields must be atoms/, fn ->
        Context.take_attrs(%{"name" => "Alpha"}, ["name"])
      end
    end
  end

  describe "write_one/2" do
    test "unwraps and normalizes a tagged returned record" do
      result = %Result{
        operation: :insert,
        affected_rows: 1,
        rows: [%{"id" => 1, "name" => "Alpha"}]
      }

      assert {:ok, %{id: 1, name: "Alpha"}} = Context.write_one({:ok, result})
      assert {:ok, %{"id" => 1, "name" => "Alpha"}} = Context.write_one(result, keys: :strings)
    end

    test "does not create atoms for unknown returned column names" do
      unknown = "context_returning_#{System.unique_integer([:positive])}"
      refute_existing_atom(unknown)

      result = %Result{
        operation: :insert,
        affected_rows: 1,
        rows: [%{unknown => "value"}]
      }

      assert {:ok, %{^unknown => "value"}} = Context.write_one(result)
      refute_existing_atom(unknown)
    end

    test "preserves write errors and rejects unusable result shapes" do
      error = %Selecto.Write.Error{type: :execution_failed, message: "failed"}

      assert {:error, ^error} = Context.write_one({:error, error})

      assert {:error, :no_returned_record} =
               Context.write_one(%Result{operation: :update, affected_rows: 1, rows: []})

      assert {:error, :multiple_returned_records} =
               Context.write_one(%Result{
                 operation: :update,
                 affected_rows: 2,
                 rows: [%{"id" => 1}, %{"id" => 2}]
               })

      assert {:error, :invalid_write_result} = Context.write_one(:unexpected)
    end
  end

  defp selecto(connection) do
    domain()
    |> Selecto.configure(connection, adapter: Adapter)
    |> Selecto.select(["id", "name"])
  end

  defp domain do
    %{
      name: "Context helper test",
      source: %{
        source_table: "projects",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp refute_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end
end
