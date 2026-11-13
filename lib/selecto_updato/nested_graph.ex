defmodule SelectoUpdato.NestedGraph do
  @moduledoc """
  Compiles domain-governed nested input into a portable `Selecto.Write.Graph`.

  Relationship policy comes exclusively from `writes.relationships`. Nested
  keys that are not explicitly writable fail closed in the ordinary flat
  command compiler. This module never emits SQL or inspects an adapter.
  """

  alias Selecto.Domain.WriteContract
  alias Selecto.Write.{Command, Graph}
  alias Selecto.Write.Graph.{Binding, Node, Row}
  alias SelectoUpdato.{DomainInput, Error, Operation, PortableCommand, QueryEnforcement}

  @max_nesting_depth 32

  @type row_ref :: {String.t(), String.t(), atom() | String.t()}

  @spec nested?(Operation.t()) :: boolean()
  def nested?(%Operation{} = operation) do
    case detect_nested(operation) do
      {:ok, _contract, nested?} -> nested?
      :error -> false
    end
  end

  @doc false
  @spec detect_nested(Operation.t()) :: {:ok, WriteContract.t(), boolean()} | :error
  def detect_nested(%Operation{} = operation) do
    payload = payload(operation)

    with true <- is_map(payload),
         {:ok, contract} <- WriteContract.compile(operation.domain) do
      relationship_keys = contract.relationships |> Map.keys() |> MapSet.new(&to_string/1)

      {:ok, contract,
       Enum.any?(Map.keys(payload), &MapSet.member?(relationship_keys, to_string(&1)))}
    else
      _ -> :error
    end
  end

  @spec compile(Operation.t(), keyword()) :: {:ok, Graph.t(), map()} | {:error, Error.t()}
  def compile(%Operation{} = operation, opts \\ []) when is_list(opts) do
    with {:ok, domain} <- DomainInput.normalize_write_authoring(operation.domain),
         operation = %{operation | domain: domain},
         :ok <- SelectoUpdato.WriteContract.validate_writes_shape(domain),
         {:ok, contract} <- compile_contract(operation.domain),
         {:ok, flat_payload, nested_payload} <- split_payload(payload(operation), contract),
         :ok <- ensure_root_changes(operation, flat_payload),
         {:ok, root_operation} <- put_payload(operation, flat_payload),
         {:ok, root_command, context} <- PortableCommand.compile_flat(root_operation, opts),
         {:ok, root_key} <- primary_key(operation.domain),
         root_command = ensure_returning(root_command, [root_key]),
         root_row = %Row{id: "root", path: [], command: root_command},
         root_node = %Node{
           id: "root",
           path: [],
           relation: root_command.relation,
           strategy: :ordered,
           rows: [root_row],
           field_types: field_types(contract),
           metadata: %{operation: operation.type}
         },
         graph_opts =
           opts
           |> Keyword.put(:context, context)
           |> Keyword.put(:candidate_parent_command, root_command)
           |> Keyword.put(
             :graph_root_tenant,
             PortableCommand.graph_root_tenant(root_operation, context)
           ),
         {:ok, child_nodes} <-
           compile_relationships(
             operation.domain,
             contract,
             nested_payload,
             operation.type,
             {"root", "root", root_key},
             [],
             graph_opts,
             1
           ),
         child_nodes = propagate_bound_scope(root_node, child_nodes, operation, graph_opts),
         {:ok, graph} <-
           Graph.new([root_node | child_nodes], {"root", "root"},
             metadata: %{
               contract_fingerprint: contract.fingerprint,
               root_returning: operation.returning || :none,
               membership_parent_lock: membership_parent_lock(operation.type, root_key)
             }
           ) do
      {:ok, graph, context}
    else
      {:error, %Selecto.Write.Error{} = error} ->
        {:error, Error.new(error.type, error.message, details: error.details)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # A nested update or delete changes the membership of a collection that is
  # owned by the selected root row.  The portable graph makes that obligation
  # explicit so an adapter can acquire the same parent lock even when no
  # candidate rule happened to request prior child rows.  Inserts create their
  # parent inside this graph, so there is no existing membership to protect.
  defp membership_parent_lock(operation, root_key) when operation in [:update, :delete],
    do: %{parent_key: root_key}

  defp membership_parent_lock(_operation, _root_key), do: nil

  defp compile_relationships(
         domain,
         contract,
         nested_payload,
         parent_operation,
         parent_ref,
         parent_path,
         opts,
         depth
       ) do
    with :ok <- validate_nesting_depth(depth, parent_path) do
      nested_payload
      |> Enum.sort_by(fn {relationship, _value} -> to_string(relationship) end)
      |> Enum.reduce_while({:ok, []}, fn {relationship, value}, {:ok, nodes} ->
        spec = relationship_spec(contract.relationships, relationship)

        case compile_relationship(
               domain,
               contract,
               relationship,
               spec,
               value,
               parent_operation,
               parent_ref,
               parent_path,
               opts,
               depth
             ) do
          {:ok, relationship_nodes} -> {:cont, {:ok, nodes ++ relationship_nodes}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp compile_relationship(
         _parent_domain,
         parent_contract,
         relationship,
         spec,
         value,
         parent_operation,
         {parent_node, parent_row, parent_key},
         parent_path,
         opts,
         depth
       ) do
    path = parent_path ++ [normalize_path_segment(relationship)]

    with {:ok, cardinality} <- cardinality(spec, path),
         {:ok, representation, entries} <-
           relationship_entries(value, cardinality, spec, parent_operation, path),
         :ok <-
           validate_relationship_policy(
             spec,
             relationship,
             parent_operation,
             representation,
             path
           ),
         {:ok, child_domain} <- child_domain(spec, path),
         {:ok, child_contract} <- compile_contract(child_domain),
         {:ok, child_required} <-
           QueryEnforcement.compile(%Operation{domain: child_domain}, child_contract),
         {:ok, child_key} <- child_key(spec, path),
         {:ok, child_relation} <- relation([], child_contract, path),
         {:ok, identity_fields} <- identity_fields(spec, child_domain, parent_operation, path),
         {:ok, predicate_fields} <- predicate_fields(spec, identity_fields, path),
         {:ok, collection_scope} <-
           collection_scope_predicate(child_contract, child_domain, opts),
         collection_scope = combine_scope_predicates(collection_scope, child_required),
         collection_opts =
           opts
           |> Keyword.put(:collection_field_types, field_types(child_contract))
           |> Keyword.put(:collection_scope_predicate, collection_scope),
         {:ok, entries} <-
           SelectoUpdato.RuleValidation.validate_nested_collection(
             parent_operation,
             parent_contract,
             relationship,
             entries,
             representation,
             path,
             identity_fields,
             Map.keys(field_types(child_contract)),
             parent_key,
             child_relation,
             child_key,
             collection_opts
           ),
         {:ok, strategy} <- strategy(spec, parent_operation, representation, path),
         node_id = path_id(path),
         {:ok, rows_and_nested} <-
           compile_rows(
             entries,
             child_domain,
             child_contract,
             child_key,
             {parent_node, parent_row, parent_key},
             path,
             cardinality,
             identity_fields,
             predicate_fields,
             opts
           ),
         {rows, nested_by_row} = Enum.unzip(rows_and_nested),
         :ok <-
           final_collection_candidate(
             parent_operation,
             parent_contract,
             relationship,
             entries,
             rows,
             representation,
             path,
             identity_fields,
             child_contract,
             parent_key,
             child_relation,
             child_key,
             collection_opts
           ),
         delete_missing? =
           strategy == :sync and delete_missing?(spec, representation),
         :ok <- validate_child_operations(spec, rows, path),
         :ok <- validate_delete_missing_policy(spec, delete_missing?, path),
         {:ok, sync_predicate} <-
           sync_predicate(
             strategy,
             child_key,
             parent_ref(parent_node, parent_row, parent_key),
             collection_scope
           ),
         {:ok, relation} <- relation(rows, child_contract, path),
         node = %Node{
           id: node_id,
           path: path,
           relation: relation,
           strategy: strategy,
           rows: rows,
           identity_fields: identity_fields,
           field_types: field_types(child_contract),
           sync_predicate: sync_predicate,
           delete_missing?: delete_missing?,
           metadata:
             %{
               relationship: to_string(relationship),
               ownership: value(spec, :ownership),
               mutation_mode: representation,
               identity_mapping?: identity_mapping?(spec)
             }
             |> put_bound_scope(bound_cleanup?(collection_scope, rows, opts))
         },
         {:ok, descendant_nodes} <-
           compile_descendants(
             nested_by_row,
             child_domain,
             child_contract,
             node_id,
             opts,
             depth
           ) do
      {:ok, [node | descendant_nodes]}
    end
  end

  defp final_collection_candidate(
         operation,
         contract,
         relationship,
         entries,
         rows,
         representation,
         path,
         identity_fields,
         child_contract,
         parent_key,
         relation,
         child_key,
         opts
       ) do
    if Keyword.get(opts, :native_rule_candidate?, false) do
      normalized =
        Enum.zip(entries, rows)
        |> Enum.map(fn {entry, row} ->
          values =
            Map.new(row.command.assignments, fn %{field: field, value: {:literal, value}} ->
              {to_string(field), value}
            end)

          attrs = Map.new(entry.attrs, fn {field, value} -> {to_string(field), value} end)
          %{entry | attrs: Map.merge(attrs, values)}
        end)

      with {:ok, validated} <-
             SelectoUpdato.RuleValidation.validate_nested_collection(
               operation,
               contract,
               relationship,
               normalized,
               representation,
               path,
               identity_fields,
               Map.keys(field_types(child_contract)),
               parent_key,
               relation,
               child_key,
               opts
             ),
           true <- validated == normalized do
        :ok
      else
        false ->
          {:error,
           Error.new(:validation, "collection normalization changed an approved child command",
             details: %{code: :required_data_rule_pending, path: path}
           )}

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  defp compile_rows(
         entries,
         child_domain,
         child_contract,
         child_key,
         {parent_node, parent_row, parent_key},
         relationship_path,
         cardinality,
         identity_fields,
         predicate_fields,
         opts
       ) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, rows} ->
      attrs = Map.fetch!(entry, :attrs)
      semantic_operation = Map.fetch!(entry, :operation)
      path_segment = entry_path_segment(entry, identity_fields, index)

      row_path =
        if cardinality == :one,
          do: relationship_path,
          else: relationship_path ++ [path_segment]

      row_id = unique_row_id(entry, identity_fields, index)

      with :ok <- validate_nested_entry(attrs, row_path),
           :ok <- reject_generated_field(attrs, child_key, row_path),
           {:ok, flat_payload, nested_payload} <- split_payload(attrs, child_contract),
           {:ok, child_operation} <-
             child_operation(
               child_domain,
               flat_payload,
               semantic_operation,
               identity_fields,
               predicate_fields,
               row_path
             ),
           {:ok, child_operation} <-
             bind_trusted_scope(child_operation, child_domain, opts, row_path),
           child_opts =
             Keyword.put(opts, :record_state_ownership, %{
               parent_command: Keyword.fetch!(opts, :candidate_parent_command),
               parent_key: parent_key,
               child_key: child_key
             }),
           {:ok, command, _context} <- PortableCommand.compile_flat(child_operation, child_opts),
           command = ensure_returning(command, identity_fields),
           command = ensure_returning_for_nested(command, child_domain, nested_payload),
           binding = %Binding{
             field: child_key,
             from_node: parent_node,
             from_row: parent_row,
             from_field: parent_key
           },
           row = %Row{
             id: row_id,
             path: row_path,
             command: command,
             bindings: [binding],
             metadata: %{
               identity: identity_values(attrs, identity_fields),
               client_identity: Map.get(entry, :client_identity),
               semantic_operation:
                 effective_semantic_operation(semantic_operation, command.operation)
             }
           } do
        nested_row = {row_id, row_path, child_operation.type, nested_payload, command}
        {:cont, {:ok, rows ++ [{row, nested_row}]}}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, prefix_nested_rule_error(error, row_path)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp compile_descendants(nested_by_row, child_domain, child_contract, node_id, opts, depth) do
    Enum.reduce_while(nested_by_row, {:ok, []}, fn
      {_row_id, _row_path, _operation, nested, _command}, {:ok, nodes}
      when map_size(nested) == 0 ->
        {:cont, {:ok, nodes}}

      {row_id, row_path, operation, nested, command}, {:ok, nodes} ->
        nested_opts = Keyword.put(opts, :candidate_parent_command, command)

        with {:ok, parent_key} <- primary_key(child_domain),
             {:ok, child_nodes} <-
               compile_relationships(
                 child_domain,
                 child_contract,
                 nested,
                 operation,
                 {node_id, row_id, parent_key},
                 row_path,
                 nested_opts,
                 depth + 1
               ) do
          {:cont, {:ok, nodes ++ child_nodes}}
        else
          {:error, _} = error -> {:halt, error}
        end
    end)
  end

  defp validate_nesting_depth(depth, _path) when depth <= @max_nesting_depth, do: :ok

  defp validate_nesting_depth(depth, path) do
    {:error,
     graph_error(
       "nested write exceeds the maximum relationship depth",
       path,
       %{depth: depth, max_depth: @max_nesting_depth}
     )}
  end

  # Bound status flows from the root, or from any node, to every descendant
  # write and delete at every depth (w3exrev18 item 33): if the root or any
  # node is bound (engine tenant, trusted pin, query enforcement, a scoped
  # collection, a bound command), every node is marked `bound_scope` (its
  # delete-missing cleanup runs the bound delete contract) and every row
  # command carries `bound_scope`: explicit delta deletes, link_delta
  # unlinks, and descendant inserts and updates (item 33a), so the adapter
  # refuses statement-level triggers and rules for each.
  defp propagate_bound_scope(%Node{} = root_node, child_nodes, %Operation{} = operation, opts) do
    nodes = [root_node | child_nodes]

    bound? =
      not is_nil(operation.query_enforcement) or
        bound_cleanup?(nil, Enum.flat_map(nodes, & &1.rows), opts) or
        Enum.any?(nodes, &(Map.get(&1.metadata || %{}, :bound_scope) == true))

    if bound? do
      Enum.map(child_nodes, fn node ->
        %{
          node
          | metadata: Map.put(node.metadata || %{}, :bound_scope, true),
            rows: Enum.map(node.rows, &bind_row/1)
        }
      end)
    else
      child_nodes
    end
  end

  defp bind_row(%Row{command: %Command{} = command} = row),
    do: %{
      row
      | command: %{command | metadata: Map.put(command.metadata || %{}, :bound_scope, true)}
    }

  defp bind_row(row), do: row

  # A delete-missing cleanup is a bound-scope delete (w3exrev17) when the
  # collection is scoped (tenant or required filters), a trusted pin or
  # engine tenant governs the graph, or the parent or any child command is
  # itself bound (post-image, query enforcement, tenant fields).
  defp bound_cleanup?(collection_scope, rows, opts) do
    parent = Keyword.get(opts, :candidate_parent_command)
    context = Keyword.get(opts, :context) || %{}

    commands =
      [parent | Enum.map(rows, &Map.get(&1, :command))]
      |> Enum.filter(&match?(%Command{}, &1))

    not is_nil(collection_scope) or
      not is_nil(Keyword.get(opts, :graph_root_tenant)) or
      not is_nil(map_get(context, :tenant_id)) or
      map_get(context, :required_filters) not in [nil, []] or
      Keyword.get(opts, :required_filters) not in [nil, []] or
      Enum.any?(commands, &bound_command?/1)
  end

  defp bound_command?(%Command{metadata: metadata}) when is_map(metadata) do
    Enum.any?(
      [:post_image, :bound_scope, :query_enforcement, :tenant_fields, :insert_admission],
      &(Map.get(metadata, &1) not in [nil, [], false])
    )
  end

  defp bound_command?(_command), do: false

  defp map_get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp map_get(_map, _key), do: nil

  defp put_bound_scope(metadata, true), do: Map.put(metadata, :bound_scope, true)
  defp put_bound_scope(metadata, false), do: metadata

  # A trusted context's required filters bound every graph child as they
  # bound the root: each joins the child's pre-image (its filters) and its
  # post-image (trusted scope), so a child row outside the pin is neither
  # read, written nor left behind. A child whose relation lacks a pinned
  # column cannot be bound and refuses the graph.
  defp bind_trusted_scope(%Operation{} = child, child_domain, opts, path) do
    filters = SelectoUpdato.Tenant.requested_required_filters(child, opts)
    source = Map.get(child_domain, :source, Map.get(child_domain, "source")) || %{}

    fields =
      source
      |> Selecto.Domain.Contract.Shared.Core.relation_fields()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    unbound =
      filters
      |> Enum.flat_map(&Selecto.Builder.ExactCompare.comparison_fields/1)
      |> Enum.map(&(&1 |> String.split(".") |> List.last()))
      |> Enum.reject(&MapSet.member?(fields, &1))
      |> Enum.uniq()

    cond do
      filters == [] ->
        {:ok, child}

      unbound != [] ->
        {:error,
         Error.new(:missing_tenant_scope, "a graph child cannot be bound to the trusted scope",
           details: %{
             code: :trusted_scope_unbound_child,
             path: path,
             fields: Enum.sort(unbound)
           }
         )}

      true ->
        child = Enum.reduce(filters, child, &SelectoUpdato.Tenant.require_tenant_filter(&2, &1))
        applied = Keyword.get(child.opts || [], :trusted_required_filters, [])

        {:ok,
         %{
           child
           | opts:
               Keyword.put(
                 child.opts || [],
                 :trusted_required_filters,
                 Enum.uniq(applied ++ filters)
               )
         }}
    end
  end

  defp child_operation(domain, attrs, operation, _identity_fields, _predicate_fields, _path)
       when operation in [:insert, :create, :link] do
    {:ok, SelectoUpdato.insert(SelectoUpdato.new(domain), attrs)}
  end

  defp child_operation(domain, attrs, operation, identity_fields, predicate_fields, path)
       when operation in [:update, :auto] do
    identity = identity_values(attrs, identity_fields)

    if map_size(identity) == length(identity_fields) do
      with {:ok, predicate} <- required_identity_values(attrs, predicate_fields, path) do
        changes = drop_fields(attrs, predicate_fields)

        if map_size(changes) == 0 do
          {:error,
           graph_error(
             "nested child update requires at least one writable scalar change",
             path,
             %{}
           )}
        else
          operation =
            domain
            |> SelectoUpdato.new()
            |> SelectoUpdato.update(changes)
            |> SelectoUpdato.filters(Enum.map(predicate, fn {field, value} -> {field, value} end))

          {:ok, operation}
        end
      end
    else
      if operation == :auto do
        {:ok, SelectoUpdato.insert(SelectoUpdato.new(domain), attrs)}
      else
        {:error,
         graph_error("nested child update requires its complete stable identity", path, %{
           identity_fields: identity_fields
         })}
      end
    end
  rescue
    error in ArgumentError ->
      {:error,
       Error.new(:invalid_graph, "nested relationship identity is invalid",
         details: %{path: path, error: Exception.message(error)}
       )}
  end

  defp child_operation(domain, attrs, operation, identity_fields, predicate_fields, path)
       when operation in [:delete, :unlink] do
    with {:ok, _identity} <- required_identity_values(attrs, identity_fields, path),
         {:ok, predicate} <- required_identity_values(attrs, predicate_fields, path) do
      delete =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.filters(Enum.map(predicate, fn {field, value} -> {field, value} end))
        |> SelectoUpdato.delete()

      {:ok, delete}
    end
  rescue
    error in ArgumentError ->
      {:error,
       Error.new(:invalid_graph, "nested relationship identity is invalid",
         details: %{path: path, error: Exception.message(error)}
       )}
  end

  defp child_operation(_domain, _attrs, operation, _identity_fields, _predicate_fields, path) do
    {:error,
     graph_error("nested relationship operation is unsupported", path, %{operation: operation})}
  end

  defp split_payload(payload, contract) when is_map(payload) do
    relationships = contract.relationships

    {flat, nested} =
      Enum.reduce(payload, {%{}, %{}}, fn {key, value}, {flat, nested} ->
        case relationship_spec(relationships, key) do
          nil -> {Map.put(flat, key, value), nested}
          _spec -> {flat, Map.put(nested, key, value)}
        end
      end)

    {:ok, flat, nested}
  end

  defp split_payload(payload, _contract) do
    {:error,
     Error.new(:invalid_graph, "nested write payload must be a map", details: %{actual: payload})}
  end

  defp put_payload(%Operation{type: :insert} = operation, payload),
    do: {:ok, %{operation | attrs: payload}}

  defp put_payload(%Operation{type: :update} = operation, payload),
    do: {:ok, %{operation | changes: payload}}

  defp payload(%Operation{type: :insert, attrs: attrs}), do: attrs
  defp payload(%Operation{type: :update, changes: changes}), do: changes
  defp payload(%Operation{}), do: nil

  defp ensure_root_changes(%Operation{type: :update}, payload) when map_size(payload) == 0 do
    {:error,
     Error.new(:invalid_graph, "nested root update requires at least one writable scalar change")}
  end

  defp ensure_root_changes(%Operation{}, _payload), do: :ok

  defp validate_relationship_policy(spec, relationship, operation, representation, path)
       when is_map(spec) do
    ownership = canonical_ownership(value(spec, :ownership))
    allowed_modes = declared_mutation_modes(spec)
    allowed_operations = allowed_semantic_operations(spec)
    required_operation = parent_required_operation(operation, representation)

    cond do
      not relationship_operations_declared?(spec) ->
        {:error,
         Error.new(
           :write_policy_missing,
           "nested relationship declares no allowed_ops or write operations",
           details: %{
             relationship: relationship,
             path: path,
             required: [:writes, :relationships, relationship, :allowed_ops]
           }
         )}

      not relationship_writable?(spec) ->
        relationship_error("nested relationship is not writable", relationship, path,
          type: :write_relation_mismatch
        )

      representation == :link_delta and
          ownership not in [:shared_association, :join_association] ->
        relationship_error(
          "link_delta requires shared or join association policy",
          relationship,
          path
        )

      representation != :link_delta and ownership != :composition ->
        relationship_error(
          "nested create, update, and delete require composition ownership",
          relationship,
          path
        )

      allowed_modes != [] and representation not in allowed_modes ->
        relationship_error(
          "mutation representation is not allowed for nested relationship",
          relationship,
          path,
          representation: representation,
          allowed_modes: allowed_modes
        )

      not is_nil(required_operation) and required_operation not in allowed_operations ->
        relationship_error("operation is not allowed for nested relationship", relationship, path,
          type: :write_operation_not_enabled,
          operation: required_operation,
          allowed_operations: allowed_operations
        )

      true ->
        :ok
    end
  end

  defp validate_relationship_policy(
         _spec,
         relationship,
         _operation,
         _representation,
         path
       ),
       do: relationship_error("nested relationship policy must be a map", relationship, path)

  defp validate_child_operations(spec, rows, path) do
    explicit? = is_map(value(spec, :write))

    allowed =
      if explicit?, do: allowed_semantic_operations(spec), else: legacy_allowed_operations(spec)

    rows
    |> Enum.map(fn row ->
      if explicit?, do: Map.get(row.metadata, :semantic_operation), else: row.command.operation
    end)
    |> Enum.uniq()
    |> Enum.find(&(&1 not in allowed))
    |> case do
      nil ->
        :ok

      operation ->
        {:error,
         graph_error(
           "nested child operation is not allowed by relationship policy",
           path,
           %{operation: operation, allowed_operations: allowed},
           :write_operation_not_enabled
         )}
    end
  end

  defp validate_delete_missing_policy(_spec, false, _path), do: :ok

  defp validate_delete_missing_policy(spec, true, path) do
    explicit? = is_map(value(spec, :write))

    allowed =
      if explicit?, do: allowed_semantic_operations(spec), else: legacy_allowed_operations(spec)

    if :delete in allowed do
      :ok
    else
      {:error,
       graph_error(
         "delete_missing requires nested delete permission",
         path,
         %{operation: :delete, allowed_operations: allowed},
         :write_operation_not_enabled
       )}
    end
  end

  defp child_domain(spec, path) do
    case value(spec, :domain) do
      domain when is_map(domain) ->
        {:ok, domain}

      _other ->
        {:error,
         Error.new(
           :write_policy_missing,
           "nested relationship must declare a child domain with its own write contract",
           details: %{path: path, required: [:domain]}
         )}
    end
  end

  defp child_key(spec, path) do
    key = value(spec, :child_key, value(spec, :foreign_key))

    if valid_identifier?(key),
      do: {:ok, key},
      else:
        {:error, graph_error("nested relationship must declare child_key", path, %{actual: key})}
  end

  defp cardinality(spec, path) do
    case value(spec, :cardinality) do
      cardinality when cardinality in [:one, "one"] ->
        {:ok, :one}

      cardinality when cardinality in [:many, "many"] ->
        {:ok, :many}

      other ->
        {:error,
         graph_error("nested relationship has invalid cardinality", path, %{actual: other})}
    end
  end

  defp relationship_entries(value, cardinality, spec, parent_operation, path) do
    with {:ok, representation, payload} <-
           detect_representation(value, cardinality, spec, parent_operation, path),
         {:ok, entries} <-
           representation_entries(representation, payload, cardinality, spec, path),
         :ok <- validate_unique_entry_ids(entries, spec, path),
         :ok <- validate_relationship_validation(entries, spec, representation, path) do
      {:ok, representation, entries}
    end
  end

  defp detect_representation(value, cardinality, spec, parent_operation, path) do
    declared = declared_mutation_modes(spec)
    explicit_authored? = is_map(value) and has_field?(value, :mode)
    explicit_value = if explicit_authored?, do: value(value, :mode)
    explicit = normalize_mutation_mode(explicit_value)

    inferred =
      cond do
        explicit ->
          explicit

        delta_payload?(value) and :delta in declared ->
          :delta

        link_delta_payload?(value) ->
          :link_delta

        cardinality == :one and :replace_one in declared ->
          :replace_one

        is_list(value) and parent_operation == :insert and :append_only in declared ->
          :append_only

        is_list(value) and :full_set in declared ->
          :full_set

        is_list(value) and :append_only in declared ->
          :append_only

        declared != [] ->
          List.first(declared)

        parent_operation == :insert ->
          :append_only

        true ->
          :full_set
      end

    cond do
      explicit_authored? and is_nil(explicit) ->
        {:error,
         graph_error("nested mutation representation is unknown", path, %{
           representation: explicit_value,
           declared_modes: declared
         })}

      declared == [] or inferred in declared ->
        {:ok, inferred, unwrap_representation_payload(value, inferred)}

      true ->
        {:error,
         graph_error(
           "nested mutation representation is not declared by the relationship",
           path,
           %{
             representation: inferred,
             declared_modes: declared
           }
         )}
    end
  end

  defp representation_entries(:append_only, payload, cardinality, spec, path) do
    with {:ok, values} <- collection_values(payload, cardinality, path),
         {:ok, values} <- validate_item_bounds(values, spec, path, cardinality_max(cardinality)) do
      {:ok, Enum.map(values, &entry(:create, &1, spec))}
    end
  end

  defp representation_entries(:full_set, payload, cardinality, spec, path) do
    with {:ok, values} <- collection_values(payload, cardinality, path),
         {:ok, values} <- validate_item_bounds(values, spec, path, cardinality_max(cardinality)) do
      {:ok, Enum.map(values, &entry(:auto, &1, spec))}
    end
  end

  defp representation_entries(:delta, payload, _cardinality, spec, path) when is_map(payload) do
    with {:ok, creates} <- operation_values(payload, :create, path),
         {:ok, updates} <- operation_values(payload, :update, path),
         {:ok, deletes} <- operation_values(payload, :delete, path),
         entries =
           Enum.map(creates, &entry(:create, &1, spec)) ++
             Enum.map(updates, &entry(:update, &1, spec)) ++
             Enum.map(deletes, &entry(:delete, &1, spec)),
         :ok <- validate_mutation_count(entries, spec, path) do
      if entries == [] do
        {:error, graph_error("delta nested mutation requires at least one change", path, %{})}
      else
        {:ok, entries}
      end
    end
  end

  defp representation_entries(:replace_one, payload, :one, spec, path) when is_map(payload) do
    explicit_operations =
      [:create, :update, :delete]
      |> Enum.flat_map(fn operation ->
        case value(payload, operation) do
          nil -> []
          item when is_map(item) -> [{operation, item}]
          item -> [{:invalid, {operation, item}}]
        end
      end)

    invalid = Enum.find(explicit_operations, &match?({:invalid, _}, &1))

    cond do
      match?({:invalid, _}, invalid) ->
        {:invalid, {operation, actual}} = invalid

        {:error,
         graph_error("replace_one operation payload must be a map", path, %{
           operation: operation,
           actual: actual
         })}

      length(explicit_operations) > 1 ->
        {:error,
         graph_error(
           "replace_one accepts exactly one create, update, or delete intent",
           path,
           %{}
         )}

      length(explicit_operations) == 1 ->
        [{operation, item}] = explicit_operations
        {:ok, [entry(operation, item, spec)]}

      true ->
        operation = if complete_identity?(payload, spec), do: :update, else: :create
        {:ok, [entry(operation, payload, spec)]}
    end
  end

  defp representation_entries(:link_delta, payload, _cardinality, spec, path)
       when is_map(payload) do
    with {:ok, links} <- operation_values(payload, :link, path),
         {:ok, unlinks} <- operation_values(payload, :unlink, path),
         entries =
           Enum.map(links, &entry(:link, &1, spec)) ++
             Enum.map(unlinks, &entry(:unlink, &1, spec)),
         :ok <- validate_mutation_count(entries, spec, path) do
      if entries == [] do
        {:error, graph_error("link_delta requires at least one link or unlink", path, %{})}
      else
        {:ok, entries}
      end
    end
  end

  defp representation_entries(representation, payload, cardinality, _spec, path) do
    {:error,
     graph_error("nested mutation payload does not match its declared representation", path, %{
       representation: representation,
       cardinality: cardinality,
       actual: payload
     })}
  end

  defp collection_values(payload, :many, _path) when is_list(payload), do: {:ok, payload}
  defp collection_values(nil, :one, _path), do: {:ok, []}
  defp collection_values(payload, :one, _path) when is_map(payload), do: {:ok, [payload]}

  defp collection_values(payload, cardinality, path) do
    {:error,
     graph_error("nested mutation payload has invalid collection cardinality", path, %{
       cardinality: cardinality,
       actual: payload
     })}
  end

  defp operation_values(payload, operation, path) do
    case value(payload, operation, []) do
      values when is_list(values) ->
        if Enum.all?(values, &is_map/1) do
          {:ok, values}
        else
          {:error,
           graph_error("nested delta operation must contain maps", path, %{
             operation: operation,
             actual: values
           })}
        end

      value when is_map(value) ->
        {:ok, [value]}

      value ->
        {:error,
         graph_error("nested delta operation must contain maps", path, %{
           operation: operation,
           actual: value
         })}
    end
  end

  defp validate_item_bounds(entries, spec, path, cardinality_max) do
    write = value(spec, :write, %{})

    min =
      value(
        write,
        :min_items,
        value(spec, :min_items, if(truthy?(value(spec, :required, false)), do: 1, else: 0))
      )

    max = value(write, :max_items, value(spec, :max_items, cardinality_max))

    cond do
      not is_integer(min) or min < 0 ->
        {:error, graph_error("nested relationship min_items is invalid", path, %{actual: min})}

      not is_nil(max) and (not is_integer(max) or max < min) ->
        {:error, graph_error("nested relationship max_items is invalid", path, %{actual: max})}

      length(entries) < min ->
        {:error,
         graph_error("nested relationship has too few items", path, %{
           minimum: min,
           actual: length(entries)
         })}

      not is_nil(max) and length(entries) > max ->
        {:error,
         graph_error("nested relationship has too many items", path, %{
           maximum: max,
           actual: length(entries)
         })}

      true ->
        {:ok, entries}
    end
  end

  defp validate_mutation_count(entries, spec, path) do
    write = value(spec, :write, %{})
    maximum = value(write, :max_mutations, value(write, :max_items, value(spec, :max_items)))

    if is_integer(maximum) and maximum > 0 and length(entries) > maximum do
      {:error,
       graph_error("nested mutation exceeds its declared mutation bound", path, %{
         maximum: maximum,
         actual: length(entries)
       })}
    else
      :ok
    end
  end

  defp unwrap_representation_payload(payload, representation)
       when representation in [:delta, :link_delta],
       do: payload

  defp unwrap_representation_payload(payload, :replace_one) when is_map(payload) do
    value(payload, :value, payload)
  end

  defp unwrap_representation_payload(payload, :full_set) when is_map(payload) do
    value(payload, :items, value(payload, :set, payload))
  end

  defp unwrap_representation_payload(payload, :append_only) when is_map(payload) do
    value(payload, :items, value(payload, :create, payload))
  end

  defp unwrap_representation_payload(payload, _representation), do: payload

  defp declared_mutation_modes(spec) do
    write = value(spec, :write, %{})

    modes =
      write
      |> value(:modes, [])
      |> List.wrap()
      |> Enum.map(&normalize_mutation_mode/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      modes != [] -> modes
      value(spec, :strategy) in [:sync, "sync"] -> [:full_set]
      true -> []
    end
  end

  defp normalize_mutation_mode(value)
       when value in [:append_only, "append_only", :append, "append"],
       do: :append_only

  defp normalize_mutation_mode(value) when value in [:delta, "delta"], do: :delta
  defp normalize_mutation_mode(value) when value in [:full_set, "full_set"], do: :full_set

  defp normalize_mutation_mode(value) when value in [:replace_one, "replace_one"],
    do: :replace_one

  defp normalize_mutation_mode(value) when value in [:link_delta, "link_delta"], do: :link_delta
  defp normalize_mutation_mode(_value), do: nil

  defp delta_payload?(payload) when is_map(payload),
    do: Enum.any?([:create, :update, :delete], &has_field?(payload, &1))

  defp delta_payload?(_payload), do: false

  defp link_delta_payload?(payload) when is_map(payload),
    do: Enum.any?([:link, :unlink], &has_field?(payload, &1))

  defp link_delta_payload?(_payload), do: false

  defp cardinality_max(:one), do: 1
  defp cardinality_max(:many), do: nil

  defp entry(operation, attrs, spec) when is_map(attrs) do
    client_field = value(spec, :client_identity)
    stable_paths? = is_map(value(spec, :write)) or not is_nil(client_field)

    client_identity =
      case client_field do
        nil ->
          nil

        field ->
          case fetch_field(attrs, field) do
            {:ok, value} -> value
            :error -> nil
          end
      end

    attrs = if is_nil(client_field), do: attrs, else: drop_fields(attrs, [client_field])

    %{
      operation: operation,
      attrs: attrs,
      client_identity: client_identity,
      stable_paths?: stable_paths?
    }
  end

  defp entry(operation, attrs, _spec),
    do: %{operation: operation, attrs: attrs, client_identity: nil, stable_paths?: false}

  defp validate_unique_entry_ids(entries, spec, path) do
    identity_fields = value(spec, :identity_fields, []) |> List.wrap()
    client_field = value(spec, :client_identity)

    missing_client =
      if is_nil(client_field) do
        nil
      else
        Enum.find(entries, fn entry ->
          (entry.operation == :create or
             (entry.operation == :auto and
                is_nil(entry_identity_token(entry, identity_fields)))) and
            is_nil(entry.client_identity)
        end)
      end

    missing_link_identity =
      Enum.find(entries, fn entry ->
        entry.operation == :link and is_nil(entry_identity_token(entry, identity_fields))
      end)

    identities =
      entries
      |> Enum.map(&entry_identity_token(&1, identity_fields))
      |> Enum.reject(&is_nil/1)

    duplicate =
      identities
      |> Enum.frequencies()
      |> Enum.find_value(fn
        {identity, count} when count > 1 -> identity
        _entry -> nil
      end)

    cond do
      missing_client ->
        {:error,
         graph_error("nested create requires a stable client identity", path, %{
           client_identity_field: client_field
         })}

      missing_link_identity ->
        {:error,
         graph_error("nested link requires its complete shared identity", path, %{
           identity_fields: identity_fields
         })}

      duplicate ->
        {:error,
         graph_error("nested mutation contains a duplicate stable identity", path, %{
           identity: duplicate
         })}

      true ->
        :ok
    end
  end

  defp validate_relationship_validation(entries, spec, representation, path) do
    case value(spec, :validation, %{}) do
      policy when policy in [nil, %{}] ->
        :ok

      policy when is_map(policy) ->
        with :ok <- validate_relationship_validation_keys(policy, path),
             :ok <- validate_field_rules(entries, value(policy, :field_rules, []), spec, path),
             :ok <- validate_unique_fields(entries, value(policy, :unique_fields, []), spec, path),
             :ok <-
               validate_aggregate_rules(
                 entries,
                 value(policy, :aggregate_rules, []),
                 representation,
                 spec,
                 path
               ) do
          :ok
        end

      policy ->
        {:error,
         graph_error("nested relationship validation policy must be a map", path, %{
           actual: policy
         })}
    end
  end

  defp validate_relationship_validation_keys(policy, path) do
    allowed = ~w(field_rules unique_fields aggregate_rules)
    unknown = Enum.map(Map.keys(policy), &to_string/1) -- allowed

    if unknown == [] do
      :ok
    else
      {:error,
       graph_error("nested relationship validation policy is unsupported", path, %{
         unsupported_keys: Enum.sort(unknown)
       })}
    end
  end

  defp validate_field_rules(_entries, [], _spec, _path), do: :ok

  defp validate_field_rules(entries, rules, spec, path) when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case validate_field_rule(entries, rule, spec, path) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp validate_field_rules(_entries, rules, _spec, path) do
    {:error, graph_error("nested field validation rules must be a list", path, %{actual: rules})}
  end

  defp validate_field_rule(entries, rule, spec, path) when is_map(rule) do
    field = value(rule, :field)
    type = value(rule, :type)

    cond do
      not valid_identifier?(field) ->
        {:error, graph_error("nested field validation field is invalid", path, %{field: field})}

      type not in [:number, "number"] ->
        {:error, graph_error("nested field validation type is unsupported", path, %{type: type})}

      true ->
        validate_number_field_entries(entries, rule, field, spec, path)
    end
  end

  defp validate_field_rule(_entries, rule, _spec, path) do
    {:error, graph_error("nested field validation rule must be a map", path, %{actual: rule})}
  end

  defp validate_number_field_entries(entries, rule, field, spec, path) do
    identity_fields = value(spec, :identity_fields, []) |> List.wrap()

    tests_result = Selecto.Rule.Legacy.input_test(rule)

    case tests_result do
      {:ok, test} ->
        with {:ok, compiled} <- Selecto.Rule.Contract.compile_test(test) do
          entries
          |> Enum.with_index()
          |> Enum.reject(fn {entry, _index} -> entry.operation in [:delete, :unlink] end)
          |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
            authored = authored_value(entry.attrs, field)

            item_path =
              path ++ [entry_path_segment(entry, identity_fields, index), to_string(field)]

            result =
              if authored in [nil, ""] and not truthy?(value(rule, :required, false)) do
                :ok
              else
                evaluate_nested_field_test(compiled, authored, field, item_path)
              end

            case result do
              :ok -> {:cont, :ok}
              {:error, _error} = error -> {:halt, error}
            end
          end)
        end

      {:error, unsupported} ->
        {:error,
         graph_error("nested field validation rule is unsupported", path, %{
           rule: unsupported
         })}
    end
  end

  defp evaluate_nested_field_test(compiled, authored, field, path) do
    case Selecto.Rule.Evaluator.evaluate_test(compiled, authored) do
      :passed ->
        :ok

      {:failed, details} ->
        {:error,
         graph_error("nested field violates its declared rule", path, %{
           field: to_string(field),
           rule: details
         })}

      {:error, details} ->
        {:error,
         graph_error("nested field rule could not be evaluated", path, %{
           field: to_string(field),
           rule: details
         })}
    end
  end

  defp validate_unique_fields(_entries, [], _spec, _path), do: :ok

  defp validate_unique_fields(entries, fields, spec, path) when is_list(fields) do
    fields = Enum.map(fields, &to_string/1)

    if fields == [] or Enum.any?(fields, &(String.trim(&1) == "")) do
      {:error, graph_error("nested unique-fields validation is invalid", path, %{fields: fields})}
    else
      candidates =
        entries
        |> Enum.with_index()
        |> Enum.reject(fn {entry, _index} -> entry.operation in [:delete, :unlink] end)
        |> Enum.map(fn {entry, index} ->
          values = Enum.map(fields, &authored_value(entry.attrs, &1))
          {values, entry, index}
        end)
        |> Enum.reject(fn {values, _entry, _index} -> Enum.any?(values, &(&1 in [nil, ""])) end)

      test = %{
        op: "collection.unique_by",
        paths: Enum.map(fields, &[&1])
      }

      with {:ok, compiled} <- Selecto.Rule.Contract.compile_test(test),
           :passed <-
             Selecto.Rule.Evaluator.evaluate_test(
               compiled,
               Enum.map(candidates, fn {_values, entry, _index} -> entry.attrs end)
             ) do
        :ok
      else
        {:failed, %{code: :duplicate_collection_value}} ->
          {values, entry, index} = duplicate_candidate(candidates)
          identity_fields = value(spec, :identity_fields, []) |> List.wrap()
          item_path = path ++ [entry_path_segment(entry, identity_fields, index)]

          {:error,
           graph_error("nested relationship contains duplicate cross-child values", item_path, %{
             fields: fields,
             values: values
           })}

        {:failed, details} ->
          {:error,
           graph_error("nested unique-fields rule could not be satisfied", path, %{
             fields: fields,
             rule: details
           })}

        {:error, details} ->
          {:error,
           graph_error("nested unique-fields rule could not be evaluated", path, %{
             fields: fields,
             rule: details
           })}
      end
    end
  end

  defp validate_unique_fields(_entries, fields, _spec, path) do
    {:error,
     graph_error("nested unique-fields validation must be a list", path, %{actual: fields})}
  end

  defp duplicate_candidate(candidates) do
    candidates
    |> Enum.group_by(fn {values, _entry, _index} -> values end)
    |> Enum.find_value(fn
      {values, [_first, {_values, entry, index} | _rest]} -> {values, entry, index}
      _pair -> nil
    end)
  end

  defp validate_aggregate_rules(_entries, [], _representation, _spec, _path), do: :ok

  defp validate_aggregate_rules(entries, rules, representation, spec, path)
       when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case validate_aggregate_rule(entries, rule, representation, spec, path) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp validate_aggregate_rules(_entries, rules, _representation, _spec, path) do
    {:error,
     graph_error("nested aggregate validation rules must be a list", path, %{actual: rules})}
  end

  defp validate_aggregate_rule(entries, rule, representation, spec, path) when is_map(rule) do
    operation = value(rule, :operation)
    field = value(rule, :field)
    representations = value(rule, :representations, [:full_set]) |> List.wrap()
    representations = Enum.map(representations, &normalize_mutation_mode/1)

    cond do
      operation not in [:sum, "sum"] ->
        {:error,
         graph_error("nested aggregate validation operation is unsupported", path, %{
           operation: operation
         })}

      not valid_identifier?(field) ->
        {:error,
         graph_error("nested aggregate validation field is invalid", path, %{field: field})}

      Enum.any?(representations, &is_nil/1) ->
        {:error,
         graph_error("nested aggregate validation representations are invalid", path, %{
           representations: value(rule, :representations)
         })}

      representation not in representations ->
        :ok

      true ->
        validate_canonical_aggregate_sum(entries, rule, field, spec, path)
    end
  end

  defp validate_aggregate_rule(_entries, rule, _representation, _spec, path) do
    {:error, graph_error("nested aggregate validation rule must be a map", path, %{actual: rule})}
  end

  defp validate_canonical_aggregate_sum(entries, rule, field, _spec, path) do
    test = %{
      op: "collection.sum",
      path: [field],
      min: value(rule, :minimum),
      max: value(rule, :maximum)
    }

    values =
      entries
      |> Enum.reject(&(&1.operation in [:delete, :unlink]))
      |> Enum.map(& &1.attrs)

    with {:ok, compiled} <- Selecto.Rule.Contract.compile_test(test),
         :passed <- Selecto.Rule.Evaluator.evaluate_test(compiled, values) do
      :ok
    else
      {:failed, details} ->
        canonical_aggregate_failure(details, rule, field, path)

      {:error, details} ->
        {:error,
         graph_error("nested aggregate rule could not be compiled or evaluated", path, %{
           field: to_string(field),
           rule: details
         })}
    end
  end

  defp canonical_aggregate_failure(%{code: :invalid_collection_sum} = details, rule, field, path) do
    direction = Map.fetch!(details, :direction)
    boundary = if direction == :minimum, do: value(rule, :minimum), else: value(rule, :maximum)

    message =
      if direction == :minimum,
        do: "nested aggregate is below its declared minimum",
        else: "nested aggregate exceeds its declared maximum"

    {:error,
     graph_error(message, path, %{
       direction => boundary,
       field: to_string(field),
       actual: canonical_aggregate_actual(Map.fetch!(details, :actual))
     })}
  end

  defp canonical_aggregate_failure(details, _rule, field, path) do
    {:error,
     graph_error("nested aggregate violates its declared rule", path, %{
       field: to_string(field),
       rule: details
     })}
  end

  defp canonical_aggregate_actual(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        if Decimal.equal?(decimal, Decimal.round(decimal, 0)),
          do: Decimal.to_integer(decimal),
          else: Decimal.to_string(decimal, :normal)

      _other ->
        value
    end
  end

  defp canonical_aggregate_actual(value), do: value

  defp authored_value(map, field) do
    case fetch_field(map, field) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp entry_identity_token(%{client_identity: value}, _identity_fields) when not is_nil(value),
    do: {:client, to_string(value)}

  defp entry_identity_token(%{attrs: attrs}, identity_fields) do
    identity = identity_values(attrs, identity_fields)

    if identity_fields != [] and map_size(identity) == length(identity_fields) do
      {:server,
       Enum.map(identity_fields, fn field -> {to_string(field), Map.fetch!(identity, field)} end)}
    end
  end

  defp entry_identity_token(_entry, _identity_fields), do: nil

  defp complete_identity?(payload, spec) do
    fields = value(spec, :identity_fields, []) |> List.wrap()
    fields != [] and map_size(identity_values(payload, fields)) == length(fields)
  end

  defp entry_path_segment(entry, identity_fields, index) do
    case entry_identity_token(entry, identity_fields) do
      {:client, value} ->
        "client_id=#{value}"

      {:server, values} ->
        Enum.map_join(values, ",", fn {field, value} -> "#{field}=#{value}" end)

      nil ->
        if(entry.stable_paths?, do: "index=#{index}", else: index)
    end
  end

  defp unique_row_id(entry, identity_fields, index) do
    if entry.stable_paths? do
      operation = entry.operation |> normalize_semantic_operation() |> Atom.to_string()
      "#{operation}:#{entry_path_segment(entry, identity_fields, index)}"
    else
      Integer.to_string(index)
    end
  end

  defp required_identity_values(attrs, fields, path) do
    identity = identity_values(attrs, fields)

    if map_size(identity) == length(fields) do
      {:ok, identity}
    else
      missing = Enum.reject(fields, &Map.has_key?(identity, &1))

      {:error,
       graph_error(
         "nested child mutation requires its complete identity and conflict fields",
         path,
         %{
           missing_fields: missing
         }
       )}
    end
  end

  defp delete_missing?(spec, :full_set) do
    write = value(spec, :write, %{})

    value(write, :omission) in [:delete_missing, "delete_missing"] or
      truthy?(value(spec, :delete_missing, false))
  end

  defp delete_missing?(_spec, _representation), do: false

  defp identity_mapping?(spec) do
    output = value(spec, :output, %{})
    truthy?(value(output, :identity_mapping, not is_nil(value(spec, :client_identity))))
  end

  defp identity_fields(spec, domain, operation, path) when operation in [:insert, :update] do
    case value(spec, :identity_fields, []) |> List.wrap() do
      [] ->
        case primary_key(domain) do
          {:ok, key} -> {:ok, [key]}
          {:error, _} = error -> error
        end

      fields ->
        if Enum.all?(fields, &valid_identifier?/1) do
          {:ok, fields}
        else
          {:error,
           graph_error("nested sync identity fields are invalid", path, %{actual: fields})}
        end
    end
  end

  defp identity_fields(_spec, _domain, operation, path),
    do:
      {:error,
       graph_error("nested relationship operation is unsupported", path, %{operation: operation})}

  defp predicate_fields(spec, identity_fields, path) do
    conflict = value(spec, :conflict, %{})

    conflict_fields =
      value(conflict, :child_fields, value(conflict, :child_field, []))
      |> List.wrap()

    fields = Enum.uniq_by(identity_fields ++ conflict_fields, &to_string/1)

    if Enum.all?(fields, &valid_identifier?/1) do
      {:ok, fields}
    else
      {:error,
       graph_error("nested conflict identity fields are invalid", path, %{actual: fields})}
    end
  end

  defp strategy(_spec, :insert, _representation, _path), do: {:ok, :ordered}

  defp strategy(_spec, :update, :full_set, _path), do: {:ok, :sync}

  defp strategy(_spec, :update, representation, _path)
       when representation in [:append_only, :delta, :replace_one, :link_delta],
       do: {:ok, :ordered}

  defp strategy(_spec, operation, representation, path),
    do:
      {:error,
       graph_error("nested mutation strategy is unsupported", path, %{
         operation: operation,
         representation: representation
       })}

  # The candidate scope of a child collection follows the same tenant binding
  # as its writes (lessons 47 and 47a): the declared tenant_field bound to the
  # trusted tenant, or a site-column child confined to the root's pinned sites.
  defp collection_scope_predicate(contract, child_domain, opts) do
    context = Keyword.get(opts, :context, %{})
    tenant_id = context_value(context, :tenant_id)

    effective =
      PortableCommand.effective_tenant_contract(
        contract,
        %Operation{domain: child_domain},
        %{tenant_id: tenant_id},
        opts
      )

    with {:ok, predicate} <- collection_tenant_predicate(effective.scope, tenant_id) do
      # A child keeping its own tenancy also binds the root tenant column.
      case {effective.scope[:root_tenant_column], tenant_id} do
        {nil, _tenant_id} ->
          {:ok, predicate}

        {_field, nil} ->
          {:ok, predicate}

        {field, tenant_id} ->
          {:ok,
           combine_scope_predicates(predicate, {:eq, {:field, field}, {:literal, tenant_id}})}
      end
    end
  end

  defp collection_tenant_predicate(scope, tenant_id) do
    case scope do
      %{site_pin: %{child: true, field: field, values: nil}} ->
        {:error,
         Error.new(:missing_tenant_scope, "site writes need a trusted site pin",
           details: %{field: field}
         )}

      %{site_pin: %{child: true, field: field, values: []}} ->
        {:error,
         Error.new(:tenant_mismatch, "site pins do not intersect", details: %{field: field})}

      %{site_pin: %{child: true, field: field, values: values}} ->
        {:ok, {:in, {:field, field}, Enum.map(values, &{:literal, &1})}}

      %{tenant: %{required: true, field: field}} ->
        case tenant_id do
          nil ->
            {:error,
             Error.new(
               :missing_tenant_scope,
               "tenant scope is required for collection candidates",
               details: %{field: field}
             )}

          tenant_id ->
            {:ok, {:eq, {:field, field}, {:literal, tenant_id}}}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp sync_predicate(:ordered, _child_key, _parent_ref, _scope), do: {:ok, nil}

  defp sync_predicate(:sync, child_key, generated_parent, scope) do
    ownership = {:eq, {:field, child_key}, generated_parent}
    {:ok, combine_scope_predicates(ownership, scope)}
  end

  defp combine_scope_predicates(nil, right), do: right
  defp combine_scope_predicates(left, nil), do: left
  defp combine_scope_predicates(left, right), do: {:and, [left, right]}

  defp ensure_returning_for_nested(command, domain, nested_payload)
       when map_size(nested_payload) > 0 do
    case primary_key(domain) do
      {:ok, key} -> ensure_returning(command, [key])
      _ -> command
    end
  end

  defp ensure_returning_for_nested(command, _domain, _nested_payload), do: command

  defp ensure_returning(%Command{returning: :all} = command, _fields), do: command
  defp ensure_returning(%Command{} = command, []), do: command

  defp ensure_returning(%Command{returning: :none} = command, fields),
    do: %{command | returning: fields}

  defp ensure_returning(%Command{returning: returning} = command, fields) when is_list(returning),
    do: %{command | returning: Enum.uniq_by(returning ++ fields, &to_string/1)}

  defp primary_key(domain) do
    source = value(domain, :source, %{})
    key = value(source, :primary_key, value(domain, :primary_key, :id))

    if valid_identifier?(key),
      do: {:ok, key},
      else: {:error, Error.new(:invalid_graph, "nested domain must declare a primary key")}
  end

  defp relation([%Row{command: command} | _], _contract, _path), do: {:ok, command.relation}

  defp relation([], contract, path) do
    source = contract.source
    relation = SelectoUpdato.WriteContract.relation_name(source)

    if valid_identifier?(relation) and SelectoUpdato.WriteContract.relation_valid?(source) do
      {:ok, relation}
    else
      {:error,
       graph_error(
         "a nested child domain must declare a bare source_table, its schema in source_schema",
         path,
         %{actual: relation}
       )}
    end
  end

  defp reject_generated_field(attrs, child_key, path) do
    if has_field?(attrs, child_key) do
      {:error,
       graph_error("caller cannot supply a generated relationship foreign key", path, %{
         field: child_key
       })}
    else
      :ok
    end
  end

  defp identity_values(attrs, fields) when is_map(attrs) do
    Enum.reduce(fields, %{}, fn field, values ->
      case fetch_field(attrs, field) do
        {:ok, value} when not is_nil(value) -> Map.put(values, field, value)
        _ -> values
      end
    end)
  end

  defp identity_values(_attrs, _fields), do: %{}

  defp drop_fields(attrs, fields) do
    rejected = MapSet.new(fields, &to_string/1)
    Map.reject(attrs, fn {key, _value} -> MapSet.member?(rejected, to_string(key)) end)
  end

  defp relationship_spec(relationships, key) when is_map(relationships) do
    Enum.find_value(relationships, fn {candidate, spec} ->
      if to_string(candidate) == to_string(key), do: spec
    end)
  end

  defp compile_contract(domain) do
    case WriteContract.compile(domain) do
      {:ok, contract} -> {:ok, contract}
      {:error, error} -> {:error, Error.new(error.type, error.message, details: error.details)}
    end
  end

  defp parent_ref(node, row, field), do: {:generated, node, row, field}

  defp field_types(contract) do
    contract.source
    |> value(:columns, %{})
    |> Enum.reduce(%{}, fn {field, spec}, types ->
      case value(spec, :type) do
        type when is_atom(type) or is_binary(type) -> Map.put(types, field, type)
        _ -> types
      end
    end)
  end

  defp path_id(path) do
    path
    |> Enum.map(fn
      index when is_integer(index) -> Integer.to_string(index)
      segment -> to_string(segment)
    end)
    |> Enum.join("/")
  end

  defp normalize_path_segment(segment) when is_atom(segment) or is_binary(segment), do: segment

  # An edge's operations come from its explicit `write` policy or its
  # `allowed_ops`; an edge that declares neither has no write policy.
  defp relationship_operations_declared?(spec) do
    is_map(value(spec, :write)) or value(spec, :allowed_ops) != nil
  end

  defp relationship_writable?(spec) do
    write = value(spec, :write, %{})

    truthy?(value(spec, :writable, value(spec, :enabled, false))) or
      (is_map(write) and List.wrap(value(write, :modes, [])) != [])
  end

  defp allowed_semantic_operations(spec) do
    write = value(spec, :write, %{})

    explicit =
      if is_map(write) do
        [:create, :update, :delete, :reorder, :link, :unlink]
        |> Enum.filter(&truthy?(value(write, &1, false)))
      else
        []
      end

    legacy =
      spec
      |> value(:allowed_ops, [])
      |> List.wrap()
      |> Enum.map(fn
        value when value in [:insert, "insert", :nested_insert, "nested_insert"] -> :create
        value when value in [:update, "update", :nested_update, "nested_update"] -> :update
        value when value in [:delete, "delete"] -> :delete
        _value -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(explicit ++ legacy)
  end

  defp legacy_allowed_operations(spec) do
    spec
    |> value(:allowed_ops, [])
    |> List.wrap()
    |> Enum.map(&normalize_operation/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parent_required_operation(:insert, _representation), do: :create
  defp parent_required_operation(:update, :append_only), do: :create
  defp parent_required_operation(_operation, _representation), do: nil

  defp canonical_ownership(value) when value in [:owned, "owned", :composition, "composition"],
    do: :composition

  defp canonical_ownership(value)
       when value in [
              :shared_reference,
              "shared_reference",
              :shared_association,
              "shared_association"
            ],
       do: :shared_association

  defp canonical_ownership(value)
       when value in [:join_only, "join_only", :join_association, "join_association"],
       do: :join_association

  defp canonical_ownership(value) when value in [:derived, "derived"], do: :derived
  defp canonical_ownership(value) when value in [:deferred, "deferred"], do: :deferred
  defp canonical_ownership(_value), do: nil

  defp effective_semantic_operation(:auto, :insert), do: :create
  defp effective_semantic_operation(:auto, :update), do: :update
  defp effective_semantic_operation(operation, _command_operation), do: operation

  defp normalize_semantic_operation(:auto), do: :upsert
  defp normalize_semantic_operation(:create), do: :create
  defp normalize_semantic_operation(:link), do: :link
  defp normalize_semantic_operation(:unlink), do: :unlink
  defp normalize_semantic_operation(operation), do: operation

  defp normalize_operation(value) when value in [:insert, "insert"], do: :insert
  defp normalize_operation(value) when value in [:nested_insert, "nested_insert"], do: :insert
  defp normalize_operation(value) when value in [:update, "update"], do: :update
  defp normalize_operation(value) when value in [:nested_update, "nested_update"], do: :update
  defp normalize_operation(value) when value in [:delete, "delete"], do: :delete
  defp normalize_operation(value) when value in [:upsert, "upsert"], do: :upsert
  defp normalize_operation(_value), do: nil

  defp context_value(context, key) when is_map(context) do
    Map.get(context, key, Map.get(context, to_string(key)))
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp fetch_field(map, field) when is_map(map) do
    Enum.find_value(map, :error, fn {key, value} ->
      if to_string(key) == to_string(field), do: {:ok, value}
    end)
  end

  defp has_field?(map, field), do: match?({:ok, _}, fetch_field(map, field))
  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp valid_identifier?(value),
    do: is_atom(value) or (is_binary(value) and String.trim(value) != "")

  defp relationship_error(message, relationship, path, details \\ []) do
    {type, details} = Keyword.pop(details, :type, :invalid_graph)

    {:error,
     Error.new(type, message,
       details: Map.merge(%{relationship: relationship, path: path}, Map.new(details))
     )}
  end

  defp graph_error(message, path, details, type \\ :invalid_graph),
    do: Error.new(type, message, details: Map.put(details, :path, path))

  defp prefix_nested_rule_error(%Error{details: details} = error, row_path)
       when is_map(details) do
    if details[:code] in [:data_rule_failed, :required_data_rule_pending, :data_rule_error] do
      outcomes =
        Enum.map(Map.get(details, :outcomes, []), fn outcome ->
          Map.update(outcome, :path, row_path, &(row_path ++ &1))
        end)

      first_path = outcomes |> List.first() |> then(&(&1 && Map.get(&1, :path)))
      relative_path = Map.get(details, :path)
      prefixed_path = if is_list(relative_path), do: row_path ++ relative_path, else: row_path

      %{
        error
        | details:
            details |> Map.put(:outcomes, outcomes) |> Map.put(:path, first_path || prefixed_path)
      }
    else
      error
    end
  end

  defp prefix_nested_rule_error(error, _row_path), do: error

  defp invalid_nested_entry(path),
    do: {:error, graph_error("nested relationship items must be maps", path, %{})}

  defp validate_nested_entry(entry, _path) when is_map(entry), do: :ok
  defp validate_nested_entry(_entry, path), do: invalid_nested_entry(path)
end
