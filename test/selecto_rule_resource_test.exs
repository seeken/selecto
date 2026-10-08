defmodule Selecto.Rule.ResourceTest do
  use ExUnit.Case, async: true

  alias Selecto.Rule.{Contract, Evaluator}

  test "text length counts Unicode scalars rather than grapheme clusters or UTF-8 bytes" do
    assert :passed = check(%{op: "text.length", exact: 2}, "e\u0301")
    assert :passed = check(%{op: "text.length", exact: 2}, "🇺🇸")
    assert :passed = check(%{op: "text.length", exact: 1}, "😀")
    assert {:failed, %{actual: 2}} = check(%{op: "text.length", exact: 1}, "e\u0301")
  end

  test "the finite matcher preserves grouping, repetition, alternatives and empty closure" do
    for {pattern, text, mode, expected} <- [
          {"(ab|c)+d?", "abcabd", "full", :passed},
          {"(ab|c)+d?", "xabcabdy", "search", :passed},
          {"(ab|c)+d?", "xabcabd", "full", :failed},
          {"(a?)*b", "b", "full", :passed},
          {"(a?)*b", "aaaa", "full", :failed},
          {"a{0}", "", "full", :passed},
          {"a{2,}", "aaa", "full", :passed},
          {"a{2,4}", "aaaaa", "full", :failed},
          {"a*", "", "search", :passed},
          {"a*b", "aaabx", "full", :failed},
          {".", "😀", "full", :passed},
          {".", "e\u0301", "full", :failed},
          {".", "\n", "full", :failed}
        ] do
      result = check(pattern(pattern, mode), text)
      assert if(expected == :passed, do: result == :passed, else: match?({:failed, _}, result))
    end
  end

  test "ASCII classes and escaped metacharacters retain their declared meaning" do
    for {source, text} <- [
          {"[A-Z0-9]{4,12}", "AB12"},
          {"[a-zA-Z_]\\w{0,8}", "a_9"},
          {"[^a-z]", "é"},
          {"\\D", "😀"},
          {"\\s", "\v"},
          {"[a\\-z]", "-"},
          {"[]]", "]"},
          {"[[]", "["},
          {"\\^\\$", "^$"}
        ] do
      assert :passed = check(pattern(source), text)
    end

    assert {:failed, _} = check(pattern("\\w"), "é")
    assert {:failed, _} = check(pattern("\\s"), "\u00a0")
    assert {:failed, _} = check(pattern("[a\\-z]"), "b")
    assert :passed = check(pattern("a\t\0"), "a\t\0")
  end

  test "engine-specific syntax and malformed ranges fail closed at public compilation" do
    for source <- [
          "^a",
          "a$",
          "(?=a)",
          "(a)\\1",
          "a*?",
          "a++",
          "[a&&b]",
          "[[:alpha:]]",
          "[z-a]",
          "[\\d-z]",
          "[]",
          "(",
          "a{2,1}",
          "\\p{L}"
        ] do
      assert {:error, %{code: :invalid_text_pattern}} = Contract.compile_test(pattern(source))
    end
  end

  test "excessive repetitions, expanded state count and depth have a resource diagnostic" do
    for source <- [
          "a{999999}",
          "(a{128}){128}",
          String.duplicate("(", 17) <> "a" <> String.duplicate(")", 17)
        ] do
      assert {:error, %{code: :evaluation_limit}} = Contract.compile_test(pattern(source))
    end
  end

  test "nullable nested repetition does not backtrack exponentially" do
    assert {:failed, %{code: :pattern_mismatch}} =
             check(pattern("(a+)+b"), String.duplicate("a", 4096))

    assert :passed = check(pattern("(a+)+b"), String.duplicate("a", 4095) <> "b")
  end

  test "one work budget covers all logical branches and errors cannot become ANY success" do
    expensive = %{op: "all", rules: List.duplicate(pattern("a*"), 100)}
    subject = String.duplicate("a", 4096)

    assert {:error, %{code: :evaluation_limit}} = check(expensive, subject)

    for operator <- ["all", "any"] do
      test = %{op: operator, rules: [%{op: "presence.required"}, expensive]}
      assert {:error, %{code: :evaluation_limit}} = check(test, subject)
    end

    assert {:error, %{code: :evaluation_limit}} = check(%{op: "not", rule: expensive}, subject)
  end

  test "one budget covers the whole record across binding conditions and tests" do
    rules = rules(pattern("a*"))
    bindings = Map.new(1..100, &{"binding#{&1}", rules.bindings.check})
    assert {:ok, contract} = Contract.compile_rules(%{rules | bindings: bindings})

    assert %{disposition: :error, outcomes: outcomes} =
             Evaluator.evaluate(contract, :candidate, %{subject: String.duplicate("a", 4096)})

    assert Enum.any?(outcomes, &(&1.code == :evaluation_limit))
    # A new invocation has its own counter; caller options cannot expand it.
    assert %{disposition: :passed} = Evaluator.evaluate(contract, :candidate, %{subject: "a"})

    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "text.length", exact: 17000}, String.duplicate("a", 17000))
  end

  test "normalization and a false condition cannot conceal an oversized authored subject" do
    rules = rules(%{op: "presence.required"})
    rules = put_in(rules, [:bindings, :check, :normalizer], %{id: :trim, version: 1})
    rules = put_in(rules, [:bindings, :check, :condition], %{op: "value.eq", value: "never"})

    rules = %{
      rules
      | normalizers: %{trim: %{version: 1, steps: [%{op: "text.trim", profile: "ascii_v1"}]}}
    }

    assert {:ok, contract} = Contract.compile_rules(rules)

    assert %{
             disposition: :error,
             values: %{subject: original},
             outcomes: [%{code: :evaluation_limit}]
           } =
             Evaluator.evaluate(contract, :candidate, %{subject: String.duplicate(" ", 17000)})

    assert byte_size(original) == 17000

    assert {:error, %{code: :evaluation_limit}} =
             Evaluator.normalize([%{"op" => "text.trim"}], String.duplicate(" ", 17000))
  end

  test "bounded ASCII trim includes vertical tab and form feed without trimming Unicode spaces" do
    assert {:ok, "AB12"} =
             Evaluator.normalize([%{"op" => "text.trim"}], " \t\r\n\v\fAB12\f\v\n\r\t ")

    assert {:ok, "\u00a0AB12\u00a0"} =
             Evaluator.normalize([%{"op" => "text.trim"}], "\u00a0AB12\u00a0")
  end

  test "advisory resource exhaustion cannot become success behind a condition or logical branch" do
    expensive = %{op: "all", rules: List.duplicate(pattern("a*"), 100)}

    for {test, subject, condition} <- [
          {%{op: "presence.required"}, String.duplicate(" ", 17000),
           %{op: "value.eq", value: "never"}},
          {%{op: "any", rules: [%{op: "presence.required"}, expensive]},
           String.duplicate("a", 4096), nil},
          {%{op: "presence.required"}, String.duplicate("a", 4096), expensive}
        ] do
      authored = put_in(rules(test), [:bindings, :check, :enforcement], :advisory)

      authored =
        if condition,
          do: put_in(authored, [:bindings, :check, :condition], condition),
          else: authored

      assert {:ok, contract} = Contract.compile_rules(authored)

      assert %{
               disposition: :error,
               outcomes: [%{code: :evaluation_limit, enforcement: "advisory"}]
             } = Evaluator.evaluate(contract, :candidate, %{subject: subject})
    end
  end

  test "advisory normalizers share the invocation budget and retain ordinary advisory behavior" do
    authored = rules(%{op: "value.eq", value: "never"})

    binding =
      authored.bindings.check
      |> Map.put(:enforcement, :advisory)
      |> Map.put(:normalizer, %{id: :trim, version: 1})
      |> Map.put(:condition, %{op: "value.eq", value: "never"})

    authored = %{
      authored
      | bindings: %{a: binding, b: binding},
        normalizers: %{
          trim: %{
            version: 1,
            steps: List.duplicate(%{op: "text.trim", profile: "ascii_v1"}, 300)
          }
        }
    }

    assert {:ok, contract} = Contract.compile_rules(authored)

    assert %{disposition: :error, outcomes: [_, %{code: :evaluation_limit}]} =
             Evaluator.evaluate(contract, :candidate, %{subject: String.duplicate("a", 4000)})

    ordinary =
      put_in(authored, [:normalizers, :trim, :steps], [%{op: "text.trim", profile: "ascii_v1"}])

    ordinary = put_in(ordinary, [:bindings, :a, :condition], %{op: "presence.required"})
    assert {:ok, contract} = Contract.compile_rules(ordinary)

    assert %{disposition: :passed, values: %{subject: "allowed"}, outcomes: outcomes} =
             Evaluator.evaluate(contract, :candidate, %{subject: " allowed "})

    assert [%{disposition: :failed, enforcement: "advisory"}, %{disposition: :not_applicable}] =
             outcomes
  end

  test "original pattern bytes cannot be hidden by a prior normalizer or false condition" do
    authored = rules(pattern("a"))

    authored =
      put_in(authored, [:normalizers, :trim], %{
        version: 1,
        steps: [%{op: "text.trim", profile: "ascii_v1"}]
      })

    authored = put_in(authored, [:bindings, :check, :normalizer], %{id: :trim, version: 1})

    authored =
      put_in(authored, [:bindings, :check, :condition], %{op: "value.eq", value: "never"})

    assert {:ok, contract} = Contract.compile_rules(authored)

    assert %{disposition: :error, outcomes: [%{code: :evaluation_limit}]} =
             Evaluator.evaluate(contract, :candidate, %{
               subject: String.duplicate(" ", 5000) <> "a"
             })

    authored =
      put_in(authored, [:definitions, :presence], %{version: 1, test: %{op: "presence.required"}})

    authored =
      put_in(authored, [:bindings, :a_first], %{
        subject: %{scope: :candidate, path: [:subject]},
        rule: %{id: :presence, version: 1},
        normalizer: %{id: :trim, version: 1}
      })

    assert {:ok, contract} = Contract.compile_rules(authored)

    assert %{disposition: :error, values: %{subject: "a"}, outcomes: outcomes} =
             Evaluator.evaluate(contract, :candidate, %{
               subject: String.duplicate(" ", 5000) <> "a"
             })

    assert List.last(outcomes).code == :evaluation_limit

    # Non-pattern scalar rules preserve the existing declared document limit.
    assert :passed = check(%{op: "text.length", exact: 16_384}, String.duplicate("x", 16_384))

    assert {:error, %{code: :evaluation_limit}} =
             check(pattern("x*"), String.duplicate("x", 4097))
  end

  test "collection size, nesting, and exact numeric expansion are bounded before work" do
    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "collection.count", exact: 1001}, Enum.to_list(1..1001))

    nested = Enum.reduce(1..33, 0, fn _, child -> [child] end)
    assert {:error, %{code: :evaluation_limit}} = check(%{op: "presence.required"}, nested)

    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "number.integer"}, Decimal.new("1e1000000"))

    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "number.integer"}, Integer.pow(10, 5000))

    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "number.integer"}, String.duplicate("9", 5000))
  end

  test "oversized compiled sets and bindings refuse before unbounded enumeration" do
    assert {:ok, compiled} =
             Contract.compile_test(%{op: "membership.in", values: Enum.to_list(1..1001)})

    assert {:error, %{code: :evaluation_limit}} = Evaluator.evaluate_test(compiled, 1)
    authored = rules(%{op: "presence.required"})
    bindings = Map.new(1..1001, &{"binding#{&1}", authored.bindings.check})
    assert {:ok, contract} = Contract.compile_rules(%{authored | bindings: bindings})

    assert %{disposition: :error, outcomes: [%{code: :evaluation_limit}]} =
             Evaluator.evaluate(contract, :candidate, %{subject: "a"})
  end

  test "remainder work is charged before arbitrary-precision division" do
    digits = String.duplicate("9", 2048)

    assert {:error, %{code: :evaluation_limit}} =
             check(%{op: "number.multiple_of", factor: digits}, digits)

    assert :passed =
             check(
               %{op: "number.multiple_of", factor: "0.01"},
               "123456789012345678901234567890.12"
             )
  end

  test "collection sums preserve exact digits beyond the ambient Decimal context" do
    big = "123456789012345678901234567890"
    original_context = Decimal.Context.get()

    Decimal.Context.with(%Decimal.Context{precision: 5}, fn ->
      assert :passed =
               check(%{op: "collection.sum", path: [:n], exact: big <> ".1"}, [
                 %{n: big},
                 %{n: "0.1"}
               ])

      assert Decimal.Context.get().precision == 5
    end)

    assert Decimal.Context.get() == original_context

    assert {:failed, %{code: :invalid_type}} = check(%{op: "number.integer"}, "1e2")
    assert {:failed, %{code: :invalid_type}} = check(%{op: "number.integer"}, 1.0)
  end

  defp pattern(source, mode \\ "full"),
    do: %{op: "text.pattern", profile: "ascii_v1", pattern: source, match: mode, flags: []}

  defp check(authored, subject) do
    assert {:ok, compiled} = Contract.compile_test(authored)
    Evaluator.evaluate_test(compiled, subject)
  end

  defp rules(test) do
    %{
      schema: "selecto.data_rules.v1",
      definitions: %{check: %{version: 1, test: test}},
      normalizers: %{},
      bindings: %{
        check: %{subject: %{scope: :candidate, path: [:subject]}, rule: %{id: :check, version: 1}}
      }
    }
  end
end
