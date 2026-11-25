defmodule Selecto.Write.SharedContract do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M

  def errors(domain) do
    writes = M.map_value(domain, :writes) || %{}
    source = M.map_value(domain, :source)

    Enum.flat_map([:row_revision, :host_bound_fields, :unique_keys], fn key ->
      case M.fetch_key(writes, key) do
        :error ->
          []

        {:ok, value} ->
          if valid?(key, value, source),
            do: [],
            else: [
              %{
                code: :invalid_domain,
                path: [:writes, key],
                message: "invalid shared write declaration #{key}"
              }
            ]
      end
    end)
  end

  defp physical?(source, field) do
    col = Selecto.ComputedOwnerKeys.column(source, field)
    (is_atom(field) or is_binary(field)) and is_map(col) and is_nil(M.map_value(col, :computed))
  end

  defp keys?(map, keys), do: is_map(map) and Enum.all?(Map.keys(map), &(to_string(&1) in keys))

  defp valid?(:row_revision, spec, source) when is_map(spec) do
    column = M.map_value(spec, :column)
    columns = M.map_value(spec, :columns)
    required = M.map_value(spec, :required)
    fields = if is_nil(column), do: columns, else: [column]

    keys?(spec, ~w(column columns required)) and
      is_nil(column) != is_nil(columns) and is_list(fields) and length(fields) in 1..32 and
      length(Enum.uniq_by(fields, &to_string/1)) == length(fields) and
      Enum.all?(fields, &physical?(source, &1)) and
      (not match?({:ok, _}, M.fetch_key(spec, :required)) or
         required in [true, false, 0, 1, "0", "1"])
  end

  defp valid?(:host_bound_fields, fields, source) when is_map(fields) do
    Enum.all?(fields, fn {field, spec} ->
      mode = M.map_value(spec, :mode) |> to_string()
      context = M.map_value(spec, :source)

      physical?(source, field) and keys?(spec, ~w(mode source)) and
        case mode do
          clock when clock in ~w(created_at modified_at) ->
            is_nil(context) and
              Selecto.Temporal.date_like?(Selecto.ComputedOwnerKeys.column(source, field))

          binding when binding in ~w(owner created_by modified_by) ->
            case context do
              [kind, key] when kind in [:context, "context"] ->
                is_binary(key) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key)

              _ ->
                false
            end

          _ ->
            false
        end
    end)
  end

  defp valid?(:unique_keys, keys, source) when is_map(keys) do
    Enum.all?(keys, fn {name, fields} ->
      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, to_string(name)) and is_list(fields) and
        length(fields) in 1..16 and
        length(Enum.uniq_by(fields, &to_string/1)) == length(fields) and
        Enum.all?(fields, &physical?(source, &1))
    end)
  end

  defp valid?(_, _, _), do: false

  def preflight(operation, backend) do
    writes = M.map_value(operation.domain, :writes) || %{}

    declarations =
      Enum.filter([:row_revision, :host_bound_fields], &match?({:ok, _}, M.fetch_key(writes, &1)))

    cond do
      declarations != [] and backend == :duckdb ->
        error(:write_capability_missing, "adapter refuses shared governed write declarations", %{
          missing: declarations
        })

      :row_revision in declarations and backend in [:mysql, :mariadb] ->
        error(:unsupported_feature, "adapter does not expose protected revision reads", %{
          unsupported_feature: :row_revision
        })

      declarations != [] and backend not in [nil, :postgresql, :sqlite, :mysql, :mariadb] ->
        error(:unsupported_feature, "adapter does not implement shared governed writes", %{
          unsupported_feature: hd(declarations)
        })

      match?({:ok, _}, M.fetch_key(writes, :host_bound_fields)) and operation.type == :upsert ->
        error(:host_bound_upsert_unsupported, "upserts with host-bound fields are unsupported")

      true ->
        bindings = M.map_value(writes, :host_bound_fields) || %{}
        values = operation.attrs || operation.changes || %{}

        if is_map(values) and
             Enum.any?(Map.keys(values), &match?({:ok, _}, M.fetch_key(bindings, &1))),
           do: error(:host_bound_field, "caller assignments cannot target host-bound fields"),
           else: :ok
    end
  end

  def error(code, message, details \\ %{}),
    do: {:error, SelectoUpdato.Error.new(code, message, details: Map.put(details, :code, code))}
end
