defmodule Selecto.RowRevision do
  @moduledoc "Opaque identity-bound revision tokens from the same statement as the public rows."
  alias Selecto.Domain.Contract.Shared.Core, as: M
  alias Selecto.Write.SharedContract

  def declaration(%Selecto{domain: domain}), do: declaration(domain)
  def declaration(domain), do: domain |> M.map_value(:writes) |> M.map_value(:row_revision)

  def fields(spec) do
    case M.map_value(spec, :column) do
      nil -> Enum.map(M.map_value(spec, :columns), &to_string/1)
      field -> [to_string(field)]
    end
  end

  def read(query, opts, execute) do
    spec = declaration(query)

    if is_map(spec) and query.set.group_by == [] and
         not Selecto.Builder.SetOperations.has_set_operations?(query) and query.set.selected != [] and
         not Enum.any?(query.set.selected, &aggregate?/1) do
      if Keyword.get(opts, :format, :raw) != :raw do
        {:error,
         Selecto.Error.validation_error("revision metadata requires raw rows", %{
           code: :invalid_query
         })}
      else
        key = to_string(query.domain.source.primary_key)
        stored = Enum.uniq([key | fields(spec)])

        additions =
          Enum.with_index(stored, fn field, index ->
            {:field, {:revision_storage, field}, "__selecto_revision_#{index}"}
          end)

        augmented = put_in(query.set.selected, query.set.selected ++ additions)

        case execute.(augmented, opts) do
          {:ok, {rows, columns, aliases}, metadata} ->
            count = length(stored)

            {rows, tokens} =
              Enum.map(rows, fn row ->
                {visible, hidden} = Enum.split(row, length(row) - count)
                values = Map.new(Enum.zip(stored, hidden))
                {visible, token(query.domain, query.adapter, values)}
              end)
              |> Enum.unzip()

            {:ok, {rows, Enum.drop(columns, -count), Enum.drop(aliases, -count)},
             Map.put(metadata, :row_revisions, tokens)}

          error ->
            error
        end
      end
    else
      execute.(query, opts)
    end
  end

  # Adding identity columns would change aggregate grain or DISTINCT semantics.
  # Revision metadata is only meaningful for root detail rows.
  defp aggregate?(value) when is_tuple(value) do
    parts = Tuple.to_list(value)
    head = hd(parts)

    head in [
      :count,
      :count_distinct,
      :sum,
      :avg,
      :min,
      :max,
      :stddev,
      :variance,
      :ratio_of_sums,
      :distinct
    ] or Enum.any?(tl(parts), &aggregate?/1)
  end

  defp aggregate?(value) when is_list(value), do: Enum.any?(value, &aggregate?/1)
  defp aggregate?(_), do: false

  def token(domain, adapter, values) do
    source = M.map_value(domain, :source)
    key = to_string(M.map_value(source, :primary_key))
    spec = declaration(domain)

    identity =
      M.map_value(domain, :domain_fingerprint) ||
        {M.map_value(domain, :name), M.map_value(source, :source_table),
         M.map_value(domain, :domain_version)}

    payload =
      {"selecto.row_revision.v1", backend_name(adapter), identity, key,
       canonical(get(values, key)), Enum.map(fields(spec), &{&1, canonical(get(values, &1))})}

    "sr1_" <>
      Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(payload)), padding: false)
  end

  def needs_protection?(operation),
    do: operation.type in [:update, :delete] and is_map(declaration(operation.domain))

  def check(operation, contract, predicate, context, opts) do
    spec = contract.row_revision
    revision = operation.row_revision
    required = is_map(spec) and M.map_value(spec, :required) in [true, 1, "1"]

    cond do
      not is_map(spec) or operation.type not in [:update, :delete] ->
        {:ok, predicate}

      is_nil(revision) and required ->
        SharedContract.error(:row_revision_required, "a row revision token is required")

      is_nil(revision) ->
        {:ok, predicate}

      not is_binary(revision) ->
        SharedContract.error(:stale_revision, "row revision is stale or invalid")

      true ->
        protected_check(operation, contract, predicate, context, opts)
    end
  end

  defp protected_check(operation, contract, predicate, context, opts) do
    key = to_string(M.map_value(contract.source, :primary_key))
    provider = Keyword.get(opts, :record_state_provider)

    cond do
      not identity_bound?(predicate, key) ->
        SharedContract.error(
          :row_revision_identity_required,
          "revision writes require one literal root identity"
        )

      not is_function(provider, 1) ->
        SharedContract.error(
          :unsupported_feature,
          "revision writes require adapter-protected record state",
          %{unsupported_feature: :row_revision}
        )

      true ->
        request = %Selecto.Write.RecordRequest{
          operation: :update,
          relation: M.map_value(contract.source, :source_table),
          predicate: predicate,
          context: context,
          fields: Enum.uniq([key | fields(contract.row_revision)])
        }

        case provider.(request) do
          {:ok,
           %Selecto.Write.RecordState{
             complete?: true,
             exists?: true,
             protection: protection,
             values: values
           }}
          when protection in [:locked, :serializable] ->
            adapter = Keyword.get(opts, :storage_backend)
            expected = token(operation.domain, adapter_module(adapter), values)

            if secure_equal?(expected, operation.row_revision) do
              guards =
                Enum.map(fields(contract.row_revision), fn field ->
                  case get(values, field) do
                    nil -> {:is_null, {:field, field}}
                    value -> {:eq, {:field, field}, {:literal, value}}
                  end
                end)

              {:ok, {:and, [predicate | guards]}}
            else
              SharedContract.error(:stale_revision, "row revision is stale")
            end

          {:error, %{type: :cardinality_mismatch}} ->
            SharedContract.error(:stale_revision, "revision target is missing")

          {:error, error} ->
            {:error, error}

          _ ->
            SharedContract.error(:unsupported_feature, "record state was not protected", %{
              unsupported_feature: :row_revision
            })
        end
    end
  end

  # Backends are data in compile options; an atom is accepted directly by the
  # token helper, avoiding any import-time adapter discovery or registry.
  defp backend_name(backend) when backend in [:postgresql, :sqlite, :duckdb, :mysql, :mariadb],
    do: backend

  defp backend_name(adapter), do: Selecto.AdapterSupport.adapter_name(adapter)

  defp adapter_module(backend), do: backend

  defp identity_bound?({:eq, {:field, field}, {:literal, value}}, key),
    do: to_string(field) == key and not is_nil(value)

  defp identity_bound?({:and, parts}, key), do: Enum.any?(parts, &identity_bound?(&1, key))
  defp identity_bound?(_, _), do: false

  defp get(map, key) do
    case M.fetch_key(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp canonical(%DateTime{} = value), do: {:instant, DateTime.to_unix(value, :microsecond)}
  defp canonical(%NaiveDateTime{} = value), do: {:datetime, NaiveDateTime.to_iso8601(value)}
  defp canonical(%Date{} = value), do: {:date, Date.to_iso8601(value)}

  defp canonical(value) when is_map(value),
    do: value |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end) == 0
  end

  defp secure_equal?(_, _), do: false
end
