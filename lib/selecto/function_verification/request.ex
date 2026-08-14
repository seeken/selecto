defmodule Selecto.FunctionVerification.Request do
  @moduledoc """
  Adapter-neutral request to verify one resolved registered-function signature.

  Requests contain signature metadata only. Runtime argument values are never
  copied into the request or sent to an adapter verification callback.
  """

  alias Selecto.TypeSystem

  @protocol_version 1
  @requirement_keys [:adapters, :requires, :volatility, :minimum_version]

  @enforce_keys [
    :protocol_version,
    :function_id,
    :kind,
    :sql_name,
    :arguments,
    :returns,
    :call_site,
    :requirements,
    :signature_fingerprint
  ]
  defstruct @enforce_keys

  @type argument :: %{
          required(:name) => atom() | String.t(),
          required(:type) => term(),
          required(:source) => :selector | :value | :literal,
          required(:null?) => boolean()
        }

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          function_id: String.t(),
          kind: :scalar | :predicate | :table,
          sql_name: String.t(),
          arguments: [argument()],
          returns: term(),
          call_site: atom(),
          requirements: map(),
          signature_fingerprint: String.t()
        }

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @spec new(atom() | String.t(), map(), atom()) ::
          {:ok, t()} | {:error, Selecto.Error.t()}
  def new(function_id, signature, call_site) when is_map(signature) and is_atom(call_site) do
    normalized_id = Selecto.UDF.normalize_id(function_id)
    sql_name = Map.get(signature, :sql_name)
    kind = Map.get(signature, :kind)
    arguments = Enum.map(Map.get(signature, :args, []), &normalize_argument/1)
    returns = Map.get(signature, :returns)

    with :ok <- validate_sql_name(sql_name),
         :ok <- validate_kind(kind),
         :ok <- validate_arguments(arguments),
         :ok <- validate_returns(kind, returns),
         {:ok, requirements} <- normalize_requirements(Map.get(signature, :database)) do
      fingerprint_source = %{
        function_id: normalized_id,
        kind: kind,
        sql_name: sql_name,
        arguments: arguments,
        returns: returns,
        call_site: call_site,
        requirements: requirements
      }

      {:ok,
       %__MODULE__{
         protocol_version: @protocol_version,
         function_id: normalized_id,
         kind: kind,
         sql_name: sql_name,
         arguments: arguments,
         returns: returns,
         call_site: call_site,
         requirements: requirements,
         signature_fingerprint: fingerprint(fingerprint_source)
       }}
    end
  end

  def new(function_id, _signature, call_site) do
    {:error,
     invalid_request("function verification requires a normalized signature and call site", %{
       function_id: normalize_id(function_id),
       call_site: call_site
     })}
  end

  defp normalize_argument(argument) when is_map(argument) do
    %{
      name: Map.get(argument, :name),
      type: argument |> Map.get(:type, :unknown) |> TypeSystem.normalize_type(),
      source: Map.get(argument, :source),
      null?: Map.get(argument, :null?, true)
    }
  end

  defp normalize_argument(_argument),
    do: %{name: nil, type: :unknown, source: nil, null?: true}

  defp normalize_requirements(nil), do: {:ok, %{}}

  defp normalize_requirements(requirements) when is_map(requirements) do
    normalized =
      Enum.reduce(@requirement_keys, %{}, fn key, acc ->
        case fetch_key(requirements, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    {:ok, normalized}
  end

  defp normalize_requirements(_requirements) do
    {:error, invalid_request("function verification database requirements must be a map")}
  end

  defp validate_sql_name(sql_name) do
    if Selecto.UDF.valid_sql_name?(sql_name) do
      :ok
    else
      {:error, invalid_request("function verification requires a safe SQL function name")}
    end
  end

  defp validate_kind(kind) do
    if Selecto.UDF.valid_kind?(kind) do
      :ok
    else
      {:error, invalid_request("function verification requires a valid function kind")}
    end
  end

  defp validate_arguments(arguments) do
    valid? =
      Enum.all?(arguments, fn argument ->
        (is_atom(argument.name) or is_binary(argument.name)) and
          TypeSystem.valid_type?(argument.type) and
          Selecto.UDF.valid_arg_source?(argument.source) and
          is_boolean(argument.null?)
      end)

    if valid? do
      :ok
    else
      {:error, invalid_request("function verification arguments are invalid")}
    end
  end

  defp validate_returns(:predicate, :boolean), do: :ok

  defp validate_returns(:table, %{columns: columns})
       when is_map(columns) and map_size(columns) > 0,
       do: :ok

  defp validate_returns(:table, %{"columns" => columns})
       when is_map(columns) and map_size(columns) > 0,
       do: :ok

  defp validate_returns(:scalar, nil), do: :ok

  defp validate_returns(:scalar, returns) when is_atom(returns),
    do: validate_scalar_return(returns)

  defp validate_returns(:scalar, {:array, _} = returns), do: validate_scalar_return(returns)

  defp validate_returns(_kind, _returns),
    do: {:error, invalid_request("function verification return metadata is invalid")}

  defp validate_scalar_return(returns) do
    if TypeSystem.valid_type?(returns) do
      :ok
    else
      {:error, invalid_request("function verification requires a known return type")}
    end
  end

  defp fingerprint(source) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(source, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp invalid_request(message, details \\ %{}) do
    Selecto.Error.validation_error(message, Map.put(details, :code, :invalid_function_request))
  end

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp normalize_id(value) when is_atom(value) or is_binary(value),
    do: Selecto.UDF.normalize_id(value)

  defp normalize_id(_value), do: nil
end
