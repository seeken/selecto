defmodule SelectoUpdato.NativeActionGrantTest do
  use ExUnit.Case, async: false
  alias SelectoUpdato.{ActionAuthorization, ActionExecutionAdapter, CapabilityDecision, Error}
  alias SelectoUpdato.NativeActionGrantFixture, as: Fixture

  defmodule NativeAdapter do
    def execute_action(plan, context, _opts),
      do:
        SelectoUpdato.execute(plan.operation_builder, context.execution_target, context: context)

    def dry_run_action(plan, context, _opts),
      do:
        SelectoUpdato.preview(plan.operation_builder, context.execution_target, context: context)
  end

  setup_all do
    uri = URI.parse(System.fetch_env!("SELECTO_ACTION_GRANT_DATABASE_URL"))

    unless uri.host in ["localhost", "127.0.0.1"] and uri.port != 5432 and
             String.starts_with?(uri.path || "", "/selecto_adv_"),
           do: raise("Disposable task database required")

    opts = [
      hostname: uri.host,
      port: uri.port,
      username: uri.userinfo,
      database: String.trim_leading(uri.path, "/")
    ]

    connection = start_supervised!({Postgrex, opts})
    Fixture.create(connection)

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(opts)
      Fixture.cleanup(cleanup)
      GenServer.stop(cleanup)
    end)

    %{connection: connection}
  end

  setup context do
    Process.put(:action_grant_observations, [])
    Process.put(:action_grant_test, context.test)
    {:ok, Map.put(context, :variants, Fixture.variants())}
  end

  test "a distinct valid preview grant returns the real adapter preview and never writes",
       context do
    for {variant, rows} <- context.variants do
      reset(context, rows)
      source = Fixture.source(context.connection)
      {operation, authorized_context} = grant(source, 1, grant_phase: :preview)
      result = SelectoUpdato.preview(operation, source, context: authorized_context)
      after_state = Fixture.state(context.connection)
      record(variant, "preview_control", result, rows, after_state)
      assert {:ok, %Selecto.Write.Preview{statements: [_]}} = result
      assert after_state == rows

      assert_refusal(
        context,
        variant,
        "preview_replay",
        operation,
        authorized_context,
        rows,
        :unregistered_action_authorization,
        :preview
      )

      {:ok, plan} = plan(source, [1])

      result =
        ActionExecutionAdapter.dry_run(NativeAdapter, plan, host_context(source),
          capability_resolver: &resolver/3
        )

      record(variant, "public_adapter_preview", result, rows, Fixture.state(context.connection))
      assert {:ok, %Selecto.Write.Preview{statements: [_]}} = result
      assert Fixture.state(context.connection) == rows
    end

    finish("preview")
  end

  test "AC-01 consumed grants reject a second actual native write", context do
    for {variant, rows} <- context.variants do
      reset(context, rows)
      source = Fixture.source(context.connection)
      {operation, authorized_context} = grant(source, 1)
      assert_effect(context, variant, "first_execute", operation, authorized_context, rows, [1])
      after_first = Fixture.effect(rows, [1])

      assert_refusal(
        context,
        variant,
        "consumed_replay",
        operation,
        authorized_context,
        after_first,
        :unregistered_action_authorization
      )

      {new_operation, new_context} = grant(source, 2)

      assert_effect(context, variant, "fresh_control", new_operation, new_context, after_first, [
        2
      ])
    end

    finish("replay")
  end

  test "AC-02 payload, target, returning, domain, query and admission option mutations burn grants",
       context do
    for {variant, rows} <- context.variants,
        {id, mutate} <- mutations() do
      reset(context, rows)
      source = Fixture.source(context.connection)
      {operation, authorized_context} = grant(source, 1)

      assert_refusal(
        context,
        variant,
        id,
        mutate.(operation),
        authorized_context,
        rows,
        :action_authorization_mismatch
      )

      assert_refusal(
        context,
        variant,
        id <> "_retry",
        operation,
        authorized_context,
        rows,
        :unregistered_action_authorization
      )
    end

    finish("operation_mutations")
  end

  test "AC-02 and AC-03 early phase and authorization-evidence rejection also burn grants",
       context do
    for {variant, rows} <- context.variants,
        {id, modify, method, code} <- [
          {"phase", & &1, :preview, :action_authorization_phase_mismatch},
          {"action", &put_in(&1, [:action_authorization, :action], "other"), :execute,
           :action_authorization_mismatch},
          {"capability", &put_in(&1, [:action_authorization, :capability], "other"), :execute,
           :action_authorization_mismatch},
          {"actor", &Map.put(&1, :actor, %{id: 77}), :execute, :action_authorization_mismatch},
          {"tenant", &Map.put(&1, :tenant_id, 8), :execute, :action_authorization_mismatch}
        ] do
      reset(context, rows)
      {operation, authorized_context} = grant(Fixture.source(context.connection), 1)

      assert_refusal(
        context,
        variant,
        id,
        operation,
        modify.(authorized_context),
        rows,
        code,
        method
      )

      assert_refusal(
        context,
        variant,
        id <> "_retry",
        operation,
        authorized_context,
        rows,
        :unregistered_action_authorization
      )
    end

    finish("early_rejections")
  end

  test "AC-04 actual expired grants reject writes and fresh grants still execute", context do
    for {variant, rows} <- context.variants do
      reset(context, rows)
      source = Fixture.source(context.connection)
      {operation, authorized_context} = grant(source, 1, action_authorization_grant_ttl: 20)
      Process.sleep(80)

      assert_refusal(
        context,
        variant,
        "expired",
        operation,
        authorized_context,
        rows,
        :unregistered_action_authorization
      )

      {new_operation, new_context} = grant(source, 1)

      assert_effect(
        context,
        variant,
        "after_expiry_fresh_control",
        new_operation,
        new_context,
        rows,
        [1]
      )
    end

    finish("expiry")
  end

  test "TW-10 explicit-capability row and mixed bulk actions retain atomic tenant and host scope",
       context do
    for {variant, rows} <- context.variants,
        ids <- [[3], [4], [8], [1, 3], [1, 8], [1], [1, 2]] do
      reset(context, rows)
      source = Fixture.source(context.connection)
      {:ok, plan} = plan(source, ids)
      host_context = host_context(source)
      before = Fixture.state(context.connection)
      assert before == rows

      result =
        ActionExecutionAdapter.execute(NativeAdapter, plan, host_context,
          capability_resolver: &resolver/3
        )

      after_state = Fixture.state(context.connection)
      record(variant, "target_" <> Enum.join(ids, "_"), result, before, after_state)

      if ids in [[1], [1, 2]] do
        assert {:ok, %{affected_rows: count}} = result
        assert count == length(ids)
        assert after_state == Fixture.effect(rows, ids)
      else
        assert {:error, %Error{type: :cardinality_mismatch}} = result
        assert after_state == before
      end
    end

    finish("scoped_actions")
  end

  test "changed row eligibility is rechecked atomically and changed current scope requires a new plan",
       context do
    for {variant, rows} <- context.variants do
      reset(context, rows)
      original = Fixture.source(context.connection)
      {operation, authorized_context} = grant(original, 1)

      Postgrex.query!(
        context.connection,
        "UPDATE selecto_cert_action_grant_people SET owner_id=77 WHERE id=1",
        []
      )

      changed_rows =
        Enum.map(rows, fn row -> if hd(row) == 1, do: List.replace_at(row, 3, 77), else: row end)

      assert_refusal(
        context,
        variant,
        "row_owner_changed",
        operation,
        authorized_context,
        changed_rows,
        :cardinality_mismatch
      )

      assert_refusal(
        context,
        variant,
        "row_owner_changed_retry",
        operation,
        authorized_context,
        changed_rows,
        :unregistered_action_authorization
      )

      reset(context, rows)
      changed_source = Fixture.source(context.connection, 77)
      {new_operation, new_context} = grant(changed_source, 1)

      assert_refusal(
        context,
        variant,
        "fresh_changed_scope",
        new_operation,
        new_context,
        rows,
        :cardinality_mismatch
      )

      {eligible_operation, eligible_context} = grant(changed_source, 3)

      assert_effect(
        context,
        variant,
        "changed_owner_positive",
        eligible_operation,
        eligible_context,
        rows,
        [3]
      )

      reset(context, rows)

      stricter_amount_source = Fixture.source(context.connection, 42, 18)
      {amount_operation, amount_context} = grant(stricter_amount_source, 2)

      assert_refusal(
        context,
        variant,
        "fresh_changed_amount",
        amount_operation,
        amount_context,
        rows,
        :cardinality_mismatch
      )

      {amount_positive, amount_positive_context} = grant(stricter_amount_source, 1)

      assert_effect(
        context,
        variant,
        "changed_amount_positive",
        amount_positive,
        amount_positive_context,
        rows,
        [1]
      )

      reset(context, rows)

      # The execution target supplies the adapter and connection. The sealed
      # operation retains its original guard; this is a trusted SDK contract,
      # not an assertion that a transport may silently replace host policy.
      {old_operation, old_context} = grant(original, 1)
      swapped_context = Map.put(old_context, :execution_target, changed_source)

      assert_effect(
        context,
        variant,
        "old_scope_snapshot",
        old_operation,
        swapped_context,
        rows,
        [1]
      )

      reset(context, rows)
      {:ok, plan} = plan(original, [1])
      disabled_context = Map.put(host_context(original), :permission, :disabled)

      result =
        ActionExecutionAdapter.execute(NativeAdapter, plan, disabled_context,
          capability_resolver: &resolver/3
        )

      record(variant, "fresh_changed_permission", result, rows, Fixture.state(context.connection))
      assert {:error, {:validation_error, _, %{code: :permission_changed}}} = result
      assert Fixture.state(context.connection) == rows
    end

    finish("changed_scope")
  end

  defp mutations do
    [
      {"payload", &%{&1 | changes: %{name: "tampered"}}},
      {"target", &%{&1 | filters: [{"id", 8}]}},
      {"returning", &%{&1 | returning: [:id, :name]}},
      {"domain", &%{&1 | domain: Map.put(&1.domain, :domain_fingerprint, "other-domain")}},
      {"query",
       &%{&1 | query_enforcement: Map.put(&1.query_enforcement, :filters, [{"owner_id", 77}])}},
      {"opts", &%{&1 | opts: Keyword.put(&1.opts || [], :choice_source_context, %{role: :other})}}
    ]
  end

  defp host_context(source),
    do: %{actor: %{id: 42}, tenant_id: 7, permission: :enabled, execution_target: source}

  defp plan(source, [id]),
    do: SelectoUpdato.plan_domain_action(source, %{action: :rename, target: %{id: id}})

  defp plan(source, ids),
    do: SelectoUpdato.plan_domain_action(source, %{action: :rename, target: %{ids: ids}})

  defp grant(source, id, opts \\ []) do
    {:ok, plan} = plan(source, [id])
    context = host_context(source)
    phase = Keyword.get(opts, :grant_phase, :execute)

    {:ok, authorized, decision, grant} =
      ActionAuthorization.authorize_and_issue(
        plan,
        phase,
        context,
        Keyword.put(opts, :capability_resolver, &resolver/3)
      )

    context =
      context
      |> Map.put(:capability_decision, CapabilityDecision.to_map(decision))
      |> Map.put(:action_authorization, %{
        action: plan.action,
        capability: plan.capability,
        phase: phase,
        status: :enabled,
        authorization_grant: grant
      })

    {authorized.operation_builder, context}
  end

  defp resolver(%{capability: "people.rename"}, %{permission: :enabled}, _opts), do: :enabled

  defp resolver(_request, _context, _opts),
    do: %{status: :disabled, reason: "Permission changed", code: :permission_changed}

  defp assert_refusal(
         context,
         variant,
         id,
         operation,
         authorized_context,
         expected_state,
         code,
         method \\ :execute
       ) do
    before = Fixture.state(context.connection)
    assert before == expected_state

    result =
      apply(SelectoUpdato, method, [
        operation,
        authorized_context.execution_target,
        [context: authorized_context]
      ])

    after_state = Fixture.state(context.connection)
    record(variant, id, result, before, after_state)
    assert {:error, %Error{} = error} = result
    assert (error.details[:code] || error.type) == code
    assert after_state == expected_state
  end

  defp assert_effect(context, variant, id, operation, authorized_context, rows, ids) do
    before = Fixture.state(context.connection)
    assert before == rows

    result =
      SelectoUpdato.execute(operation, authorized_context.execution_target,
        context: authorized_context
      )

    after_state = Fixture.state(context.connection)
    record(variant, id, result, before, after_state)
    assert {:ok, %{affected_rows: count}} = result
    assert count == length(ids)
    assert after_state == Fixture.effect(rows, ids)
  end

  defp record(variant, id, result, before, after_state) do
    row = %{
      variant: variant,
      probe: id,
      native_result: native_result(result),
      before_rows: before,
      after_rows: after_state
    }

    Process.put(:action_grant_observations, [row | Process.get(:action_grant_observations, [])])
    persist("latest")
  end

  defp native_result({:ok, %Selecto.Write.Preview{} = preview}),
    do: Map.put(Map.from_struct(preview), :outcome, "previewed")

  defp native_result({:ok, result}),
    do: Map.put(Map.from_struct(result), :outcome, "applied")

  defp native_result({:error, %Error{} = error}),
    do: %{
      outcome: "refused",
      type: error.type,
      code: error.details[:code] || error.type,
      raw_native_error: inspect(error, limit: :infinity, printable_limit: :infinity)
    }

  defp native_result({:error, {:validation_error, _message, details}}),
    do: %{outcome: "refused", type: "validation_error", code: details.code}

  defp reset(context, rows) do
    Fixture.reset(context.connection, rows)
    assert Fixture.state(context.connection) == rows
    by_id = Map.new(rows, &{hd(&1), &1})
    assert Enum.at(by_id[3], 1) == 7 and Enum.at(by_id[3], 3) == 77 and Enum.at(by_id[3], 4) < 25
    assert Enum.at(by_id[4], 1) == 7 and Enum.at(by_id[4], 3) == 42 and Enum.at(by_id[4], 4) > 25
    assert Enum.at(by_id[8], 1) == 8 and Enum.at(by_id[8], 3) == 42 and Enum.at(by_id[8], 4) < 25
  end

  defp finish(name) do
    Process.get(:action_grant_observations, [])
    |> Enum.group_by(& &1.probe)
    |> Enum.each(fn {_probe, observations} ->
      assert length(observations) == 3
      public = Enum.map(observations, &Map.drop(&1.native_result, [:raw_native_error]))
      assert length(Enum.uniq(public)) == 1
    end)

    persist(name)
  end

  defp persist(name) do
    if path = System.get_env("SELECTO_ACTION_GRANT_EVIDENCE_PREFIX") do
      test_name = to_string(Process.get(:action_grant_test))

      test_id =
        :crypto.hash(:sha256, test_name) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      bytes =
        Jason.encode!(
          %{
            test: test_name,
            observations: Enum.reverse(Process.get(:action_grant_observations, []))
          },
          pretty: true
        )

      File.write!(path <> "." <> name <> ".json", bytes)
      File.write!(path <> ".test-" <> test_id <> ".json", bytes)
    end
  end
end
