defmodule SelectoUpdato.ActionTemplateTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.ActionTemplate

  test "validates the current action template expression surface without inputs" do
    template = %{
      note: {:input, :note, [:trim, :blank_to_nil]},
      tags: ["literal", ["input", "tag", ["downcase"]]]
    }

    assert :ok = ActionTemplate.validate(template, [:execution, :set])
  end

  test "resolves nested input placeholders and transforms" do
    template = %{
      note: {:input, :note, [:trim, :blank_to_nil]},
      nested: [%{tag: ["input", "tag", ["trim", "downcase"]]}]
    }

    assert {:ok, resolved} =
             ActionTemplate.resolve(
               template,
               %{"note" => "  Bring waiver  ", "tag" => "  URGENT  "},
               [:execution, :set]
             )

    assert resolved == %{note: "Bring waiver", nested: [%{tag: "urgent"}]}
  end

  test "resolves trusted context placeholders from host-provided context" do
    template = %{
      tenant_id: {:context, :tenant_id},
      actor_email: ["context", "actor_email", ["trim", "downcase"]]
    }

    assert {:ok, resolved} =
             ActionTemplate.resolve(
               template,
               %{},
               [tenant_id: 42, actor_email: "  LEAD@EXAMPLE.COM  "],
               [:execution, :set]
             )

    assert resolved == %{tenant_id: 42, actor_email: "lead@example.com"}
  end

  test "applies arithmetic transform pipelines" do
    template = %{
      score: {:input, :score, [{:add, 5}, {:multiply, 2}, {:subtract, "4"}]},
      ratio: ["context", "base_ratio", [["divide", 2]]]
    }

    assert {:ok, resolved} =
             ActionTemplate.resolve(
               template,
               %{"score" => "10"},
               %{base_ratio: 9},
               [:execution, :set]
             )

    assert resolved == %{score: 26, ratio: 4.5}
  end

  test "applies date transform pipelines to ISO strings and date structs" do
    template = %{
      due_on: {:input, :due_on, [{:date_add, 7, :day}]},
      reminder_at: ["context", "now", [["date_subtract", 2, "hour"]]],
      warranty_until: {:context, :start_on, [{:date_add, 2, :week}]}
    }

    now = ~U[2026-05-08 10:30:00Z]

    assert {:ok, resolved} =
             ActionTemplate.resolve(
               template,
               %{"due_on" => "2026-05-08"},
               %{now: now, start_on: ~D[2026-05-08]},
               [:execution, :set]
             )

    assert resolved.due_on == "2026-05-15"
    assert resolved.reminder_at == ~U[2026-05-08 08:30:00Z]
    assert resolved.warranty_until == ~D[2026-05-22]
  end

  test "resolves fallback expressions from first non-nil candidate" do
    template = %{
      note:
        {:fallback,
         [
           {:input, :missing_note},
           {:input, :note, [:trim, :blank_to_nil]},
           "No note"
         ]}
    }

    assert {:ok, %{note: "No note"}} =
             ActionTemplate.resolve(template, %{"note" => "   "}, [:execution, :set])
  end

  test "fallback expressions preserve false and zero values" do
    assert {:ok, %{received: false, count: 0}} =
             ActionTemplate.resolve(
               %{
                 received: ["fallback", [["input", "received"], true]],
                 count: {:fallback, [{:context, :missing_count}, {:input, :count}, 100]}
               },
               %{"received" => false, "count" => 0},
               %{},
               [:execution, :set]
             )
  end

  test "rejects unsupported transforms during static validation" do
    assert {:error, error} =
             ActionTemplate.validate(
               %{note: {:input, :note, [:rot13]}},
               [:execution, :set]
             )

    assert error.code == :unsupported_action_input_transform
    assert error.path == [:execution, :set, "note"]
    assert error.transform == "rot13"
    assert "rot13" not in error.allowed
    assert "trim" in error.allowed
    assert "add" in error.allowed
    assert "date_add" in error.allowed
  end

  test "rejects arithmetic transforms on non-numeric values" do
    assert {:error, error} =
             ActionTemplate.resolve(%{score: {:input, :score, [{:add, 1}]}}, %{
               score: "ten"
             })

    assert error.code == :invalid_action_input_transform_value
    assert error.path == ["score"]
    assert error.transform == "add"
    assert error.value == "ten"
  end

  test "rejects invalid date transform arguments" do
    assert {:error, error} =
             ActionTemplate.validate(%{due_on: {:input, :due_on, [{:date_add, "soon", :day}]}}, [
               :execution,
               :set
             ])

    assert error.code == :invalid_action_input_transform
    assert error.path == [:execution, :set, "due_on"]
    assert error.transform == "date_add"
    assert error.amount == "soon"
  end

  test "rejects date transforms on non-date values" do
    assert {:error, error} =
             ActionTemplate.resolve(
               %{due_on: {:input, :due_on, [{:date_add, 1, :day}]}},
               %{due_on: "eventually"},
               [:execution, :set]
             )

    assert error.code == :invalid_action_input_transform_value
    assert error.path == [:execution, :set, "due_on"]
    assert error.transform == "date_add"
    assert error.value == "eventually"
  end

  test "rejects malformed reserved input placeholders" do
    assert {:error, error} =
             ActionTemplate.validate(%{note: ["input"]}, [:execution, :set])

    assert error.code == :invalid_action_template
    assert error.path == [:execution, :set, "note"]
  end

  test "rejects malformed reserved context placeholders" do
    assert {:error, error} =
             ActionTemplate.validate(%{tenant_id: ["context"]}, [:execution, :set])

    assert error.code == :invalid_action_template
    assert error.path == [:execution, :set, "tenant_id"]
  end

  test "rejects malformed fallback expressions" do
    assert {:error, error} =
             ActionTemplate.validate(%{note: ["fallback", {:input, :note}]}, [
               :execution,
               :set
             ])

    assert error.code == :invalid_action_template
    assert error.path == [:execution, :set, "note"]
  end

  test "rejects missing trusted context references outside fallback expressions" do
    assert {:error, error} =
             ActionTemplate.resolve(%{tenant_id: {:context, :tenant_id}}, %{}, %{}, [
               :execution,
               :set
             ])

    assert error.code == :missing_action_context_reference
    assert error.path == [:execution, :set, "tenant_id"]
    assert error.context == "tenant_id"
  end

  test "rejects string transforms on non-string values during resolution" do
    assert {:error, error} =
             ActionTemplate.resolve(
               %{note: {:input, :note, [:trim]}},
               %{note: 123},
               [:execution, :set]
             )

    assert error.code == :invalid_action_input_transform_value
    assert error.path == [:execution, :set, "note"]
    assert error.transform == "trim"
    assert error.value == 123
  end
end
