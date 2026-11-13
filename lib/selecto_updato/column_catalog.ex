defmodule SelectoUpdato.ColumnCatalog do
  @moduledoc false

  # Catalog metadata for the portable candidate check (query_enforced_scalar
  # v2): the real type of each column of the insert target, read once per
  # write before the adapter opens a transaction (the pool may hold a single
  # connection). It is the `verified` trust level: the adapter reads it from
  # its database catalog through the optional callback
  #
  #     column_catalog(connection, table) ::
  #       {:ok, %{column => %{type: String.t(), deterministic: boolean() | nil}}}
  #
  # where `type` is the column's complete declared type (length, precision,
  # scale, fractional seconds and, by name, collation) and `deterministic`
  # the catalog's collation determinism when the backend reports it (nil:
  # the collation name in `type` decides). A column the catalog does not
  # report, an adapter without the callback, or any failure leaves the field
  # known only by its declared domain type, which is `unverified` (fails
  # closed).
  #
  # A host may pass `:column_metadata` itself (the same shape, keyed by
  # table) when it issued the DDL; it is taken as verified.

  alias SelectoUpdato.Operation

  @scope {__MODULE__, :scope}

  @doc """
  Runs `fun` inside a catalog scope: one write transaction (an execute, a
  Multi batch). Within the scope each table's catalog is read at most once,
  keyed by connection and table; the cache is dropped when the scope ends.
  A cache never spans transactions: after DDL a stale entry could fail open
  (a varchar(10) narrowed to varchar(2) would still admit 't1 ').
  """
  @spec scoped((-> result)) :: result when result: term()
  def scoped(fun) when is_function(fun, 0) do
    case Process.get(@scope) do
      cache when is_map(cache) ->
        # Already inside a scope (an execute within a Multi): share it.
        fun.()

      _ ->
        Process.put(@scope, %{})

        try do
          fun.()
        after
          Process.delete(@scope)
        end
    end
  end

  @doc """
  The catalog options for one write. A write that compiles inside the
  adapter's transaction (`prepared?`) reads the catalog now, before the
  transaction holds the connection. Any other write gets a provider the
  candidate check calls only when it evaluates a candidate, so a write
  refused earlier (tenant scope, contract) performs no catalog I/O.
  """
  @spec options(keyword(), Operation.t() | [Operation.t()], Selecto.t(), boolean()) :: keyword()
  def options(opts, operations, selecto, true), do: put(opts, operations, selecto)

  def options(opts, _operations, %Selecto{} = selecto, false) do
    if Keyword.has_key?(opts, :column_metadata_provider),
      do: opts,
      else: Keyword.put(opts, :column_metadata_provider, &cached_lookup(selecto, &1))
  end

  @doc "Adds `:column_metadata` for the insert targets of `operations` to `opts`."
  @spec put(keyword(), Operation.t() | [Operation.t()], Selecto.t()) :: keyword()
  def put(opts, operations, %Selecto{} = selecto) do
    existing = Keyword.get(opts, :column_metadata) || %{}

    tables =
      operations
      |> List.wrap()
      |> Enum.filter(&needs_catalog?/1)
      |> Enum.map(&table/1)
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(existing, &1)))
      |> Enum.uniq()

    case tables do
      [] ->
        opts

      tables ->
        metadata =
          Enum.reduce(tables, existing, fn table, acc ->
            case cached_lookup(selecto, table) do
              columns when map_size(columns) > 0 -> Map.put(acc, table, columns)
              _ -> acc
            end
          end)

        Keyword.put(opts, :column_metadata, metadata)
    end
  end

  # Only inserts reach the portable candidate check.
  defp needs_catalog?(%Operation{type: :insert} = operation) do
    not is_nil(operation.query_enforcement) or
      (map_value(operation.domain, :required_filters) || []) != []
  end

  defp needs_catalog?(_operation), do: false

  defp table(%Operation{domain: domain}) do
    source = map_value(domain, :source) || %{}

    case SelectoUpdato.WriteContract.relation_name(source) do
      table when is_binary(table) and table != "" -> table
      table when is_atom(table) and not is_nil(table) -> Atom.to_string(table)
      _ -> nil
    end
  end

  # The catalog of `table`, read once per scope (see scoped/1); outside a
  # scope every call reads.
  defp cached_lookup(%Selecto{adapter: adapter, connection: connection} = selecto, table) do
    key = {adapter, connection, table}

    case Process.get(@scope) do
      %{^key => columns} ->
        columns

      cache when is_map(cache) ->
        columns = lookup(selecto, table)
        Process.put(@scope, Map.put(cache, key, columns))
        columns

      _ ->
        lookup(selecto, table)
    end
  end

  @doc false
  def lookup(%Selecto{adapter: adapter, connection: connection}, table) do
    with true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :column_catalog, 2),
         {:ok, columns} when is_map(columns) <- adapter.column_catalog(connection, table) do
      normalize_columns(columns)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  @doc false
  # A table's catalog columns, `%{column => info}`, with every key and value
  # in its documented string or atom form normalised by column_info/1. A
  # column whose name is not a string or atom is dropped.
  def normalize_columns(columns) when is_map(columns) do
    columns
    |> Enum.flat_map(fn
      {name, info} when is_binary(name) ->
        [{name, column_info(info)}]

      {name, info} when is_atom(name) and not is_nil(name) ->
        [{Atom.to_string(name), column_info(info)}]

      _other ->
        []
    end)
    |> Map.new()
  end

  def normalize_columns(_columns), do: %{}

  @doc false
  # One column's catalog info: `%{type: String.t() | nil, trust: trust,
  # deterministic: boolean() | nil}`. Keys may be atoms or strings, trust and
  # deterministic values atoms/booleans or their strings. An adapter or host
  # may lower trust (an unresolved domain chain), never raise it: an absent
  # trust is verified, a recognised one is kept, and anything else (an
  # unknown value, a missing or non-string type, a malformed map) is
  # unverified, so it decides nothing.
  def column_info(info) when is_map(info) do
    type =
      case map_value(info, :type) do
        type when is_binary(type) and type != "" -> type
        _ -> nil
      end

    trust =
      case {type, normalize_trust(map_value(info, :trust))} do
        {nil, _trust} -> :unverified
        {_type, trust} -> trust
      end

    %{
      type: type,
      trust: trust,
      deterministic: normalize_deterministic(map_value(info, :deterministic))
    }
  end

  def column_info(_info), do: %{type: nil, trust: :unverified, deterministic: false}

  defp normalize_trust(nil), do: :verified
  defp normalize_trust(trust) when trust in [:verified, "verified"], do: :verified
  defp normalize_trust(trust) when trust in [:base_verified, "base_verified"], do: :base_verified
  defp normalize_trust(_trust), do: :unverified

  # Determinism unknown (nil) lets the declared collation name decide; an
  # unrecognised value is treated as nondeterministic.
  defp normalize_deterministic(value) when value in [true, "true"], do: true
  defp normalize_deterministic(nil), do: nil
  defp normalize_deterministic(_value), do: false

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil
end
