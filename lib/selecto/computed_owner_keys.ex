defmodule Selecto.ComputedOwnerKeys do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M
  alias Selecto.Domain.Contract.ComputedValues, as: Values

  def errors(domain) do
    source = M.map_value(domain, :source)
    schemas = M.map_value(domain, :schemas) || %{}

    relation_errors(source, [:source]) ++
      Enum.flat_map(schemas, fn {id, relation} -> relation_errors(relation, [:schemas, id]) end) ++
      write_errors(domain)
  end

  defp relation_errors(relation, path) do
    associations = M.map_value(relation, :associations) || %{}

    if is_map(associations) do
      Enum.flat_map(associations, fn {id, association} ->
        key = M.map_value(association, :owner_key)

        case column(relation, key) do
          %{computed: _} = col ->
            validate(relation, col, path ++ [:associations, id, :owner_key])

          %{"computed" => _} = col ->
            validate(relation, col, path ++ [:associations, id, :owner_key])

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp validate(relation, column, path) do
    computed = M.map_value(column, :computed)
    expression = M.map_value(computed, :expression)

    result =
      with kind when kind in [:expression, "expression"] <- M.map_value(computed, :kind),
           {:ok, ["case" | branches] = normalized, deps} <- Values.validate(expression),
           true <-
             Enum.all?(branches, fn [_condition, result] -> match?(["field", _], result) end),
           true <-
             Enum.all?(deps, fn field ->
               col = column(relation, field)

               not String.contains?(field, ".") and is_map(col) and
                 is_nil(M.map_value(col, :computed)) and
                 M.map_value(col, :redacted) not in [true, 1, "1"] and
                 field not in Enum.map(M.map_value(relation, :redact_fields) || [], &to_string/1)
             end),
           {:ok, type} <- Values.infer(normalized, &M.map_value(column(relation, &1), :type)),
           true <- Values.compatible?(M.map_value(column, :type), type) do
        :ok
      else
        _ -> :invalid
      end

    if result == :ok,
      do: [],
      else: [
        %{
          code: :invalid_domain,
          path: path,
          message:
            "computed owner keys require a local CASE over physical unredacted columns with matching types"
        }
      ]
  end

  defp write_errors(domain) do
    source = M.map_value(domain, :source)
    relationships = domain |> M.map_value(:writes) |> M.map_value(:relationships) || %{}

    if is_map(relationships) do
      Enum.flat_map(relationships, fn {id, spec} ->
        association = M.map_value(source, :associations) |> M.fetch_key(id)

        case association do
          {:ok, association} ->
            key = M.map_value(association, :owner_key)

            if M.map_value(spec, :writable) in [true, 1, "1"] and
                 not is_nil(M.map_value(column(source, key), :computed)),
               do: [
                 %{
                   code: :computed_owner_key_read_only,
                   path: [:writes, :relationships, id],
                   message: "relationships through computed owner keys are read-only"
                 }
               ],
               else: []

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  def column(relation, key) do
    case M.fetch_key(M.map_value(relation, :columns), key) do
      {:ok, column} -> column
      _ -> nil
    end
  end
end
