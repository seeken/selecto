defmodule Selecto.ComputedShorthandTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.Contract.ComputedValues
  alias Selecto.Domain.Shorthand.Computed

  @lead_bucket %{
    kind: :bucket,
    field: "lead_days",
    otherwise: "Unknown",
    buckets: [
      %{label: "After the start", max: -1},
      %{label: "0-6 days", min: 0, max: 6},
      %{label: "7-29 days", min: 7, max: 29},
      %{label: "30+ days", min: 30}
    ]
  }

  defp columns(extra) do
    Map.merge(
      %{
        id: %{type: :integer},
        event_id: %{type: :integer},
        purchased_at: %{type: :naive_datetime},
        refunded_on: %{type: :date},
        lead_days: %{
          type: :integer,
          computed: %{kind: :temporal_delta, from: "purchased_at", to: "event.starts_on"}
        },
        refund_days: %{
          type: :integer,
          computed: %{kind: :temporal_delta, from: "purchased_at", to: "refunded_on", unit: :day}
        },
        lead_bucket: %{type: :string, computed: @lead_bucket}
      },
      extra
    )
  end

  defp domain(extra \\ %{}) do
    cols = columns(extra)

    %{
      name: "Tickets",
      source: %{
        source_table: "tickets",
        primary_key: :id,
        fields: Map.keys(cols),
        redact_fields: [],
        columns: cols,
        associations: %{
          event: %{queryable: :event, field: :event, owner_key: :event_id, related_key: :id}
        }
      },
      schemas: %{
        event: %{
          source_table: "events",
          primary_key: :id,
          fields: [:id, :name, :starts_on],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}, starts_on: %{type: :date}},
          associations: %{}
        }
      },
      joins: %{event: %{type: :left}}
    }
  end

  defp computed(normalized, field), do: normalized.source.columns[field].computed

  defp refusal(extra) do
    case Selecto.Domain.validate(domain(extra)) do
      {:ok, _normalized, _diagnostics} -> :accepted
      {:error, diagnostics} -> Enum.map(diagnostics.errors, & &1.code)
    end
  end

  describe "expansion" do
    test "temporal_delta normalizes into days_between, with or without unit" do
      assert {:ok, normalized, _} = Selecto.Domain.validate(domain())

      assert computed(normalized, :lead_days) == %{
               kind: :expression,
               expression: [
                 "days_between",
                 ["field", "purchased_at"],
                 ["field", "event.starts_on"]
               ]
             }

      assert computed(normalized, :refund_days).expression ==
               ["days_between", ["field", "purchased_at"], ["field", "refunded_on"]]
    end

    test "bucket normalizes into a case over inclusive ranges, in the order written" do
      assert {:ok, normalized, _} = Selecto.Domain.validate(domain())

      assert computed(normalized, :lead_bucket) == %{
               kind: :expression,
               expression: [
                 "case",
                 [["lte", "lead_days", -1], ["literal", "After the start", "string"]],
                 [
                   ["and", ["gte", "lead_days", 0], ["lte", "lead_days", 6]],
                   ["literal", "0-6 days", "string"]
                 ],
                 [
                   ["and", ["gte", "lead_days", 7], ["lte", "lead_days", 29]],
                   ["literal", "7-29 days", "string"]
                 ],
                 [["gte", "lead_days", 30], ["literal", "30+ days", "string"]],
                 ["else", ["literal", "Unknown", "string"]]
               ]
             }
    end

    test "without otherwise there is no else branch" do
      band = %{kind: :bucket, field: "lead_days", buckets: [%{label: "Week", min: 0, max: 6}]}

      assert {:ok, normalized, _} =
               Selecto.Domain.validate(domain(%{band: %{type: :string, computed: band}}))

      assert computed(normalized, :band).expression ==
               [
                 "case",
                 [
                   ["and", ["gte", "lead_days", 0], ["lte", "lead_days", 6]],
                   ["literal", "Week", "string"]
                 ]
               ]
    end

    test "string-keyed declarations expand to string-keyed expression columns" do
      shorthand = %{
        "kind" => "bucket",
        "field" => "id",
        "buckets" => [%{"label" => "low", "max" => 1.5}, %{"label" => "high", "min" => 1.75}]
      }

      {domain, []} = Computed.expand(domain(%{band: %{type: :string, computed: shorthand}}))

      assert domain.source.columns.band.computed == %{
               "kind" => "expression",
               "expression" => [
                 "case",
                 [["lte", "id", 1.5], ["literal", "low", "string"]],
                 [["gte", "id", 1.75], ["literal", "high", "string"]]
               ]
             }
    end

    test "the expanded form normalizes back unchanged" do
      {:ok, normalized, _} = Selecto.Domain.validate(domain())
      {:ok, again, _} = Selecto.Domain.validate(%{domain() | source: normalized.source})
      assert again.source.columns == normalized.source.columns
    end

    test "fifty buckets are accepted" do
      buckets = for i <- 0..49, do: %{label: "b#{i}", min: i, max: i}
      bucket = %{type: :string, computed: %{kind: :bucket, field: "id", buckets: buckets}}
      assert refusal(%{band: bucket}) == :accepted
    end
  end

  describe "invalid declarations refuse the domain" do
    @bad_delta [
      unit_hour: %{kind: :temporal_delta, from: "purchased_at", to: "refunded_on", unit: "hour"},
      missing_to: %{kind: :temporal_delta, from: "purchased_at"},
      unknown_key: %{
        kind: :temporal_delta,
        from: "purchased_at",
        to: "refunded_on",
        absolute: true
      },
      non_date_operand: %{kind: :temporal_delta, from: "id", to: "refunded_on"},
      non_date_association_operand: %{
        kind: :temporal_delta,
        from: "event.name",
        to: "refunded_on"
      },
      unknown_field: %{kind: :temporal_delta, from: "nowhere", to: "refunded_on"},
      unknown_association_field: %{
        kind: :temporal_delta,
        from: "event.nowhere",
        to: "refunded_on"
      }
    ]

    for {name, shorthand} <- @bad_delta do
      test "temporal_delta: #{name}" do
        assert :invalid_computed_value in refusal(%{
                 bad: %{type: :integer, computed: unquote(Macro.escape(shorthand))}
               })
      end
    end

    test "temporal_delta: a declared type the integer result does not fit" do
      bad = %{type: :string, computed: %{kind: :temporal_delta, from: "id", to: "refunded_on"}}
      assert :invalid_computed_value in refusal(%{bad: bad})
    end

    test "days_between: one operand, or a non-date operand" do
      one = %{kind: :expression, expression: ["days_between", ["field", "refunded_on"]]}

      integer = %{
        kind: :expression,
        expression: ["days_between", ["field", "id"], ["field", "refunded_on"]]
      }

      assert :invalid_computed_value in refusal(%{bad: %{type: :integer, computed: one}})
      assert :invalid_computed_value in refusal(%{bad: %{type: :integer, computed: integer}})
    end

    defp bucket(buckets, extra \\ %{}),
      do: Map.merge(%{kind: :bucket, field: "id", buckets: buckets}, extra)

    @bad_buckets [
      no_buckets: {[], %{}},
      no_bounds: {[%{label: "a"}], %{}},
      min_above_max: {[%{label: "a", min: 5, max: 1}], %{}},
      duplicate_label: {[%{label: "a", max: 1}, %{label: "a", min: 2}], %{}},
      blank_label: {[%{label: " ", max: 1}], %{}},
      shared_bound: {[%{label: "a", min: 0, max: 5}, %{label: "b", min: 5, max: 9}], %{}},
      open_end_overlap: {[%{label: "a", min: 3}, %{label: "b", min: 7, max: 9}], %{}},
      written_out_of_order_overlap: {[%{label: "b", min: 7, max: 9}, %{label: "a", min: 3}], %{}},
      non_numeric_bound: {[%{label: "a", min: "x"}], %{}},
      otherwise_repeats_label: {[%{label: "a", min: 0}], %{otherwise: "a"}},
      unknown_key: {[%{label: "a", min: 0}], %{ranges: []}},
      unknown_bucket_key: {[%{label: "a", min: 0, step: 1}], %{}},
      fifty_one: {for(i <- 0..50, do: %{label: "b#{i}", min: i, max: i}), %{}}
    ]

    for {name, {buckets, extra}} <- @bad_buckets do
      test "bucket: #{name}" do
        shorthand = bucket(unquote(Macro.escape(buckets)), unquote(Macro.escape(extra)))
        assert :invalid_computed_value in refusal(%{bad: %{type: :string, computed: shorthand}})
      end
    end

    test "bucket: a string source field, here or one association away" do
      for field <- ["event.name", "purchased_at"] do
        shorthand = %{kind: :bucket, field: field, buckets: [%{label: "a", min: 0}]}
        assert :invalid_computed_value in refusal(%{bad: %{type: :string, computed: shorthand}})
      end
    end

    test "an unexpanded shorthand is reported once, not also as an unknown kind" do
      bad = %{type: :string, computed: bucket([])}
      assert refusal(%{bad: bad}) == [:invalid_computed_value]
    end

    test "configure refuses an invalid shorthand whatever :validate says" do
      bad = %{type: :string, computed: bucket([%{label: "a"}])}

      for validate <- [true, false] do
        assert_raise Selecto.DomainValidator.ValidationError,
                     ~r/needs a min, a max, or both/,
                     fn ->
                       Selecto.configure(domain(%{bad: bad}), :compile_only, validate: validate)
                     end
      end
    end
  end

  describe "days_between" do
    test "takes exactly two operands" do
      assert {:ok, ["days_between", ["field", "a"], ["field", "b"]]} =
               ComputedValues.normalize(["days_between", ["field", "a"], ["field", "b"]])

      assert {:error, _} = ComputedValues.normalize(["days_between", ["field", "a"]])

      assert {:error, _} =
               ComputedValues.normalize([
                 "days_between",
                 ["field", "a"],
                 ["field", "b"],
                 ["field", "c"]
               ])
    end

    test "is an integer of date or datetime operands" do
      types = %{"d" => :date, "t" => :naive_datetime, "u" => :utc_datetime, "s" => :string}
      resolve = &Map.get(types, &1, :unknown)
      infer = &ComputedValues.infer(["days_between", ["field", &1], ["field", &2]], resolve)

      assert {:ok, :integer} = infer.("d", "t")
      assert {:ok, :integer} = infer.("u", "d")
      assert {:ok, :integer} = infer.("d", "elsewhere")
      assert {:error, message} = infer.("s", "d")
      assert message =~ "date or datetime"
    end
  end

  describe "queries" do
    defp sql(query) do
      {sql, _aliases, params} = Selecto.gen_sql(query, [])
      {sql, params}
    end

    test "shorthand columns run as their expressions with bound labels" do
      {sql, params} =
        domain()
        |> Selecto.configure(:compile_only)
        |> Selecto.select(["id", "lead_days", "refund_days", "lead_bucket"])
        |> sql()

      assert sql =~ ~r/\(CAST\([^)]*starts_on[^)]* AS DATE\) - CAST\([^)]*purchased_at/
      assert String.downcase(sql) =~ "join events"
      assert sql =~ "CASE WHEN"
      refute sql =~ "days"
      refute sql =~ "Unknown"
      assert ["After the start", "0-6 days", "7-29 days", "30+ days", "Unknown"] -- params == []
    end

    test "shorthand columns filter, group and order like computed columns" do
      {sql, _params} =
        domain()
        |> Selecto.configure(:compile_only)
        |> Selecto.select(["lead_bucket", {:count}])
        |> Selecto.filter({"lead_days", {:>=, 7}})
        |> Selecto.group_by(["lead_bucket"])
        |> Selecto.order_by("lead_bucket")
        |> sql()

      assert String.downcase(sql) =~ ~r/group by 1\s/
      assert sql =~ ~r/where.*CAST\(.* AS DATE\) - CAST\(/s
    end
  end
end
