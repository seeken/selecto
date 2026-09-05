defmodule Selecto.Query.Cursor do
  @moduledoc """
  Host-signed, expiring cursor tokens bound to release, tenant, query and profile.
  Keys remain host configuration and are never stored in plans or previews.
  Cursor pagination guarantees deterministic key ordering, not a database snapshot.
  """
  alias Selecto.Error

  def encode(plan, values, opts \\ []) do
    with {:ok, secret} <- secret(opts),
         :ok <- Selecto.Query.Plan.cursor_values(plan, values) do
      payload = %{
        "v" => 1,
        "scope" => scope(plan, opts),
        "values" => values,
        "expires" => now(opts) + min(max(Keyword.get(opts, :cursor_ttl, 900), 1), 3600)
      }

      body = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      {:ok, body <> "." <> sign(body, secret)}
    end
  end

  def decode(plan, token, opts \\ []) do
    with {:ok, secret} <- secret(opts),
         true <- is_binary(token) and byte_size(token) <= 32_768,
         [body, signature] <- String.split(token, "."),
         true <- secure_equal?(signature, sign(body, secret)),
         {:ok, json} <- Base.url_decode64(body, padding: false),
         {:ok, %{"v" => 1, "scope" => binding, "values" => values, "expires" => expiry}} <-
           Jason.decode(json),
         true <- binding == scope(plan, opts) and is_integer(expiry) and expiry > now(opts),
         :ok <- Selecto.Query.Plan.cursor_values(plan, values) do
      {:ok, values}
    else
      _ -> {:error, Error.validation_error("Invalid, expired, or incompatible cursor")}
    end
  end

  defp scope(plan, opts) do
    {plan.release["digest"], plan.relation["id"], plan.relation["parent_identity"], plan.tenant,
     plan.predicates, plan.ordering, plan.metadata["access_pattern"],
     Keyword.get(opts, :cursor_profile, "document-v1")}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp secret(opts) do
    case Keyword.get(opts, :cursor_secret) do
      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, key}

      _ ->
        {:error,
         Error.configuration_error("A host cursor_secret of at least 32 bytes is required")}
    end
  end

  defp sign(body, key),
    do: :crypto.mac(:hmac, :sha256, key, body) |> Base.url_encode64(padding: false)

  defp now(opts), do: Keyword.get(opts, :cursor_now, System.system_time(:second))

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_, _), do: false
end
