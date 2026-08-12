defmodule Selecto.Verification.WriteRegistrySafety do
  @moduledoc """
  Bounded verification of normalized write-registry identifier safety.

  The model crosses both canonical authority registries, atom/string key
  spellings, and conflicting boolean authority values. It proves that an
  atom/string collision always fails closed at validation and compilation,
  while every unambiguous spelling remains accepted.
  """

  alias Selecto.Domain
  alias Selecto.Domain.WriteContract
  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.Error

  @doc "Runs the built-in normalized write-registry collision model."
  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto.write_registry_identifier_safety.v1", states(), invariants())
  end

  defp states do
    for registry <- [:operations, :fields],
        key_shape <- [:atom, :string, :atom_string_collision],
        atom_authority? <- [false, true],
        string_authority? <- [false, true] do
      dimensions = %{
        registry: registry,
        key_shape: key_shape,
        atom_authority?: atom_authority?,
        string_authority?: string_authority?,
        collision?: key_shape == :atom_string_collision,
        expected_code: duplicate_code(registry)
      }

      domain = domain(dimensions)
      {:ok, normalized, _diagnostics} = Domain.normalize(domain)

      dimensions
      |> Map.put(:validation, Domain.validate(domain))
      |> Map.put(:authored_compilation, WriteContract.compile(domain))
      |> Map.put(:normalized_compilation, WriteContract.compile(normalized))
    end
  end

  defp invariants do
    [
      {"normalized_collisions_fail_closed", &normalized_collisions_fail_closed/1},
      {"unambiguous_registry_ids_remain_accepted", &unambiguous_registry_ids_remain_accepted/1}
    ]
  end

  defp normalized_collisions_fail_closed(%{collision?: false}), do: :ok

  defp normalized_collisions_fail_closed(state) do
    expected_code = state.expected_code

    validation_code? =
      match?(
        {:error, %{errors: errors}}
        when is_list(errors),
        state.validation
      ) and diagnostic_code?(state.validation, state.expected_code)

    authored_code? =
      match?(
        {:error, %Error{type: :invalid_domain, details: %{errors: errors}}}
        when is_list(errors),
        state.authored_compilation
      ) and compilation_diagnostic_code?(state.authored_compilation, state.expected_code)

    normalized_code? =
      match?(
        {:error,
         %Error{
           type: :invalid_domain,
           details: %{code: ^expected_code, normalized_id: normalized_id, authored_ids: [_, _]}
         }}
        when is_binary(normalized_id),
        state.normalized_compilation
      )

    if validation_code? and authored_code? and normalized_code? do
      :ok
    else
      {:error,
       %{
         expected_code: state.expected_code,
         validation: state.validation,
         authored_compilation: state.authored_compilation,
         normalized_compilation: state.normalized_compilation
       }}
    end
  end

  defp unambiguous_registry_ids_remain_accepted(%{collision?: true}), do: :ok

  defp unambiguous_registry_ids_remain_accepted(state) do
    if match?({:ok, _normalized, _diagnostics}, state.validation) and
         match?({:ok, %WriteContract{}}, state.authored_compilation) and
         match?({:ok, %WriteContract{}}, state.normalized_compilation) do
      :ok
    else
      {:error,
       %{
         validation: state.validation,
         authored_compilation: state.authored_compilation,
         normalized_compilation: state.normalized_compilation
       }}
    end
  end

  defp diagnostic_code?({:error, %{errors: errors}}, code),
    do: Enum.any?(errors, &(Map.get(&1, :code) == code))

  defp compilation_diagnostic_code?(
         {:error, %Error{details: %{errors: errors}}},
         code
       ),
       do: Enum.any?(errors, &(Map.get(&1, :code) == code))

  defp domain(state) do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :status],
        columns: %{id: %{type: :integer}, status: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: operation_registry(state),
        fields: field_registry(state)
      }
    }
  end

  defp operation_registry(%{registry: :operations} = state) do
    Map.merge(%{insert: %{enabled: true}}, registry_entries(state, :update, "update", :enabled))
  end

  defp operation_registry(_state), do: %{update: %{enabled: true}}

  defp field_registry(%{registry: :fields} = state) do
    Map.merge(%{id: %{insertable: true}}, registry_entries(state, :status, "status", :updatable))
  end

  defp field_registry(_state), do: %{status: %{updatable: true}}

  defp registry_entries(state, atom_id, string_id, authority_key) do
    atom_spec = %{authority_key => state.atom_authority?}
    string_spec = %{authority_key => state.string_authority?}

    case state.key_shape do
      :atom -> %{atom_id => atom_spec}
      :string -> %{string_id => string_spec}
      :atom_string_collision -> %{string_id => string_spec, atom_id => atom_spec}
    end
  end

  defp duplicate_code(:operations), do: :duplicate_write_operation_id
  defp duplicate_code(:fields), do: :duplicate_write_field_id
end
