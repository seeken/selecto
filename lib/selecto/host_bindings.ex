defmodule Selecto.HostBindings do
  @moduledoc "Trusted owner/audit bindings for governed writes; authored metadata remains immutable."
  alias Selecto.Domain.Contract.Shared.Core, as: M
  alias Selecto.Write.SharedContract

  def fields(%Selecto{domain: domain}), do: fields(domain)
  def fields(domain), do: domain |> M.map_value(:writes) |> M.map_value(:host_bound_fields) || %{}
  def readonly?(domain, field), do: match?({:ok, _}, M.fetch_key(fields(domain), field))

  @doc false
  def discovery_source(source, domain) when is_map(source) do
    columns = M.map_value(source, :columns) || %{}

    columns =
      Map.new(columns, fn {field, column} ->
        {field, if(readonly?(domain, field), do: Map.put(column, :read_only, true), else: column)}
      end)

    Selecto.Domain.Shared.Map.put_map_value(source, :columns, columns)
  end

  def discovery_source(source, _domain), do: source

  def prepare(operation, contract, context) do
    Enum.reduce_while(contract.host_bound_fields, {:ok, operation, contract}, fn {field, spec},
                                                                                 {:ok, op,
                                                                                  compiled} ->
      field = to_string(field)
      mode = M.map_value(spec, :mode) |> to_string()
      applies = op.type == :insert or (op.type == :update and mode == "modified_by")

      if mode in ~w(created_at modified_at) do
        # The database resolves these values after literal validators. They satisfy
        # required-field admission, but cannot satisfy a pending value validator.
        fields =
          Map.update(
            compiled.fields,
            field,
            %{},
            &(&1 |> Map.put(:required, false) |> Map.put(:required_on, []))
          )

        {:cont, {:ok, op, %{compiled | fields: fields}}}
      else
        if applies or (mode == "owner" and op.type in [:update, :delete]) do
          [_kind, key] = M.map_value(spec, :source)

          case M.fetch_key(context, key) do
            {:ok, value} when (is_binary(value) and byte_size(value) > 0) or is_number(value) ->
              op = if applies, do: put_value(op, field, value), else: op

              op =
                if mode == "owner" do
                  pin = {field, value}

                  opts =
                    Keyword.update(
                      op.opts || [],
                      :trusted_required_filters,
                      [pin],
                      &Enum.uniq(&1 ++ [pin])
                    )

                  filters =
                    if op.type in [:update, :delete],
                      do: (op.filters || []) ++ [pin],
                      else: op.filters

                  %{op | filters: filters, opts: opts}
                else
                  op
                end

              fields =
                Map.update(
                  compiled.fields,
                  field,
                  %{insertable: true, updatable: mode == "modified_by"},
                  &Map.merge(&1, %{insertable: true, updatable: mode == "modified_by"})
                )

              {:cont, {:ok, op, %{compiled | fields: fields}}}

            _ ->
              {:halt,
               SharedContract.error(
                 :missing_host_context,
                 "required trusted host binding is missing",
                 %{field: field}
               )}
          end
        else
          {:cont, {:ok, op, compiled}}
        end
      end
    end)
  end

  def augment(command, operation, contract) do
    clocks =
      Enum.filter(contract.host_bound_fields, fn {_field, spec} ->
        mode = M.map_value(spec, :mode) |> to_string()

        (operation.type == :insert and mode in ~w(created_at modified_at)) or
          (operation.type == :update and mode == "modified_at")
      end)

    pending =
      Enum.any?(clocks, fn {field, _} ->
        spec = Map.get(contract.fields, to_string(field), %{})

        Enum.any?([:validate, :validators, :validation], fn key ->
          M.map_value(spec, key) not in [nil, []]
        end)
      end)

    if pending do
      SharedContract.error(
        :required_data_rule_pending,
        "database timestamps cannot satisfy literal validators before storage"
      )
    else
      additions =
        Enum.map(clocks, fn {field, _} ->
          %{field: to_string(field), value: {:literal, {:system, :now}}}
        end)

      {:ok,
       %{
         command
         | assignments: command.assignments ++ additions,
           metadata: Map.put(command.metadata, :unique_keys, contract.unique_keys)
       }}
    end
  end

  defp put_value(%{type: :insert} = operation, field, value),
    do: %{operation | attrs: Map.put(operation.attrs || %{}, field, value)}

  defp put_value(%{type: :update} = operation, field, value),
    do: %{operation | changes: Map.put(operation.changes || %{}, field, value)}
end
