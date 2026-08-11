defmodule Selecto.Write.AdapterConformance do
  @moduledoc """
  Reusable, non-mutating conformance checks for write-capable Selecto adapters.

  This module supplies canonical commands for all portable operations and
  verifies the adapter's capability and preview callback shapes. Adapter
  packages should run it in their own test suite, then add dialect-specific
  integration tests for execution and transactional rollback.

  Conformance does not grant write capability and does not execute a command.
  An adapter remains read-only unless it explicitly implements
  `Selecto.DB.WriteAdapter`.
  """

  alias Selecto.Write
  alias Selecto.Write.{Batch, Command, Error, Preview}

  @operations [:insert, :update, :upsert, :delete]

  @spec check(Selecto.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def check(%Selecto{} = selecto, opts \\ []) do
    relation = Keyword.get(opts, :relation, :selecto_write_conformance)
    context = Keyword.get(opts, :context, %{tenant_id: "tenant-conformance"})
    commands = fixture_commands(relation)

    with {:ok, capabilities} <- Write.capabilities(selecto),
         :ok <- validate_capabilities(capabilities),
         {:ok, previews} <- preview_commands(selecto, commands, context),
         {:ok, batch} <- Batch.new(Enum.map(@operations, &Map.fetch!(commands, &1))),
         {:ok, batch_preview} <- Write.preview(selecto, batch, context: context),
         :ok <- validate_preview(batch_preview, :atomic_batch) do
      {:ok,
       %{
         adapter: selecto.adapter,
         operations: @operations,
         capabilities: capabilities,
         previews: previews,
         batch_preview: batch_preview
       }}
    end
  end

  @doc """
  Returns canonical commands for the four portable write operations.
  """
  @spec fixture_commands(atom() | String.t()) :: %{required(atom()) => Command.t()}
  def fixture_commands(relation \\ :selecto_write_conformance) do
    %{
      insert:
        command!(%{
          operation: :insert,
          relation: relation,
          assignments: [
            %{field: :external_id, value: {:literal, "insert-conformance"}},
            %{field: :tenant_id, value: {:context, :tenant_id}}
          ]
        }),
      update:
        command!(%{
          operation: :update,
          relation: relation,
          assignments: [%{field: :name, value: {:literal, "updated-conformance"}}],
          predicate: tenant_predicate()
        }),
      upsert:
        command!(%{
          operation: :upsert,
          relation: relation,
          assignments: [
            %{field: :external_id, value: {:literal, "upsert-conformance"}},
            %{field: :tenant_id, value: {:context, :tenant_id}},
            %{field: :name, value: {:literal, "upserted-conformance"}}
          ],
          metadata: %{
            conflict_target: [:tenant_id, :external_id],
            upsert_update_fields: [:name]
          }
        }),
      delete:
        command!(%{
          operation: :delete,
          relation: relation,
          predicate: tenant_predicate()
        })
    }
  end

  defp tenant_predicate,
    do: {:eq, {:field, :tenant_id}, {:context, :tenant_id}}

  defp command!(attrs) do
    {:ok, command} = Command.new(attrs)
    command
  end

  defp validate_capabilities(capabilities) when is_map(capabilities) do
    missing = Enum.reject(@operations, &(Map.get(capabilities, &1) == true))

    cond do
      missing != [] ->
        {:error,
         Error.new(
           :adapter_conformance_failed,
           "adapter does not advertise every portable operation",
           details: %{missing_capabilities: missing}
         )}

      Map.get(capabilities, :atomic_batch) != true ->
        {:error,
         Error.new(:adapter_conformance_failed, "adapter must advertise atomic batch execution")}

      Map.get(capabilities, :transactions) != true ->
        {:error,
         Error.new(:adapter_conformance_failed, "adapter must advertise transactional writes")}

      true ->
        :ok
    end
  end

  defp validate_capabilities(other) do
    {:error,
     Error.new(:adapter_conformance_failed, "write capabilities must be a map",
       details: %{actual: other}
     )}
  end

  defp preview_commands(selecto, commands, context) do
    Enum.reduce_while(@operations, {:ok, %{}}, fn operation, {:ok, previews} ->
      case Write.preview(selecto, Map.fetch!(commands, operation), context: context) do
        {:ok, preview} ->
          case validate_preview(preview, operation) do
            :ok -> {:cont, {:ok, Map.put(previews, operation, preview)}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_preview(%Preview{statements: statements}, operation)
       when is_list(statements) and statements != [] do
    if Enum.all?(statements, &valid_statement?/1) do
      :ok
    else
      invalid_preview(operation, statements)
    end
  end

  defp validate_preview(other, operation), do: invalid_preview(operation, other)

  defp valid_statement?(%{text: text, params: params})
       when is_binary(text) and is_list(params),
       do: String.trim(text) != ""

  defp valid_statement?(_statement), do: false

  defp invalid_preview(operation, actual) do
    {:error,
     Error.new(:adapter_conformance_failed, "adapter returned an invalid write preview",
       details: %{operation: operation, actual: actual}
     )}
  end
end
