defmodule SelectoUpdato.QueryEnforcedScalarV2Test do
  # query_enforced_scalar v2 (certification specification 2.37): every case of
  # the harness corpora, copied byte for byte into test/fixtures, runs through
  # the in-process candidate evaluator with the case's declared column type,
  # metadata trust level and backend.
  use ExUnit.Case, async: true

  alias SelectoUpdato.QueryEnforcement
  alias SelectoUpdato.QueryEnforcement.Scalar

  @fixtures Path.expand("../fixtures", __DIR__)

  defp load(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  @trust %{
    "verified" => :verified,
    "base_verified" => :base_verified,
    "unverified" => :unverified
  }

  defp trust(entry), do: Map.fetch!(@trust, Map.get(entry, "metadata", "verified"))

  defp backend("mysql_family"), do: :mysql_family
  defp backend(_), do: :other

  defp op("ne"), do: :neq
  defp op(name), do: String.to_existing_atom(name)

  defp literal(nil), do: nil
  defp literal(value), do: {:literal, value}

  # The case as a compiled enforcement predicate on field `subject`, evaluated
  # by the public candidate evaluator the insert path uses.
  defp evaluate(entry) do
    column =
      Scalar.column(entry["column_type"],
        trust: trust(entry),
        backend: backend(entry["backend"])
      )

    columns = %{"subject" => column, "subject_peer" => column}
    subject = {:field, "subject"}

    {predicate, candidate} =
      case {entry["form"], entry["op"]} do
        {"absent_field", op} ->
          {{op(op), subject, literal(entry["expected"])}, %{}}

        {"column_pair", op} ->
          {{op(op), subject, {:field, "subject_peer"}},
           %{"subject" => entry["actual"], "subject_peer" => entry["expected"]}}

        {nil, "in"} ->
          {{:in, subject, Enum.map(entry["expected"], &{:literal, &1})},
           %{"subject" => entry["actual"]}}

        {nil, "not_in"} ->
          {{:not, {:in, subject, Enum.map(entry["expected"], &{:literal, &1})}},
           %{"subject" => entry["actual"]}}

        {nil, op} ->
          {{op(op), subject, {:literal, entry["expected"]}}, %{"subject" => entry["actual"]}}
      end

    case QueryEnforcement.evaluate_candidate(predicate, candidate, columns) do
      {:ok, true} -> "true"
      {:ok, false} -> "false"
      {:ok, :unknown} -> "unknown"
      {:error, _details} -> "query_rule_not_evaluable"
    end
  end

  # A NULL scalar `expected` is SQL NULL: the compiled predicate carries a
  # NULL literal only through this evaluator (the filter compiler rewrites
  # `= nil` to IS NULL), so the case uses the literal directly.
  defp check(cases) do
    failures =
      for entry <- cases,
          classified = Scalar.classify(entry["column_type"], backend(entry["backend"])),
          result = evaluate(entry),
          Atom.to_string(classified) != entry["type_class"] or result != entry["outcome"] do
        {entry["id"], entry["type_class"], classified, entry["outcome"], result}
      end

    assert failures == []
  end

  test "the v2 main corpus: 714 cases, every outcome and type class" do
    fixture = load("query_enforced_scalar_v2.json")
    assert fixture["format"] == "selecto.query-enforced-scalar.v2"
    cases = fixture["cases"]
    assert length(cases) == 714

    assert Enum.frequencies_by(cases, &String.first(&1["id"])) ==
             %{"S" => 239, "T" => 212, "N" => 119, "I" => 103, "U" => 31, "X" => 10}

    assert Enum.frequencies_by(cases, &Map.get(&1, "metadata", "verified")) ==
             %{"verified" => 666, "base_verified" => 34, "unverified" => 14}

    assert Enum.count(cases, &(&1["backend"] == "mysql_family")) == 11
    # The evaluator's type classes are the corpus's own lists.
    assert Scalar.type_classes() == fixture["type_classes"]
    check(cases)
  end

  test "the v2 edge corpus: 532 cases" do
    fixture = load("query_enforced_scalar_edges_v2.json")
    assert fixture["format"] == "selecto.query-enforced-scalar-edges.v2"
    assert length(fixture["cases"]) == 532
    check(fixture["cases"])
  end

  test "declared names parse: parameters, max, collations and invalid lists" do
    assert Scalar.parse("VARCHAR(2) CHARACTER SET utf8mb4 COLLATE \"C\"") ==
             %{base: "varchar", params: [2], collation: "c"}

    assert Scalar.parse("nvarchar(max)").params == []
    assert Scalar.parse("char(max)").params == :invalid
    assert Scalar.parse("enum('a','b')").params == :invalid
    assert Scalar.parse("numeric( 10 , -2 )").params == [10, -2]
    assert Scalar.classify("charge_amount") == :identity
    assert Scalar.classify("text collate utf8mb4_bin") == :identity
    assert Scalar.classify("text collate utf8mb4_bin", :mysql_family) == :text
    # Catalog determinism overrides the name.
    assert Scalar.column("text", trust: :verified, deterministic: false).class == :identity
  end

  test "native candidates compare as their bound text or are refused" do
    assert Scalar.bound_text(Decimal.new("10.50")) == {:ok, "10.50"}
    assert Scalar.bound_text(10) == {:ok, "10"}
    assert Scalar.bound_text(true) == {:ok, "true"}
    assert Scalar.bound_text(1.5) == :error
    assert Scalar.bound_text(~N[2024-01-01 10:00:00]) == :error
    assert Scalar.bound_text(Decimal.new("NaN")) == :error

    columns = %{"amount" => Scalar.column("numeric(12,2)", trust: :verified)}
    predicate = {:eq, {:field, "amount"}, {:literal, 10}}

    assert QueryEnforcement.evaluate_candidate(
             predicate,
             %{"amount" => Decimal.new("10.00")},
             columns
           ) ==
             {:ok, true}

    assert {:error, _} =
             QueryEnforcement.evaluate_candidate(predicate, %{"amount" => 10.0}, columns)
  end
end
