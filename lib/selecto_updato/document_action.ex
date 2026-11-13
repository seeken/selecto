defmodule SelectoUpdato.DocumentAction do
  @moduledoc """
  Compiles authored document actions through the ordinary Updato action boundary.

  `execution.document` binds an approved ShapeRelease and server-authored paths.
  Mutated root fields must explicitly list the action in
  `writes.fields.<id>.document_actions`; ordinary assignment permission is
  independent. Trusted tenant identity is bound
  only after the usual caller authorization and scope checks have succeeded.
  """

  alias Selecto.Document.ShapeRelease
  alias Selecto.Write.DocumentMutation
  alias SelectoUpdato.{ActionPlan, Error, Operation}

  @doc false
  def attach(%ActionPlan{execution: execution} = plan) do
    case value(execution, :document) do
      nil -> {:ok, plan}
      spec when is_map(spec) -> attach_document(plan, spec)
      _ -> invalid(:invalid_document_action)
    end
  end

  @doc false
  def compile(%Operation{action_policy: %{document: document}}, command, context) do
    tenant = context[:tenant_id]

    if (is_binary(tenant) or is_integer(tenant)) and tenant != "" do
      mutation =
        struct!(
          DocumentMutation,
          Map.put(document, :tenant, %{path: document.tenant.path, value: tenant})
        )

      scope_digest = DocumentMutation.digest({mutation.tenant, mutation.identity})
      mutation = %{mutation | scope_digest: scope_digest}

      mutation = %{
        mutation
        | payload_digest:
            DocumentMutation.digest(%{
              mutation: payload_mutation(mutation),
              relation: command.relation,
              predicate: command.predicate,
              expected_cardinality: command.expected_cardinality,
              returning: command.returning,
              domain_fingerprint: command.metadata[:domain_fingerprint]
            })
      }

      with :ok <- DocumentMutation.validate(mutation) do
        {:ok, %{command | metadata: Map.put(command.metadata, :document, mutation)}}
      end
    else
      invalid(:missing_trusted_document_tenant)
    end
  end

  def compile(_operation, command, _context), do: {:ok, command}

  # Empty additive feature metadata must preserve the original persisted
  # idempotency hash, including the struct marker in its external-term encoding.
  defp payload_mutation(mutation) do
    normalized = %{mutation | payload_digest: "", idempotency_key: ""}

    if mutation.shape_features == [],
      do: Map.delete(normalized, :shape_features),
      else: normalized
  end

  defp attach_document(%ActionPlan{operation_builder: %Operation{} = operation} = plan, spec) do
    release = value(spec, :shape_release)
    relation = value(spec, :relation)

    with :ok <- approved_release(release),
         {:ok, %{"kind" => "root"}} <- ShapeRelease.relation(release, relation),
         true <-
           plan.operation == "update" and plan.changes == %{} and
             plan.collection_operations == %{} and plan.expected_cardinality == {:exactly, 1},
         true <- is_binary(plan.capability) and plan.capability != "",
         {:ok, identity} <- target_identity(plan, operation, release),
         :ok <- validate_scope(operation, release),
         {:ok, mutations} <-
           resolve_mutations(spec, plan, operation, release, relation),
         {:ok, expected} <- input(plan.inputs, value(spec, :expected_version_from)),
         {:ok, key} <- input(plan.inputs, value(spec, :idempotency_key_from)),
         document <- %{
           identity: identity,
           tenant: %{path: release["source"]["tenant_path"], value: "pending-authorized-context"},
           version: %{path: release["source"]["version_path"], expected: expected},
           action: plan.action,
           shape_version: release["id"],
           shape_digest: release["digest"],
           shape_features: ShapeRelease.features(release),
           mutations: mutations,
           effects: value(spec, :effects),
           idempotency_key: key,
           payload_digest: String.duplicate("0", 64),
           scope_digest: String.duplicate("0", 64)
         },
         :ok <- DocumentMutation.validate(struct!(DocumentMutation, document)) do
      policy = Map.put(operation.action_policy, :document, document)
      {:ok, %{plan | operation_builder: %{operation | action_policy: policy}}}
    else
      {:error, _} = error -> error
      _ -> invalid(:invalid_document_action_contract)
    end
  end

  defp attach_document(_plan, _spec), do: invalid(:document_action_requires_domain)

  defp approved_release(release) do
    case ShapeRelease.validate(release, require_approved: true) do
      :ok -> :ok
      _ -> invalid(:document_release_not_approved)
    end
  end

  defp target_identity(plan, operation, release) do
    source = value(operation.domain, :source, %{})
    primary_key = value(source, :primary_key)
    shape_field = Map.get(release["shape"]["fields"], to_string(primary_key))
    target = if is_map(plan.target), do: value(plan.target, primary_key)

    if is_map(shape_field) and shape_field["path"] == release["source"]["identity_path"] and
         value(source, :source_table) == release["source"]["collection"] and
         identity_value?(shape_field["type"], target) do
      {:ok, %{path: shape_field["path"], value: target}}
    else
      invalid(:document_identity_mismatch)
    end
  end

  defp validate_scope(operation, release) do
    writes = value(operation.domain, :writes, %{})
    scope = value(writes, :scope, value(writes, :scopes, %{}))
    tenant = value(scope, :tenant, %{})
    field = Map.get(release["shape"]["fields"], to_string(value(tenant, :field)))

    if is_map(field) and field["path"] == release["source"]["tenant_path"] and
         value(tenant, :required) == true, do: :ok, else: invalid(:document_scope_mismatch)
  end

  defp resolve_mutations(spec, plan, operation, release, root) do
    case value(spec, :mutations) do
      mutations when is_list(mutations) and mutations != [] ->
        if Enum.all?(mutations, &(value(&1, :op) in [:set, :unset, "set", "unset"])) do
          SelectoUpdato.DocumentRootPatch.resolve(spec, plan, operation, release, root)
        else
          with [mutation] when is_map(mutation) <- mutations,
               {:ok, resolved} <- resolve_element(mutation, plan.inputs),
               :ok <- validate_shape_mutations(operation, plan.action, release, root, resolved) do
            {:ok, resolved}
          else
            {:error, _} = error -> error
            _ -> invalid(:unsupported_document_mutations)
          end
        end

      _ ->
        invalid(:unsupported_document_mutations)
    end
  end

  defp resolve_element(mutation, inputs) do
    identity = value(mutation, :identity, %{})

    with true <- value(mutation, :op) in [:update_element, "update_element"],
         [patch] when is_map(patch) <- value(mutation, :patch),
         true <- value(patch, :op) in [:increment, "increment"],
         {:ok, identity_value} <- input(inputs, value(identity, :value_from)),
         {:ok, amount} <- input(inputs, value(patch, :value_from)) do
      {:ok,
       [
         %{
           op: :update_element,
           path: value(mutation, :path),
           identity: %{path: value(identity, :path), value: identity_value},
           patch: [%{op: :increment, path: value(patch, :path), value: amount}]
         }
       ]}
    else
      _ -> invalid(:unsupported_document_mutations)
    end
  end

  defp validate_shape_mutations(operation, action, release, root, [mutation]) do
    child =
      Enum.find_value(release["relations"], fn {_id, relation} ->
        if relation["kind"] == "array" and relation["parent"] == root and
             relation["path"] == mutation.path,
           do: relation
      end)

    [patch] = mutation.patch

    root_field =
      Enum.find_value(release["shape"]["fields"], fn {id, field} ->
        if field["path"] == mutation.path, do: id
      end)

    writes = value(operation.domain, :writes, %{})
    field_policy = value(value(writes, :fields, %{}), root_field, %{})
    allowed_actions = value(field_policy, :document_actions, [])

    with true <- is_map(child) and child["identity_path"] == mutation.identity.path,
         identity_field when is_map(identity_field) <-
           Enum.find_value(child["fields"], fn {_id, field} ->
             if field["path"] == mutation.identity.path, do: field
           end),
         true <- identity_value?(identity_field["type"], mutation.identity.value),
         true <-
           is_list(allowed_actions) and Enum.any?(allowed_actions, &(to_string(&1) == action)),
         field when is_map(field) <-
           Enum.find_value(child["fields"], fn {_id, field} ->
             if field["path"] == patch.path, do: field
           end),
         true <-
           field["type"] == "integer" and field["required"] == true and
             field["nullable"] == false and field["server_managed"] != true,
         false <- protected_root?(release, mutation.path) do
      :ok
    else
      _ -> invalid(:forbidden_document_path)
    end
  end

  defp identity_value?("object_id", value), do: Selecto.Document.ObjectId.valid?(value)
  defp identity_value?("string", value), do: is_binary(value) and value != ""
  defp identity_value?("integer", value), do: is_integer(value)
  defp identity_value?(_type, _value), do: false

  defp protected_root?(release, path) do
    protected = [
      release["shape"]["variants"]["path"]
      | Enum.flat_map(release["shape"]["fields"], fn {_id, field} ->
          if field["server_managed"] == true, do: [field["path"]], else: []
        end)
    ]

    Enum.any?(protected, &(Enum.take(path, length(&1)) == &1))
  end

  defp input(inputs, key) when is_atom(key) or is_binary(key) do
    case Map.fetch(inputs, to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> invalid(:missing_document_action_input)
    end
  end

  defp input(_, _), do: invalid(:missing_document_action_input)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, default, fn {candidate, value} ->
          if to_string(candidate) == to_string(key), do: {:found, value}
        end)
        |> case do
          {:found, value} -> value
          value -> value
        end
    end
  end

  defp value(_, _, default), do: default

  defp invalid(code),
    do:
      {:error,
       Error.new(:invalid_operation, "Document action does not satisfy its governed contract",
         details: %{code: code}
       )}
end
