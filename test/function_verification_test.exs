defmodule Selecto.FunctionVerificationTest do
  use ExUnit.Case, async: true

  alias Selecto.FunctionVerification.{Report, Request}

  defmodule SuccessfulAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :function_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false

    def verify_function(connection, %Request{} = request, opts) do
      send(connection, {:function_verification_request, request, opts})

      {:ok,
       %{
         status: :database_resolved,
         function_id: "adapter-cannot-override-request",
         signature_fingerprint: "adapter-cannot-override-request",
         resolved_identity: "public.similarity(text,text)",
         server: %{version: 17},
         evidence: %{strategy: :mock_describe},
         diagnostics: []
       }}
    end
  end

  defmodule UnsupportedAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :unsupported_function_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
    def supports?(_feature), do: false
  end

  defmodule MissingCallbackAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :missing_callback_function_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false
  end

  defmodule RaisingAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :raising_function_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false
    def verify_function(_connection, _request, _opts), do: raise("adapter secret failure")
  end

  defmodule InvalidReportAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :invalid_report_function_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false
    def verify_function(_connection, _request, _opts), do: {:ok, %{status: :made_up}}
  end

  test "dispatches only normalized signature metadata to a capable adapter" do
    selecto = selecto(SuccessfulAdapter)

    assert {:ok, %Report{status: :database_resolved} = report} =
             Selecto.verify_function(selecto, "similarity", ["name", "TOP SECRET"],
               mode: :strict,
               call_site: :select,
               timeout: 500
             )

    assert report.adapter == :function_test
    assert report.function_id == "similarity"
    assert report.resolved_identity == "public.similarity(text,text)"
    assert report.server == %{version: 17}
    assert report.evidence == %{strategy: :mock_describe}

    assert_receive {:function_verification_request, %Request{} = request, [timeout: 500]}
    assert request.function_id == "similarity"
    assert request.sql_name == "public.similarity"
    assert request.call_site == :select
    assert request.protocol_version == Request.protocol_version()
    assert Enum.map(request.arguments, & &1.type) == [:string, :string]

    assert request.requirements == %{
             adapters: [:postgresql],
             requires: [extension: "pg_trgm"],
             volatility: :stable
           }

    refute inspect(request) =~ "TOP SECRET"
  end

  test "request fingerprints describe signatures rather than runtime values" do
    selecto = selecto(SuccessfulAdapter)

    assert {:ok, first} =
             Selecto.verify_function(selecto, "similarity", ["name", "first"], mode: :warn)

    assert_receive {:function_verification_request, first_request, []}

    assert {:ok, second} =
             Selecto.verify_function(selecto, "similarity", ["name", "second"], mode: :warn)

    assert_receive {:function_verification_request, second_request, []}
    assert first.signature_fingerprint == second.signature_fingerprint
    assert first_request.signature_fingerprint == second_request.signature_fingerprint
  end

  test "warn mode reports an adapter that does not advertise verification" do
    assert {:ok, %Report{} = report} =
             UnsupportedAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :warn)

    assert report.status == :unsupported_adapter
    assert report.diagnostics == [%{code: :function_verification_not_supported}]
  end

  test "strict mode fails closed when verification is unsupported" do
    assert {:error, %Selecto.Error{} = error} =
             UnsupportedAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :strict)

    assert error.type == :validation_error
    assert error.details.code == :function_verification_failed
    assert error.details.status == :unsupported_adapter
  end

  test "capability advertisement without the callback fails closed" do
    assert {:ok, report} =
             MissingCallbackAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :warn)

    assert report.status == :unsupported_adapter
    assert report.diagnostics == [%{code: :function_verification_callback_missing}]
  end

  test "callback failures are sanitized and become indeterminate evidence" do
    assert {:ok, report} =
             RaisingAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :warn)

    assert report.status == :indeterminate

    assert report.diagnostics == [
             %{code: :function_verification_callback_failed, class: :exception}
           ]

    refute inspect(report) =~ "adapter secret failure"
  end

  test "invalid adapter reports cannot claim connected resolution" do
    assert {:ok, report} =
             InvalidReportAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :warn)

    assert report.status == :indeterminate
    assert report.diagnostics == [%{code: :invalid_function_report}]
  end

  test "off mode emits no connected claim and does not dispatch" do
    assert {:ok, report} =
             SuccessfulAdapter
             |> selecto()
             |> Selecto.verify_function("similarity", ["name", "value"], mode: :off)

    assert report.status == :unverified
    assert report.proof_level == :none
    refute_received {:function_verification_request, _request, _opts}
  end

  test "invalid modes and statically invalid calls are structured errors" do
    selecto = selecto(SuccessfulAdapter)

    assert {:error, mode_error} =
             Selecto.verify_function(selecto, "similarity", ["name", "value"], mode: :maybe)

    assert mode_error.details.code == :invalid_function_verification_mode

    assert {:error, type_error} =
             Selecto.verify_function(selecto, "similarity", ["id", "value"], mode: :warn)

    assert type_error.details.code == :argument_type_mismatch
  end

  defp selecto(adapter) do
    %{
      name: "Function verification test",
      source: %{
        source_table: "products",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      functions: %{
        "similarity" => %{
          kind: :scalar,
          sql_name: "public.similarity",
          args: [
            %{name: :left, type: :string, source: :selector},
            %{name: :right, type: :string, source: :value}
          ],
          returns: :float,
          allowed_in: [:select],
          database: %{
            adapters: [:postgresql],
            requires: [extension: "pg_trgm"],
            volatility: :stable,
            ignored_domain_metadata: "not sent to adapters"
          }
        }
      }
    }
    |> Selecto.configure(self(), adapter: adapter)
  end
end
