defmodule SelectoUpdato.CandidateState do
  @moduledoc """
  Typed host boundary for hydrating a complete nested collection candidate.

  The provider is configured by trusted host code at the governed execution
  boundary. It returns prior rows only; this module applies the submitted delta
  so callers cannot claim that a partial collection is complete.
  """

  alias SelectoUpdato.Error

  @max_rows 1_000
  @protections [:snapshot, :locked, :serializable, :native_constraint]

  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @spec complete([map()], keyword()) :: Selecto.Write.CandidateState.t()
  def complete(rows, opts \\ []) when is_list(rows) and is_list(opts) do
    %Selecto.Write.CandidateState{
      rows: rows,
      complete?: true,
      protection: Keyword.get(opts, :protection, :snapshot),
      revision: Keyword.get(opts, :revision)
    }
  end

  @spec materialize(
          (Selecto.Write.CandidateRequest.t() -> term()) | nil,
          Selecto.Write.CandidateRequest.t(),
          [map()]
        ) :: {:ok, [map()], Selecto.Write.CandidateState.t()} | {:error, Error.t()}
  def materialize(nil, %Selecto.Write.CandidateRequest{} = request, _entries),
    do: pending(request)

  def materialize(provider, %Selecto.Write.CandidateRequest{} = request, entries)
      when is_function(provider, 1) do
    with {:ok, state} <- call_provider(provider, request),
         :ok <- validate_state(state, request),
         {:ok, rows} <- normalize_rows(state.rows, request),
         {:ok, candidate} <- apply_entries(rows, entries, request),
         :ok <- validate_bound(candidate, request) do
      {:ok, candidate, state}
    end
  end

  defp call_provider(provider, request) do
    case provider.(request) do
      {:ok, %Selecto.Write.CandidateState{} = state} -> {:ok, state}
      {:error, _reason} -> unavailable(request)
      _other -> invalid_state(request)
    end
  rescue
    _exception -> unavailable(request)
  catch
    _kind, _reason -> unavailable(request)
  end

  defp validate_state(
         %Selecto.Write.CandidateState{complete?: true, protection: protection},
         _request
       )
       when protection in @protections,
       do: :ok

  defp validate_state(%Selecto.Write.CandidateState{complete?: false}, request),
    do: pending(request)

  defp validate_state(%Selecto.Write.CandidateState{}, request), do: invalid_state(request)

  defp normalize_rows(rows, request) when is_list(rows) do
    cond do
      length(rows) > request.max_rows -> bound_error(request, length(rows))
      not Enum.all?(rows, &is_map/1) -> invalid_state(request)
      true -> validate_prior_identities(Enum.map(rows, &string_keys/1), request)
    end
  end

  defp normalize_rows(_rows, request), do: invalid_state(request)

  defp validate_prior_identities(rows, request) do
    with {:ok, identities} <- identities(rows, request.identity_fields, request),
         true <- length(identities) == MapSet.size(MapSet.new(identities)) do
      {:ok, rows}
    else
      false -> ambiguous_state(request)
      {:error, _} = error -> error
    end
  end

  defp apply_entries(rows, entries, request) do
    Enum.reduce_while(entries, {:ok, rows}, fn entry, {:ok, current} ->
      attrs = entry |> Map.fetch!(:attrs) |> string_keys()

      case entry.operation do
        operation when operation in [:create, :insert, :link] ->
          {:cont, add_row(current, attrs, request)}

        operation when operation in [:update, :auto] ->
          {:cont, update_row(current, attrs, request)}

        operation when operation in [:delete, :unlink] ->
          {:cont, delete_row(current, attrs, request)}

        _operation ->
          {:halt, invalid_state(request)}
      end
    end)
  end

  defp add_row(rows, attrs, request) do
    case optional_identity(attrs, request.identity_fields) do
      nil ->
        {:ok, rows ++ [attrs]}

      identity ->
        if Enum.any?(rows, &(identity_key(&1, request.identity_fields) == identity)) do
          ambiguous_state(request)
        else
          {:ok, rows ++ [attrs]}
        end
    end
  end

  defp update_row(rows, attrs, request) do
    with {:ok, identity} <- required_identity(attrs, request.identity_fields, request),
         {:ok, index} <- exactly_one_index(rows, identity, request) do
      {:ok, List.update_at(rows, index, &Map.merge(&1, attrs))}
    end
  end

  defp delete_row(rows, attrs, request) do
    with {:ok, identity} <- required_identity(attrs, request.identity_fields, request),
         {:ok, index} <- exactly_one_index(rows, identity, request) do
      {:ok, List.delete_at(rows, index)}
    end
  end

  defp exactly_one_index(rows, identity, request) do
    indexes =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} ->
        identity_key(row, request.identity_fields) == identity
      end)
      |> Enum.map(&elem(&1, 1))

    case indexes do
      [index] -> {:ok, index}
      _ -> ambiguous_state(request)
    end
  end

  defp identities(rows, fields, request) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, values} ->
      case required_identity(row, fields, request) do
        {:ok, identity} -> {:cont, {:ok, values ++ [identity]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp required_identity(row, fields, request) do
    case optional_identity(row, fields) do
      nil -> invalid_state(request)
      identity -> {:ok, identity}
    end
  end

  defp optional_identity(row, fields) do
    values = Enum.map(fields, &Map.fetch(row, to_string(&1)))

    if values != [] and
         Enum.all?(values, fn
           {:ok, value} -> not is_nil(value)
           :error -> false
         end),
       do: values,
       else: nil
  end

  defp identity_key(row, fields), do: optional_identity(row, fields)

  defp validate_bound(rows, request) do
    if length(rows) <= request.max_rows, do: :ok, else: bound_error(request, length(rows))
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp pending(request),
    do:
      candidate_error(
        :required_data_rule_pending,
        :pending,
        "complete candidate state is required",
        request
      )

  defp unavailable(request),
    do:
      candidate_error(
        :candidate_state_unavailable,
        :error,
        "candidate state provider failed",
        request
      )

  defp invalid_state(request),
    do: candidate_error(:invalid_candidate_state, :error, "candidate state is invalid", request)

  defp ambiguous_state(request),
    do:
      candidate_error(
        :ambiguous_candidate_identity,
        :error,
        "candidate identities are incomplete or ambiguous",
        request
      )

  defp bound_error(request, count),
    do:
      candidate_error(
        :candidate_state_limit_exceeded,
        :error,
        "candidate state exceeds its row bound",
        request,
        count: count
      )

  defp candidate_error(code, disposition, message, request, extra \\ []) do
    {:error,
     Error.new(:validation, message,
       details:
         Map.merge(
           %{
             code: code,
             disposition: disposition,
             path: request.path,
             stage: :candidate,
             representation: request.representation,
             max_rows: request.max_rows
           },
           Map.new(extra)
         )
     )}
  end
end
