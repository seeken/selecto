defmodule SelectoUpdato.DirectWrite do
  @moduledoc """
  Bounded JSON command bridge to domain-governed Updato operations.

  Commands name the logical `root` relation. The supplied domain determines
  the physical source and grants. This bridge never dispatches raw commands.
  Trusted tenant context and captured queries are supplied through host options,
  not inferred from submitted command data.
  """
  alias SelectoUpdato.{Error, PortableCommand}
  alias Selecto.Domain.Contract.Shared.Core

  @keys ~w(operation relation assignments predicate returning conflict_target upsert_update_fields)

  # Only vocabulary already defined by the contract becomes atoms. Registry
  # identifiers and submitted values remain data, including unfamiliar names.
  @native_keys ~w(schema_version name source source_table primary_key tenant_field fields columns associations schemas joins writes operations insert update delete upsert enabled bulk expected_cardinality returning conflict_targets insertable updatable immutable server_managed write_once required required_on type nullable internal scope tenant field satisfied_by relationships writable allowed_ops parent_key child_key domain ownership cardinality identity_fields strategy delete_missing)a
  @native_types ~w(integer bigint decimal numeric float string text uuid boolean date naive_datetime utc_datetime)a

  def import_domain(domain) when is_map(domain) and not is_struct(domain) do
    with true <- valid_keys?(domain),
         domain = native_domain(domain),
         {:ok, _} <- Selecto.Domain.WriteContract.compile(domain) do
      {:ok, domain}
    else
      {:error, error} -> {:error, Error.new(error.type, error.message, details: error.details)}
      _ -> invalid()
    end
  end

  def import_domain(_), do: invalid()

  @doc "Executes a creation-only nested graph after adapter-owned relationship inference."
  def execute_graph(domain, %Selecto{} = target, values, opts \\ []) do
    with true <- is_map(domain) and not is_struct(domain),
         true <- valid_keys?(domain) and valid_keys?(values),
         true <- is_list(opts) and Keyword.keyword?(opts),
         true <- is_nil(Keyword.get(opts, :query)),
         domain = native_domain(domain),
         {:ok, domain} <- infer_query_tenant(domain, opts),
         {:ok, _count} <- payload_bound(values, 0, 0),
         :ok <- graph_values(domain, values, 0),
         :ok <- graph_adapter(target) do
      prepare = fn loader ->
        with {:ok, %{domain: inferred, edges: edges}} when is_list(edges) and edges != [] <-
               loader.({:write_graph_domain, domain}),
             {:ok, values} <- graph_representation(inferred, values),
             operation =
               inferred
               |> SelectoUpdato.new(Keyword.take(opts, [:tenant]))
               |> SelectoUpdato.insert(values),
             # The target's engine tenant bounds the graph like any other
             # write (lesson 47).
             {:ok, compile_opts} <-
               SelectoUpdato.Executor.engine_tenant_opts(operation, target,
                 action_phase: :execute,
                 storage_backend: Selecto.AdapterSupport.adapter_name(target.adapter),
                 candidate_state_provider: loader,
                 record_state_provider: loader,
                 rule_candidate_provider: loader,
                 native_rule_candidate?: true
               ),
             operation = SelectoUpdato.Tenant.apply_execution_scope(operation, compile_opts),
             {:ok, %Selecto.Write.Graph{} = graph, context} <-
               PortableCommand.compile(operation, compile_opts) do
          graph = %{graph | metadata: Map.put(graph.metadata, :catalog_inferred_edges, edges)}
          SelectoUpdato.GovernedWrite.prepared(graph, context)
        else
          {:error, %Error{} = error} ->
            {:error, Selecto.Write.Error.new(error.type, error.message, details: error.details)}

          {:error, _} = error ->
            error

          _ ->
            {:error,
             Selecto.Write.Error.new(
               :invalid_write,
               "Creation graph requires a declared nested payload"
             )}
        end
      end

      Selecto.Write.execute_prepared(target, prepare, [])
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  defp graph_adapter(target) do
    if function_exported?(target.adapter, :execute_prepared_write, 3) and
         function_exported?(target.adapter, :write_capabilities, 1) and
         Map.get(
           target.adapter.write_capabilities(target.connection),
           :graph_domain_inference,
           false
         ) and
         Map.get(
           target.adapter.write_capabilities(target.connection),
           :native_rule_candidates,
           false
         ),
       do: :ok,
       else:
         {:error,
          Error.new(:write_capability_missing, "Protected graph inference is unavailable")}
  end

  def execute(domain, target, command, opts \\ []) do
    with {:ok, operation} <- build(domain, command, opts) do
      SelectoUpdato.execute(operation, target)
    end
  end

  def execute_batch(domain, target, commands, opts \\ [])

  def execute_batch(domain, target, commands, opts)
      when is_list(commands) and length(commands) in 1..64 do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {command, index}, {:ok, operations} ->
      case build(domain, command, opts) do
        {:ok, operation} -> {:cont, {:ok, operations ++ [{index, operation}]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, operations} -> SelectoUpdato.run(%SelectoUpdato.Multi{operations: operations}, target)
      error -> error
    end
  end

  def execute_batch(_domain, _target, _commands, _opts), do: invalid()

  def build(domain, command, opts \\ []) do
    with true <- is_map(command) and Enum.all?(Map.keys(command), &(&1 in @keys)),
         true <- valid_keys?(command),
         true <- is_list(opts) and Keyword.keyword?(opts),
         true <- query_option?(Keyword.get(opts, :query)),
         :ok <- root(command),
         {:ok, type} <- operation(command["operation"]),
         :ok <- query_operation(type, opts),
         true <- is_map(command["assignments"]) and not is_struct(command["assignments"]),
         :ok <- command_shape(type, command),
         {:ok, filter} <- predicate(command["predicate"]),
         {:ok, operation} <- builder(domain, type, command, filter, opts),
         {:ok, compiled, _context} <- PortableCommand.compile(operation),
         :ok <- update_fields(type, command["upsert_update_fields"], compiled) do
      {:ok, operation}
    else
      {:error, %Error{type: :unknown_field} = error} ->
        {:error, %{error | details: Map.put(error.details, :code, :unknown_field)}}

      {:error, _} = error ->
        error

      _ ->
        invalid()
    end
  end

  defp root(%{"relation" => "root"}), do: :ok

  defp root(_),
    do: {:error, Error.new(:write_relation_mismatch, "Direct writes require the domain root")}

  defp operation("insert"), do: {:ok, :insert}
  defp operation("update"), do: {:ok, :update}
  defp operation("delete"), do: {:ok, :delete}
  defp operation("upsert"), do: {:ok, :upsert}
  defp operation(_), do: invalid()

  defp command_shape(type, command) do
    cond do
      not field_list?(Map.get(command, "returning", [])) ->
        invalid()

      not is_nil(command["conflict_target"]) and not field_list?(command["conflict_target"]) ->
        invalid()

      not is_nil(command["upsert_update_fields"]) and
          not field_list?(command["upsert_update_fields"]) ->
        invalid()

      type == :delete and command["assignments"] != %{} ->
        invalid()

      type in [:insert, :upsert] and command["predicate"] != nil ->
        invalid()

      type != :upsert and command["conflict_target"] not in [nil, []] ->
        invalid()

      true ->
        :ok
    end
  end

  defp field_list?(fields) when is_list(fields),
    do: Enum.all?(fields, &(is_atom(&1) or is_binary(&1)))

  defp field_list?(_), do: false

  defp query_option?(nil), do: true

  defp query_option?(%Selecto{domain: domain, config: config, set: set}),
    do:
      is_map(domain) and not is_struct(domain) and is_map(config) and not is_struct(config) and
        is_map(set) and not is_struct(set)

  defp query_option?(_), do: false

  defp predicate(nil), do: {:ok, nil}

  defp predicate(%{"field" => field, "op" => "eq", "value" => value} = map)
       when map_size(map) == 3 and is_binary(field), do: {:ok, {field, value}}

  defp predicate(_), do: invalid()

  defp builder(domain, type, command, filter, opts) do
    with {:ok, domain} <- import_domain(domain) do
      build_operation(domain, type, command, filter, opts)
    end
  end

  defp build_operation(domain, type, command, filter, opts) do
    with {:ok, domain} <- infer_query_tenant(domain, opts) do
      bounded_operation(domain, type, command, filter, opts)
    end
  end

  defp bounded_operation(domain, type, command, filter, opts) do
    base = SelectoUpdato.new(domain, Keyword.take(opts, [:tenant]))
    base = if filter, do: SelectoUpdato.filter(base, filter), else: base

    base =
      case Keyword.get(opts, :query) do
        %Selecto{} = query -> SelectoUpdato.enforce_query(base, query)
        nil -> base
      end

    base =
      case type do
        :insert ->
          SelectoUpdato.insert(base, command["assignments"])

        :update ->
          SelectoUpdato.update(base, command["assignments"])

        :delete ->
          SelectoUpdato.delete(base)

        :upsert ->
          base = SelectoUpdato.upsert(base, command["assignments"])

          case command["conflict_target"] do
            fields when is_list(fields) and fields != [] ->
              SelectoUpdato.conflict_target(base, fields)

            _ ->
              base
          end
      end

    returning = Map.get(command, "returning", [])

    if is_list(returning),
      do: {:ok, SelectoUpdato.returning(base, if(returning == [], do: :none, else: returning))},
      else: invalid()
  end

  defp query_operation(:upsert, opts) do
    if match?(%Selecto{}, Keyword.get(opts, :query)),
      do:
        {:error,
         Error.new(
           :query_enforcement,
           "Captured query predicates cannot govern both upsert branches",
           details: %{code: :query_enforcement_unsupported_operation}
         )},
      else: :ok
  end

  defp query_operation(_, _), do: :ok

  defp infer_query_tenant(domain, opts) do
    field = Core.map_value(domain.source, :tenant_field)

    if (match?(%Selecto{}, Keyword.get(opts, :query)) or not is_nil(Keyword.get(opts, :tenant))) and
         not is_nil(field) do
      writes = Core.map_value(domain, :writes)
      scope = Core.map_value(writes, :scope) || %{}
      tenant = Core.map_value(scope, :tenant) || %{}
      declared_field = Core.map_value(tenant, :field) || Core.map_value(tenant, :tenant_field)

      if is_map(writes) and is_map(scope) and is_map(tenant) and
           (is_atom(field) or is_binary(field)) and
           (is_nil(declared_field) or
              ((is_atom(declared_field) or is_binary(declared_field)) and
                 to_string(declared_field) == to_string(field))) do
        tenant =
          tenant
          |> Map.put(:required, true)
          |> Map.put(:field, field)
          |> Map.put(:satisfied_by, [:trusted_context])

        {:ok, put_in(domain, [:writes, :scope], Map.put(scope, :tenant, tenant))}
      else
        invalid()
      end
    else
      {:ok, domain}
    end
  end

  defp graph_values(domain, _values, _depth) when is_struct(domain), do: invalid()

  defp graph_values(_domain, _values, depth) when depth >= 32, do: invalid()

  defp graph_values(domain, values, depth)
       when is_map(values) and not is_struct(values) and map_size(values) <= 256 do
    relationships =
      domain |> Core.map_value(:writes) |> Core.map_value(:relationships) |> Kernel.||(%{})

    fields = domain |> Core.map_value(:source) |> Core.relation_fields()

    Enum.reduce_while(values, :ok, fn {field, value}, :ok ->
      spec =
        Enum.find_value(relationships, fn {name, spec} ->
          if to_string(name) == to_string(field), do: spec
        end)

      result =
        cond do
          is_map(spec) and is_list(value) and length(value) <= 64 ->
            Enum.reduce_while(value, :ok, fn child, :ok ->
              case graph_values(Core.map_value(spec, :domain), child, depth + 1) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end)

          is_map(spec) ->
            invalid()

          to_string(field) in fields ->
            :ok

          true ->
            {:error,
             Error.new(
               :write_relation_mismatch,
               "Graph payload exceeds declared root fields and relationships"
             )}
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp graph_values(_, _, _), do: invalid()

  defp graph_representation(domain, values) do
    relationships = Core.map_value(domain.writes, :relationships) || %{}

    Enum.reduce_while(values, {:ok, %{}}, fn {field, value}, {:ok, normalized} ->
      spec =
        Enum.find_value(relationships, fn {name, spec} ->
          if to_string(name) == to_string(field), do: spec
        end)

      result =
        if is_map(spec) do
          Enum.reduce_while(value, {:ok, []}, fn child, {:ok, children} ->
            case graph_representation(Core.map_value(spec, :domain), child) do
              {:ok, child} -> {:cont, {:ok, children ++ [child]}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, []} when spec.cardinality == :one -> {:ok, nil}
            {:ok, [child]} when spec.cardinality == :one -> {:ok, child}
            {:ok, _children} when spec.cardinality == :one -> invalid()
            result -> result
          end
        else
          {:ok, value}
        end

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(normalized, field, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp payload_bound(_value, depth, count) when depth >= 32 or count >= 256, do: invalid()

  defp payload_bound(value, depth, count) when is_map(value) or is_list(value) do
    children = if is_map(value), do: Map.values(value), else: value

    Enum.reduce_while(children, {:ok, count + 1}, fn child, {:ok, count} ->
      case payload_bound(child, depth + 1, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        error -> {:halt, error}
      end
    end)
  end

  defp payload_bound(_value, _depth, count), do: {:ok, count + 1}

  defp native_map(%_{} = value), do: value

  defp native_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      native_key = Enum.find(@native_keys, key, &(to_string(&1) == to_string(key)))

      value =
        cond do
          native_key == :type and is_binary(value) ->
            Enum.find(@native_types, value, &(to_string(&1) == value))

          native_key in [:fields, :columns, :schemas, :relationships, :operations] and
              is_map(value) ->
            Map.new(value, fn {id, spec} -> {id, native_map(spec)} end)

          true ->
            native_map(value)
        end

      {native_key, value}
    end)
  end

  defp native_map(list) when is_list(list), do: Enum.map(list, &native_map/1)
  defp native_map(value), do: value

  defp valid_keys?(%_{}), do: true

  defp valid_keys?(map) when is_map(map) do
    keys = Map.keys(map)

    Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) and
      length(Enum.uniq(Enum.map(keys, &to_string/1))) == length(keys) and
      Enum.all?(Map.values(map), &valid_keys?/1)
  end

  defp valid_keys?(list) when is_list(list), do: Enum.all?(list, &valid_keys?/1)
  defp valid_keys?(_), do: true

  defp native_domain(domain) do
    domain = native_map(SelectoUpdato.DomainInput.canonical_domain(domain))
    domain = Map.put_new(domain, :schemas, %{})
    domain = Map.put_new(domain, :joins, %{})

    update_in(domain, [:source], fn source ->
      if is_map(source), do: Map.put_new(source, :associations, %{}), else: %{}
    end)
  end

  defp update_fields(:upsert, requested, command) when is_list(requested) do
    allowed = Map.get(command.metadata, :upsert_update_fields, []) |> Enum.map(&to_string/1)

    cond do
      Enum.any?(requested, &(&1 not in allowed)) ->
        {:error,
         Error.new(:write_field_not_writable, "Upsert update fields exceed domain grants")}

      requested == allowed ->
        :ok

      true ->
        invalid()
    end
  end

  defp update_fields(:upsert, nil, _command), do: :ok
  defp update_fields(_type, fields, _command) when fields in [nil, []], do: :ok
  defp update_fields(_, _, _), do: invalid()

  defp invalid,
    do:
      {:error,
       Error.new(:invalid_write, "Invalid bounded direct write command",
         details: %{code: :invalid_write}
       )}
end
