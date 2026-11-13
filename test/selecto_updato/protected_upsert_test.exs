defmodule SelectoUpdato.ProtectedUpsertTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{UpsertCandidateRequest, UpsertCandidateState}
  alias SelectoUpdato.PortableCommand

  defmodule UnsupportedAdapter do
    def name, do: :sqlite

    def write_capabilities(_connection),
      do: %{protocol_version: 1, native_rule_candidates: true, upsert: true}

    def execute_prepared_write(_, _, _), do: raise("unsupported adapter must not prepare")
    def preview_prepared_write(_, _, _), do: raise("unsupported adapter must not preview")
  end

  test "conflict rules consume only actual update fields, retaining ignored insert attributes" do
    operation =
      operation(
        domain(:secret, %{op: "value.eq", value: "private"}),
        %{id: 1, name: "new", secret: "insert-only"}
      )

    assert {:ok, command, _} = compile(operation, loader(prior()))
    assert assignment(command, "secret") == "insert-only"
    assert command.metadata.upsert_update_fields == ["name"]
    assert is_reference(command.metadata.protected_upsert_receipt)
    assert is_reference(command.metadata.protected_upsert_subject)
    assert :protected_upsert_candidates in command.required_capabilities
    assert_receive {:project, %UpsertCandidateRequest{prior: nil} = first}
    assert_receive {:project, %UpsertCandidateRequest{prior: receipt} = second}
    assert is_reference(receipt)
    assert first.subject === second.subject
    assert first.command.metadata.upsert_update_fields == ["name"]
    refute Map.has_key?(second.command.metadata, :protected_upsert_receipt)
  end

  test "a failing stored field refuses before final projection" do
    operation =
      operation(
        domain(:secret, %{op: "value.eq", value: "private"}),
        %{id: 1, name: "new", secret: "private"}
      )

    assert {:error, %{details: %{code: :data_rule_failed}}} =
             compile(operation, loader(%{prior() | "secret" => "wrong"}))

    assert_receive {:project, %UpsertCandidateRequest{prior: nil}}
    refute_receive {:project, %UpsertCandidateRequest{}}
  end

  test "insert branch uses adapter-proved omitted defaults" do
    operation =
      operation(domain(:secret, %{op: "value.eq", value: "generated"}), %{id: 2, name: "new"})

    provider = loader(%{}, :insert, %{"secret" => "generated"})
    assert {:ok, command, _} = compile(operation, provider)
    refute Enum.any?(command.assignments, &(&1.field == "secret"))
    assert assignment(command, "id") == 2
  end

  test "DO NOTHING validates the unchanged conflict row and retains an empty update mask" do
    authored =
      domain(:name, %{op: "value.eq", value: "before"})
      |> put_in([:writes, :fields, :name, :updatable], false)

    operation = operation(authored, %{id: 1, name: "ignored"})
    assert {:ok, command, _} = compile(operation, loader(prior()))
    assert command.metadata.upsert_update_fields == []
    assert assignment(command, "name") == "ignored"
  end

  test "candidate normalization is realized in the actual conflict assignment and reprojected" do
    authored = domain(:name, %{op: "value.eq", value: "new"}) |> normalizer(:name)

    assert {:ok, command, _} =
             compile(operation(authored, %{id: 1, name: " new "}), loader(prior()))

    assert assignment(command, "name") == "new"
    assert_receive {:project, %UpsertCandidateRequest{prior: nil} = first}
    assert assignment(first.command, "name") == " new "
    assert_receive {:project, %UpsertCandidateRequest{prior: receipt} = final}
    assert is_reference(receipt)
    assert assignment(final.command, "name") == "new"
  end

  test "a normalized unassigned field is added only through its actual grants" do
    authored = domain(:extra, %{op: "value.eq", value: "extra"}) |> normalizer(:extra)
    before = Map.put(prior(), "extra", " extra ")
    assert {:ok, command, _} = compile(operation(authored, %{id: 1, name: "new"}), loader(before))
    assert assignment(command, "extra") == "extra"
    assert Enum.sort(command.metadata.upsert_update_fields) == ["extra", "name"]

    forbidden = put_in(authored, [:writes, :fields, :extra, :insertable], false)

    assert {:error, %{type: :write_field_not_writable}} =
             compile(operation(forbidden, %{id: 1, name: "new"}), loader(before))
  end

  test "normalizers cannot silently rewrite ignored insert-only fields" do
    authored = domain(:secret, %{op: "value.eq", value: "private"}) |> normalizer(:secret)

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             compile(
               operation(authored, %{id: 1, name: "new", secret: "insert-only"}),
               loader(%{prior() | "secret" => " private "})
             )

    assert_receive {:project, %UpsertCandidateRequest{prior: nil}}
    refute_receive {:project, %UpsertCandidateRequest{}}
  end

  test "candidate normalizers cannot rewrite a trusted context foreign-key fill" do
    authored = domain(:extra, %{op: "value.eq", value: "extra"}) |> normalizer(:extra)

    authored =
      put_in(authored, [:writes, :constraints], %{
        foreign_keys: %{
          extra: %{
            source: {:context, :parent_key},
            required: true,
            references: %{relation: "parents", field: :key}
          }
        }
      })

    opts = [
      protected_upsert_candidates?: true,
      upsert_candidate_provider: loader(prior()),
      context: %{parent_key: " extra "}
    ]

    assert {:error, %{type: :foreign_key_source_mismatch}} =
             PortableCommand.compile(operation(authored, %{id: 1, name: "new"}), opts)

    assert_receive {:project, %UpsertCandidateRequest{prior: nil} = first}
    assert assignment(first.command, "extra") == " extra "
    refute_receive {:project, %UpsertCandidateRequest{}}

    assert {:ok, command, _} =
             PortableCommand.compile(
               operation(authored, %{id: 1, name: "new"}),
               Keyword.put(opts, :context, %{parent_key: "extra"})
             )

    assert assignment(command, "extra") == "extra"
  end

  test "changed branch, prior row, or unstable storage projection cannot authorize" do
    authored = domain(:name, %{op: "value.eq", value: "new"})

    for mutation <- [
          fn state -> %{state | branch: :insert, effect: :insert, prior_values: %{}} end,
          fn state ->
            %{state | prior_values: Map.put(state.prior_values, "secret", "changed")}
          end,
          fn state -> %{state | values: Map.put(state.values, "name", "changed")} end,
          fn state -> %{state | values: Map.put(state.values, "id", 1.0)} end
        ] do
      provider = fn request ->
        {:ok, state} = loader(prior()).(request)
        {:ok, if(request.prior, do: mutation.(state), else: state)}
      end

      assert {:error, %{details: %{code: :required_data_rule_pending}}} =
               compile(operation(authored, %{id: 1, name: "new"}), provider)
    end
  end

  test "malformed or incomplete adapter state is not a protected branch proof" do
    for mutation <- [
          fn state -> %{state | complete?: false} end,
          fn state -> %{state | protection: :unprotected} end,
          fn state -> %{state | receipt: nil} end,
          fn state -> %{state | format_version: 2} end,
          fn state -> %{state | effect: :insert} end,
          fn state -> %{state | values: Map.delete(state.values, "name")} end,
          fn state -> %{state | values: Map.put(state.values, "ghost", "x")} end,
          fn state -> %{state | values: Map.put(state.values, :name, "collision")} end,
          fn state -> %{state | prior_values: %{{} => "invalid"}} end
        ] do
      provider = fn request ->
        {:ok, state} = loader(prior()).(request)
        {:ok, mutation.(state)}
      end

      assert {:error, %{details: %{code: :required_data_rule_pending}}} =
               compile(operation(domain(:name), %{id: 1, name: "new"}), provider)
    end
  end

  test "subjects are private to each compilation and generic record loaders are never used" do
    caller_subject = make_ref()

    for _ <- 1..2 do
      assert {:ok, command, _} =
               PortableCommand.compile(operation(domain(:name), %{id: 1, name: "new"}),
                 protected_upsert_candidates?: true,
                 upsert_candidate_provider: loader(prior()),
                 protected_upsert_subject: caller_subject,
                 record_state_provider: fn _ -> flunk("generic record request") end,
                 rule_candidate_provider: fn _ -> flunk("generic storage projection") end
               )

      refute command.metadata.protected_upsert_subject === caller_subject
      send(self(), {:subject, command.metadata.protected_upsert_subject})
    end

    assert_receive {:subject, first}
    assert_receive {:subject, second}
    refute first === second
  end

  test "an explicit protected capability and loader are both required" do
    operation = operation(domain(:name), %{id: 1, name: "new"})

    for opts <- [
          [],
          [upsert_candidate_provider: loader(prior())],
          [protected_upsert_candidates?: true]
        ] do
      assert {:error, %{details: %{code: :upsert_rule_strategy_unsupported}}} =
               PortableCommand.compile(operation, opts)
    end
  end

  test "public execute and preview cannot replace missing native support with caller options" do
    operation = operation(domain(:name), %{id: 1, name: "new"})
    selecto = %Selecto{adapter: UnsupportedAdapter, connection: :unused}

    opts = [
      protected_upsert_candidates?: true,
      upsert_candidate_provider: fn _ -> flunk("caller provider must not run") end
    ]

    assert {:error, %{details: %{code: :upsert_rule_strategy_unsupported}}} =
             SelectoUpdato.execute(operation, selecto, opts)

    assert {:error, %{details: %{code: :upsert_rule_strategy_unsupported}}} =
             SelectoUpdato.preview(operation, selecto, opts)
  end

  test "original INPUT is checked before field normalization and not repeated after projection" do
    authored =
      domain(:name, %{op: "value.eq", value: "NEW"})
      |> put_in([:source, :columns, :name, :text_case], :uppercase)
      |> put_in([:rules, :definitions, :original], %{
        version: 1,
        test: %{op: "value.eq", value: "new"}
      })
      |> put_in([:rules, :bindings, :original], %{
        subject: %{scope: :input, path: [:name]},
        operations: [:upsert],
        rule: %{id: :original, version: 1}
      })

    assert {:ok, command, _} =
             compile(operation(authored, %{id: 1, name: "new"}), loader(prior()))

    assert assignment(command, "name") == "NEW"

    assert {:error, %{details: %{code: :data_rule_failed}}} =
             compile(operation(authored, %{id: 1, name: "NEW"}), loader(prior()))
  end

  test "ordinary upserts remain independent of protected branch capability" do
    authored = Map.delete(domain(:name), :rules)
    assert {:ok, command, _} = PortableCommand.compile(operation(authored, %{id: 1, name: "new"}))
    refute :protected_upsert_candidates in command.required_capabilities
    refute Map.has_key?(command.metadata, :protected_upsert_receipt)
  end

  test "ordinary updates and upserts ignore an optional prepared record loader" do
    authored =
      domain(:name)
      |> Map.delete(:rules)
      |> put_in([:writes, :operations, :update], %{enabled: true, require_filter: true})

    update =
      authored
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "new"})

    optional_loader = fn %Selecto.Write.RecordRequest{} ->
      flunk("ordinary operations must not request protected record state")
    end

    for operation <- [update, operation(authored, %{id: 1, name: "new"})] do
      assert {:ok, command, _} =
               PortableCommand.compile(operation,
                 record_state_provider: optional_loader,
                 require_protected_record_state: true
               )

      assert assignment(command, "name") == "new"
      refute Map.has_key?(command.metadata, :protected_upsert_receipt)
    end
  end

  test "protected callbacks retain actual record demand and upserts never use a generic proof" do
    authored =
      domain(:name, %{op: "value.eq", value: "new"})
      |> put_in([:writes, :operations, :update], %{enabled: true, require_filter: true})
      |> put_in([:rules, :bindings, :guard, :operations], [:update])

    update =
      authored
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{name: "new"})

    assert {:error, %{details: %{code: :record_state_unavailable}}} =
             PortableCommand.compile(update, require_protected_record_state: true)

    assert {:error, %{details: %{code: :record_state_unavailable}}} =
             PortableCommand.compile(update,
               require_protected_record_state: true,
               record_state_provider: fn %Selecto.Write.RecordRequest{} ->
                 {:ok, %Selecto.Write.RecordState{values: prior(), complete?: false}}
               end
             )

    # Standalone inspection retains its existing submitted-only semantics.
    assert {:ok, _command, _} = PortableCommand.compile(update)

    upsert = operation(domain(:name), %{id: 1, name: "new"})

    assert {:error, %{details: %{code: :upsert_rule_strategy_unsupported}}} =
             PortableCommand.compile(upsert,
               require_protected_record_state: true,
               record_state_provider: fn _ -> flunk("upserts need their own branch proof") end
             )
  end

  test "remaining evidence obligations use proven state and still fail closed" do
    authored = put_in(domain(:name), [:rules, :bindings, :guard, :subject, :scope], :evidence)

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             compile(operation(authored, %{id: 1, name: "new"}), loader(prior()))
  end

  test "membership rejects a normalized disallowed value and accepts the final value exactly once" do
    authored =
      domain(:name, %{op: "value.eq", value: "new"})
      |> normalizer(:name)
      |> with_choice(:name)

    for {allowed, outcome} <- [{" new ", :invalid}, {"new", :valid}] do
      resolver = fn %Selecto.Domain.Choices.Request{} = request ->
        send(self(), {:membership, request})

        if request.value == allowed,
          do: Selecto.Domain.Choices.valid(:member),
          else: Selecto.Domain.Choices.invalid(:not_member)
      end

      result =
        authored
        |> choice_operation(%{id: 1, name: " new "}, resolver)
        |> compile(loader(prior()))

      if outcome == :valid do
        assert {:ok, command, _} = result
        assert assignment(command, "name") == "new"
      else
        assert {:error, %{type: :validation}} = result
      end

      assert_receive {:membership, %{field: :name, value: "new", record: %{name: "new"}}}
      refute_receive {:membership, _}
    end
  end

  test "conflict membership uses the stored dependent field and ignores insert-only choices" do
    authored =
      domain(:name, %{op: "value.eq", value: "new"})
      |> with_choice(:name)
      |> with_choice(:secret)

    resolver = fn %Selecto.Domain.Choices.Request{} = request ->
      send(self(), {:membership, request})

      if request.field == :name and request.value == "new" and request.record.secret == "private" and
           not Map.has_key?(request.record, "secret"),
         do: Selecto.Domain.Choices.valid(:stored_dependency),
         else: Selecto.Domain.Choices.invalid(:wrong_dependency)
    end

    operation =
      authored
      |> SelectoUpdato.new(
        choice_source_membership_resolver: resolver,
        choice_source_record: %{"secret" => "host-override", host_metadata: "kept"}
      )
      |> SelectoUpdato.upsert(%{id: 1, name: "new", secret: "insert-only"})

    assert {:ok, command, _} = compile(operation, loader(prior()))
    assert assignment(command, "secret") == "insert-only"
    assert command.metadata.upsert_update_fields == ["name"]
    assert_receive {:membership, %{record: %{secret: "private", host_metadata: "kept"}}}
    refute_receive {:membership, _}
  end

  test "a candidate-normalized additional choice field is validated before it can persist" do
    authored =
      domain(:extra, %{op: "value.eq", value: "extra"})
      |> normalizer(:extra)
      |> with_choice(:extra)

    resolver = fn %Selecto.Domain.Choices.Request{} = request ->
      send(self(), {:membership, request})
      Selecto.Domain.Choices.invalid(:introduced_not_member)
    end

    assert {:error, %{type: :validation}} =
             authored
             |> choice_operation(%{id: 1, name: "new"}, resolver)
             |> compile(loader(Map.put(prior(), "extra", " extra ")))

    assert_receive {:membership, %{field: :extra, value: "extra", record: %{extra: "extra"}}}
    refute_receive {:membership, _}
  end

  test "insert membership uses proved defaults and refuses an unproved dependent record" do
    authored = domain(:name, %{op: "value.eq", value: "new"}) |> with_choice(:name)

    resolver = fn %Selecto.Domain.Choices.Request{} = request ->
      send(self(), {:membership, request})

      if request.record.secret == "generated",
        do: Selecto.Domain.Choices.valid(:proved_default),
        else: Selecto.Domain.Choices.invalid(:wrong_default)
    end

    operation = choice_operation(authored, %{id: 2, name: "new"}, resolver)

    assert {:ok, _command, _} =
             compile(
               operation,
               loader(%{}, :insert, %{"secret" => "generated", "extra" => "extra"})
             )

    assert_receive {:membership, %{record: %{secret: "generated"}}}
    refute_receive {:membership, _}

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             compile(operation, loader(%{}, :insert))

    refute_receive {:membership, _}
  end

  test "DO NOTHING and failed candidate rules do not invoke the membership resolver" do
    authored =
      domain(:name, %{op: "value.eq", value: "before"})
      |> with_choice(:name)
      |> put_in([:writes, :fields, :name, :updatable], false)

    resolver = fn _ -> flunk("unchanged conflict has no persisted choice assignment") end
    operation = choice_operation(authored, %{id: 1, name: "ignored"}, resolver)

    # Other fields are unavailable but not consumed by an unchanged conflict.
    assert {:ok, command, _} = compile(operation, loader(%{"id" => 1, "name" => "before"}))
    assert command.metadata.upsert_update_fields == []
    assert_receive {:project, %UpsertCandidateRequest{prior: nil, dependencies: ["name"]}}

    invalid = domain(:name, %{op: "value.eq", value: "allowed"}) |> with_choice(:name)
    operation = choice_operation(invalid, %{id: 1, name: "wrong"}, resolver)
    assert {:error, %{details: %{code: :data_rule_failed}}} = compile(operation, loader(prior()))
  end

  test "ordinary choice assignments are checked after declared field normalization" do
    authored =
      domain(:name)
      |> Map.delete(:rules)
      |> with_choice(:name)
      |> put_in([:source, :columns, :name, :text_case], :uppercase)

    resolver = fn %Selecto.Domain.Choices.Request{} = request ->
      send(self(), {:membership, request})

      if request.value == "NEW",
        do: Selecto.Domain.Choices.valid(:normalized_member),
        else: Selecto.Domain.Choices.invalid(:not_member)
    end

    operation = choice_operation(authored, %{id: 1, name: "new"}, resolver)
    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert assignment(command, "name") == "NEW"
    assert_receive {:membership, %{field: :name, value: "NEW"}}
    refute_receive {:membership, _}
  end

  defp compile(operation, provider),
    do:
      PortableCommand.compile(operation,
        protected_upsert_candidates?: true,
        upsert_candidate_provider: provider
      )

  defp operation(domain, attrs), do: domain |> SelectoUpdato.new() |> SelectoUpdato.upsert(attrs)

  defp choice_operation(domain, attrs, resolver) do
    domain
    |> SelectoUpdato.new(choice_source_membership_resolver: resolver)
    |> SelectoUpdato.upsert(attrs)
  end

  defp with_choice(authored, field) do
    authored
    |> put_in([:source, :columns, field, :choice_source], :members)
    |> Map.put(:choice_sources, %{
      members: %{domain: :members, value_field: :id, label_field: :name}
    })
  end

  defp assignment(command, field) do
    %{value: {:literal, value}} = Enum.find(command.assignments, &(&1.field == field))
    value
  end

  defp prior, do: %{"id" => 1, "name" => "before", "secret" => "private", "extra" => "extra"}

  defp loader(prior, branch \\ :conflict, defaults \\ %{}) do
    fn %UpsertCandidateRequest{} = request ->
      send(self(), {:project, request})

      assignments =
        Map.new(
          request.command.assignments,
          fn %{field: field, value: {:literal, value}} -> {field, value} end
        )

      updates = Map.take(assignments, request.command.metadata.upsert_update_fields)

      values =
        if branch == :insert,
          do: Map.merge(defaults, assignments),
          else: Map.merge(prior, updates)

      effect =
        if branch == :insert,
          do: :insert,
          else: if(map_size(updates) == 0, do: :nothing, else: :update)

      {:ok,
       %UpsertCandidateState{
         values: values,
         prior_values: prior,
         branch: branch,
         effect: effect,
         complete?: true,
         protection: :locked,
         receipt: make_ref()
       }}
    end
  end

  defp normalizer(authored, _field) do
    authored
    |> put_in([:rules, :normalizers], %{
      trim: %{version: 1, steps: [%{op: "text.trim", profile: "ascii_whitespace_v1"}]}
    })
    |> put_in([:rules, :bindings, :guard, :normalizer], %{id: :trim, version: 1})
  end

  defp domain(field, test \\ %{op: "presence.non_null"}) do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :secret, :extra],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          secret: %{type: :string},
          extra: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{upsert: %{enabled: true, conflict_targets: [[:id]]}},
        fields: %{
          id: %{insertable: true},
          name: %{insertable: true, updatable: true},
          secret: %{insertable: true, updatable: true, immutable: true},
          extra: %{insertable: true, updatable: true}
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        normalizers: %{},
        definitions: %{guard: %{version: 1, test: test}},
        bindings: %{
          guard: %{
            subject: %{scope: :candidate, path: [field]},
            operations: [:upsert],
            rule: %{id: :guard, version: 1}
          }
        }
      }
    }
  end
end
