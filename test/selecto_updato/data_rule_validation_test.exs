defmodule SelectoUpdato.DataRuleValidationTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.Command
  alias SelectoUpdato.{Operation, PortableCommand}

  defmodule RecordingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :data_rule_recording
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        atomic_batch: true,
        write_graph: true,
        committed_effect_sink: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Command{} = command, _opts) do
      send(self(), {:data_rule_write, command})
      {:ok, %Selecto.Write.Result{operation: command.operation, affected_rows: 1}}
    end
  end

  defmodule PreparedRecordAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :prepared_record_rule_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        update: true,
        upsert: true,
        prepared_candidate_state: true,
        protected_upsert_candidates: true,
        transactions: true,
        committed_effect_sink: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}
    def execute_write(_connection, _command, _opts), do: raise("prepared path must be used")

    def execute_prepared_write(pid, prepare, _opts) do
      # A conforming adapter spends the governed preparation's authorization.
      prepare = Selecto.Write.Authorization.governed_preparation(prepare)

      loader = fn
        %Selecto.Write.RecordRequest{} = request ->
          send(pid, {:record_state_request, request})

          {:ok,
           %Selecto.Write.RecordState{
             values: %{"id" => 1, "start" => "5", "finish" => "5"},
             complete?: true,
             protection: :locked
           }}

        %Selecto.Write.UpsertCandidateRequest{} = request ->
          send(pid, {:upsert_candidate_request, request})
          prior = %{"id" => 1, "start" => "5", "finish" => "5"}
          updated = MapSet.new(request.command.metadata.upsert_update_fields)

          changes =
            Map.new(
              Enum.filter(request.command.assignments, &MapSet.member?(updated, &1.field)),
              fn %{field: field, value: {:literal, value}} -> {field, value} end
            )

          {:ok,
           %Selecto.Write.UpsertCandidateState{
             values: Map.merge(prior, changes),
             prior_values: prior,
             branch: :conflict,
             effect: :update,
             complete?: true,
             protection: :locked,
             receipt: make_ref()
           }}
      end

      with {:ok, %Command{} = command, _context} <- prepare.(loader) do
        send(pid, {:prepared_record_command, command})
        {:ok, %Selecto.Write.Result{operation: command.operation, affected_rows: 1}}
      end
    end
  end

  defmodule UnavailableSQLiteAdapter do
    def name, do: :sqlite
    def write_capabilities(_connection), do: %{native_rule_candidates: false}
    def execute_write(_, _, _), do: raise("required native rule candidate must not dispatch")
  end

  test "SQLite without native storage projection refuses required rules before preview or execution" do
    operation =
      candidate_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{quantity: 2, reference: "AB12"})

    selecto = %Selecto{adapter: UnavailableSQLiteAdapter, connection: :unavailable}

    assert {:error, %{details: %{code: :native_rule_candidates_unsupported}}} =
             SelectoUpdato.execute(operation, selecto)

    assert {:error, %{details: %{code: :native_rule_candidates_unsupported}}} =
             SelectoUpdato.preview(operation, selecto)
  end

  test "canonical candidate rules reject invalid writes and persist normalized values" do
    %Operation{} =
      invalid =
      candidate_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{quantity: "0", reference: " ab12 "})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{code: :data_rule_failed, outcomes: outcomes}
            }} = PortableCommand.compile(invalid)

    assert Enum.any?(outcomes, &(&1.rule_id == "positive_quantity" and &1.disposition == :failed))

    valid = %Operation{invalid | attrs: %{quantity: "2", reference: " ab12 "}}

    assert {:ok, %Command{} = command, _context} = PortableCommand.compile(valid)
    assert %{field: "reference", value: {:literal, "AB12"}} in command.assignments
  end

  test "JSON-shaped source columns retain scalar rules and normalizers" do
    domain = candidate_domain() |> Jason.encode!() |> Jason.decode!()

    invalid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{"quantity" => "0", "reference" => " ab12 "})

    assert {:error, %{details: %{code: :data_rule_failed}}} = PortableCommand.compile(invalid)

    valid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{"quantity" => "2", "reference" => " ab12 "})

    assert {:ok, %Command{} = command, _context} = PortableCommand.compile(valid)
    assert %{field: "reference", value: {:literal, "AB12"}} in command.assignments
  end

  test "invalid canonical writes never dispatch and valid normalized controls do" do
    selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}

    %Operation{} =
      invalid =
      candidate_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{quantity: 0, reference: " ab12 "})

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed}}} =
             SelectoUpdato.execute(invalid, selecto)

    refute_receive {:data_rule_write, _}

    valid = %Operation{invalid | attrs: %{quantity: 2, reference: " ab12 "}}
    assert {:ok, %Selecto.Write.Result{affected_rows: 1}} = SelectoUpdato.execute(valid, selecto)
    assert_receive {:data_rule_write, %Command{} = command}
    assert %{field: "reference", value: {:literal, "AB12"}} in command.assignments
  end

  test "legacy field validators use the canonical evaluator and fail closed" do
    domain =
      update_in(candidate_domain(), [:writes, :fields, :quantity], fn spec ->
        Map.put(spec, :validators, [{:number, greater_than: 0}])
      end)
      |> Map.delete(:rules)

    operation =
      domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: 0, reference: "ok"})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{code: :data_rule_failed, path: ["quantity"]}
            }} = PortableCommand.compile(operation)
  end

  test "required transaction rules cannot be silently skipped by a raw command" do
    domain =
      candidate_domain()
      |> put_in([:rules, :bindings], %{
        transaction_reference: %{
          subject: %{scope: :transaction, path: [:reference]},
          rule: %{id: :reference_shape, version: 1}
        }
      })

    operation =
      domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: 2, reference: "ABCD"})

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{code: :required_data_rule_pending, obligations: [_]}
            }} = PortableCommand.compile(operation)
  end

  test "required native constraint declarations become typed command obligations" do
    operation =
      candidate_domain()
      |> put_in([:rules, :bindings, :positive_quantity, :native_constraint], %{
        adapter: "postgresql",
        constraint: "line_items_quantity_positive",
        category: "check_violation"
      })
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{quantity: 2, reference: "AB12"})

    assert {:ok, %Command{native_constraints: [native]}, _context} =
             PortableCommand.compile(operation)

    assert native == %{
             binding_id: "positive_quantity",
             adapter: "postgresql",
             constraint: "line_items_quantity_positive",
             category: :check_violation
           }
  end

  test "action input rules enforce exactly three selections" do
    domain = action_domain()

    assert {:error, %{code: :data_rule_failed}} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :choose_products,
               target: %{id: 1},
               inputs: %{selected_products: [1, 2]}
             })

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :choose_products,
               target: %{id: 1},
               inputs: %{selected_products: [1, 2, 3]}
             })

    assert plan.inputs["selected_products"] == [1, 2, 3]
  end

  test "related-field candidate rules reject an invalid inserted range before dispatch" do
    %Operation{} =
      invalid =
      related_field_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{start: "5", finish: "5"})

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed, outcomes: outcomes}}} =
             PortableCommand.compile(invalid)

    assert Enum.any?(outcomes, &(&1.code == :related_value_comparison and &1.path == ["finish"]))

    valid = %Operation{invalid | attrs: %{start: "5", finish: "6"}}
    assert {:ok, %Command{}, _context} = PortableCommand.compile(valid)
  end

  test "temporal candidate rules reject an invalid inserted range before dispatch" do
    domain =
      related_field_domain()
      |> put_in([:rules, :definitions, :finish_after_start, :test], %{
        op: "temporal.compare_path",
        kind: "date",
        comparison: "gt",
        path: [:start]
      })

    %Operation{} =
      invalid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{start: "2026-09-06", finish: "2026-09-06"})

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed}}} =
             PortableCommand.compile(invalid)

    valid = %Operation{invalid | attrs: %{start: "2026-09-06", finish: "2026-09-07"}}
    assert {:ok, %Command{}, _context} = PortableCommand.compile(valid)
  end

  test "structured object candidate rules reject invalid values before dispatch" do
    domain =
      candidate_domain()
      |> update_in([:source, :fields], &(&1 ++ [:vehicle]))
      |> put_in([:source, :columns, :vehicle], %{type: :map})
      |> put_in([:writes, :fields, :vehicle], %{insertable: true})
      |> put_in([:rules, :definitions, :vehicle_shape], %{
        version: 1,
        test: %{
          op: "object.shape",
          required: [:vin, :year],
          properties: %{
            vin: %{
              op: "text.pattern",
              profile: "ascii_v1",
              pattern: "[A-Z0-9]{17}",
              match: "full"
            },
            year: %{op: "number.range", min: 1886, max: 9999}
          },
          additional: false
        }
      })
      |> put_in([:rules, :bindings, :vehicle_shape], %{
        subject: %{scope: :candidate, path: [:vehicle]},
        rule: %{id: :vehicle_shape, version: 1}
      })

    %Operation{} =
      invalid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{
        quantity: 2,
        reference: "AB12",
        vehicle: %{vin: "1HGCM82633A004352"}
      })

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed, outcomes: outcomes}}} =
             PortableCommand.compile(invalid)

    assert Enum.any?(outcomes, &(&1.code == :missing_object_key and &1.path == ["vehicle"]))

    %Operation{} =
      valid =
      %Operation{
        invalid
        | attrs: %{invalid.attrs | vehicle: %{vin: "1HGCM82633A004352", year: 2026}}
      }

    assert {:ok, %Command{}, _context} = PortableCommand.compile(valid)
  end

  test "conditional candidate rules use a related input path before dispatch" do
    domain =
      candidate_domain()
      |> update_in([:source, :fields], &(&1 ++ [:kind, :discount_code]))
      |> put_in([:source, :columns, :kind], %{type: :string})
      |> put_in([:source, :columns, :discount_code], %{type: :string})
      |> put_in([:writes, :fields, :kind], %{insertable: true})
      |> put_in([:writes, :fields, :discount_code], %{insertable: true})
      |> put_in([:rules, :definitions, :discount_code], %{
        version: 1,
        test: %{op: "presence.required"}
      })
      |> put_in([:rules, :bindings, :discount_code], %{
        subject: %{scope: :candidate, path: [:discount_code]},
        rule: %{id: :discount_code, version: 1},
        condition: %{op: "path.test", path: [:kind], test: %{op: "value.eq", value: "coupon"}}
      })

    %Operation{} =
      invalid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{quantity: 2, reference: "AB12", kind: "coupon"})

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed, outcomes: outcomes}}} =
             PortableCommand.compile(invalid)

    assert Enum.any?(outcomes, &(&1.code == :required and &1.path == ["discount_code"]))

    standard = %Operation{invalid | attrs: %{quantity: 2, reference: "AB12", kind: "standard"}}
    assert {:ok, %Command{}, _context} = PortableCommand.compile(standard)
  end

  test "partial updates evaluate candidate rules against protected record state" do
    domain =
      related_field_domain()
      |> put_in([:writes, :operations], %{update: %{enabled: true, require_filter: true}})
      |> put_in([:writes, :fields], %{start: %{updatable: true}, finish: %{updatable: true}})

    %Operation{} =
      valid =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{finish: "6"})

    provider = fn %Selecto.Write.RecordRequest{} = request ->
      assert request.operation == :update
      assert request.fields == ["finish", "id", "start"]

      {:ok,
       %Selecto.Write.RecordState{
         values: %{"id" => 1, "start" => "5", "finish" => "5"},
         complete?: true,
         protection: :locked
       }}
    end

    assert {:ok, %Command{}, _context} =
             PortableCommand.compile(valid, record_state_provider: provider)

    invalid = %Operation{valid | changes: %{finish: "4"}}

    assert {:error, %SelectoUpdato.Error{details: %{code: :data_rule_failed, outcomes: outcomes}}} =
             PortableCommand.compile(invalid, record_state_provider: provider)

    assert Enum.any?(outcomes, &(&1.code == :related_value_comparison and &1.path == ["finish"]))

    selecto = %Selecto{adapter: PreparedRecordAdapter, connection: self()}

    assert {:ok, %Selecto.Write.Result{operation: :update}} =
             SelectoUpdato.execute(valid, selecto)

    assert_receive {:record_state_request, %Selecto.Write.RecordRequest{operation: :update}}
    assert_receive {:prepared_record_command, %Command{operation: :update}}
  end

  test "upserts with required final-state rules use a command-aware protected branch request" do
    domain =
      related_field_domain()
      |> put_in([:writes, :operations], %{
        upsert: %{enabled: true, conflict_targets: [[:id]], update_fields: [:start, :finish]}
      })
      |> put_in([:writes, :fields], %{
        id: %{insertable: true},
        start: %{insertable: true, updatable: true},
        finish: %{insertable: true, updatable: true}
      })

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.upsert(%{id: 1, start: "5", finish: "6"})

    assert {:error, %{details: %{code: :upsert_rule_strategy_unsupported}}} =
             PortableCommand.compile(operation)

    selecto = %Selecto{adapter: PreparedRecordAdapter, connection: self()}

    assert {:ok, %Selecto.Write.Result{operation: :upsert}} =
             SelectoUpdato.execute(operation, selecto)

    assert_receive {:upsert_candidate_request,
                    %Selecto.Write.UpsertCandidateRequest{
                      command: %Command{
                        operation: :upsert,
                        metadata: %{conflict_target: [:id], upsert_update_fields: update_fields}
                      },
                      prior: nil,
                      subject: subject
                    }}

    assert is_reference(subject)
    assert Enum.sort(update_fields) == ["finish", "start"]

    assert_receive {:upsert_candidate_request,
                    %Selecto.Write.UpsertCandidateRequest{subject: ^subject, prior: receipt}}

    assert is_reference(receipt)
    refute_receive {:record_state_request, _}

    assert_receive {:prepared_record_command, %Command{operation: :upsert}}

    unsupported_selecto = %Selecto{adapter: RecordingAdapter, connection: :recording}

    assert {:error,
            %SelectoUpdato.Error{
              type: :unsupported_operation,
              details: %{code: :upsert_rule_strategy_unsupported}
            }} = SelectoUpdato.execute(operation, unsupported_selecto)

    refute_receive {:data_rule_write, _}
  end

  test "selected-row bulk updates with required final-state rules reject before a record load" do
    domain =
      related_field_domain()
      |> put_in([:writes, :operations], %{update: %{enabled: true, bulk: true}})
      |> put_in([:writes, :fields], %{finish: %{updatable: true}})

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, :in, [1, 2]})
      |> SelectoUpdato.update(%{finish: "6"})
      |> SelectoUpdato.expected_cardinality({:exactly, 2})

    assert {:error,
            %SelectoUpdato.Error{
              type: :unsupported_operation,
              details: %{code: :bulk_rule_strategy_unsupported, bindings: bindings}
            }} = PortableCommand.compile(operation)

    assert [%{binding_id: "finish_after_start", stage: "candidate"}] = bindings
  end

  test "deletes with required final-state rules reject until a post-delete strategy exists" do
    operation =
      related_field_domain()
      |> put_in([:writes, :operations], %{delete: %{enabled: true}})
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.delete()

    assert {:error,
            %SelectoUpdato.Error{
              type: :unsupported_operation,
              details: %{code: :delete_rule_strategy_unsupported, bindings: bindings}
            }} = PortableCommand.compile(operation)

    assert [%{binding_id: "finish_after_start", stage: "candidate"}] = bindings
  end

  test "inline action rules reject explicit null and non-text values" do
    domain =
      put_in(action_domain(), [:actions, :choose_products, :inputs, :note], %{
        type: :string,
        required: true,
        nonblank: true,
        rules: [%{op: "type.is", type: "text"}]
      })

    for note <- [nil, 42, "   "] do
      assert {:error, %{code: code}} =
               SelectoUpdato.plan_domain_action(domain, %{
                 action: :choose_products,
                 target: %{id: 1},
                 inputs: %{selected_products: [1, 2, 3], note: note}
               })

      assert code in [:invalid_action_input_value, :invalid_action_input_type]
    end
  end

  test "unsupported legacy action validators fail closed" do
    domain =
      put_in(action_domain(), [:actions, :choose_products, :inputs, :note], %{
        type: :string,
        validators: [{:host_callback, :unsafe}]
      })

    assert {:error, %{code: :unsupported_action_input_rule}} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :choose_products,
               target: %{id: 1},
               inputs: %{selected_products: [1, 2, 3], note: "hello"}
             })
  end

  defp candidate_domain do
    %{
      source: %{
        source_table: "line_items",
        primary_key: :id,
        fields: [:id, :quantity, :reference],
        columns: %{
          id: %{type: :integer},
          quantity: %{type: :integer},
          reference: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{
          quantity: %{insertable: true},
          reference: %{insertable: true}
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          positive_quantity: %{version: 1, test: %{op: "number.gt", bound: "0"}},
          reference_shape: %{
            version: 1,
            test: %{
              op: "text.pattern",
              profile: "ascii_v1",
              pattern: "[A-Z0-9]{4,12}",
              match: "full"
            }
          }
        },
        normalizers: %{
          reference: %{
            version: 1,
            steps: [
              %{op: "text.trim", profile: "ascii_whitespace_v1"},
              %{op: "text.uppercase", profile: "ascii_v1"}
            ]
          }
        },
        bindings: %{
          positive_quantity: %{
            subject: %{scope: :input, path: [:quantity]},
            rule: %{id: :positive_quantity, version: 1}
          },
          reference_shape: %{
            subject: %{scope: :candidate, path: [:reference]},
            rule: %{id: :reference_shape, version: 1},
            normalizer: %{id: :reference, version: 1}
          }
        }
      }
    }
  end

  defp action_domain do
    %{
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :selected_products],
        columns: %{id: %{type: :integer}, selected_products: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{update: %{enabled: true, require_filter: true}},
        fields: %{selected_products: %{updatable: true}}
      },
      actions: %{
        choose_products: %{
          type: :detail_action,
          inputs: %{
            selected_products: %{type: :collection, required: true}
          },
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{selected_products: {:input, :selected_products}}
          }
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          exactly_three: %{version: 1, test: %{op: "collection.count", exact: 3}}
        },
        normalizers: %{},
        bindings: %{
          three_products: %{
            subject: %{
              scope: :action_input,
              action: :choose_products,
              path: [:selected_products]
            },
            rule: %{id: :exactly_three, version: 1}
          }
        }
      }
    }
  end

  defp related_field_domain do
    %{
      source: %{
        source_table: "ranges",
        primary_key: :id,
        fields: [:id, :start, :finish],
        columns: %{id: %{type: :integer}, start: %{type: :decimal}, finish: %{type: :decimal}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{start: %{insertable: true}, finish: %{insertable: true}}
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          finish_after_start: %{
            version: 1,
            test: %{op: "value.compare_path", comparison: "gt", path: [:start]}
          }
        },
        normalizers: %{},
        bindings: %{
          finish_after_start: %{
            subject: %{scope: :candidate, path: [:finish]},
            rule: %{id: :finish_after_start, version: 1}
          }
        }
      }
    }
  end
end
