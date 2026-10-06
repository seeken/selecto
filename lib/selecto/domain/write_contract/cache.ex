defmodule Selecto.Domain.WriteContract.Cache do
  @moduledoc false

  # Compiled write contracts, so a governed write does not re-validate its
  # domain on every command (a batch of 100 commands used to compile the same
  # contract 100 times).
  #
  # Compiling is a pure function of the domain term, so an entry is reused
  # only for a domain that is exactly equal (`===`) to the one it was compiled
  # from; the hash is just the slot. A host that passes a modified domain map,
  # even one that keeps its name or `domain_fingerprint`, misses and gets its
  # own freshly compiled contract. Failed compilations are never stored.
  #
  # The table belongs to the application and holds at most @max_entries
  # domains; when it fills it is cleared and refills on demand. Without the
  # table (application not started) every call compiles.

  @table :selecto_write_contracts
  @max_entries 256

  @doc false
  def init_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc false
  @spec fetch(map(), (map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(domain, compile) when is_map(domain) and is_function(compile, 1) do
    key = :erlang.phash2(domain, 4_294_967_296)

    case lookup(key, domain) do
      {:ok, contract} ->
        {:ok, contract}

      :miss ->
        with {:ok, contract} <- compile.(domain) do
          store(key, domain, contract)
          {:ok, contract}
        end
    end
  end

  @doc false
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key, domain) do
    case :ets.lookup(@table, key) do
      [{^key, cached_domain, contract}] when cached_domain === domain -> {:ok, contract}
      _other -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, domain, contract) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, domain, contract})
  rescue
    # The table is missing, or went away between the size check and the insert.
    ArgumentError -> true
  end
end
