defmodule Selecto.Domain.Registry do
  @moduledoc """
  Trusted, fail-closed resolution of Selecto domains by opaque name.

  A registry is a server-owned module implementing `fetch/2`. It must return a
  domain map using one of these forms:

      {:ok, domain}
      {:ok, domain, metadata}
      {:error, reason}

  Bare maps are deliberately rejected so accidental fallback values cannot
  become query authority. Every resolved domain passes both the portable
  schema-v1 contract and the authored runtime validator.

  A generated single-domain provider can use this module directly:

      defmodule MyApp.SelectoDomains.OrdersDomain do
        use Selecto.Domain.Registry, id: "orders"

        def domain, do: %{...}
      end
  """

  alias Selecto.Domain.Ref

  @type id :: atom() | String.t()
  @type context :: map()
  @type metadata :: map()
  @type fetch_result ::
          {:ok, Selecto.Types.domain()}
          | {:ok, Selecto.Types.domain(), metadata()}
          | {:error, term()}

  @callback fetch(id(), context()) :: fetch_result()
  @callback ids() :: [id()]
  @optional_callbacks ids: 0

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)

    unless (is_atom(id) and not is_nil(id)) or (is_binary(id) and String.trim(id) != "") do
      raise ArgumentError, "Selecto domain registry id must be a non-empty atom or string"
    end

    quote bind_quoted: [id: id] do
      @behaviour Selecto.Domain.Registry
      @selecto_domain_id id

      @doc "Returns the stable registry id for this generated domain."
      def domain_id, do: @selecto_domain_id

      @doc "Returns an opaque registry reference without embedding the domain map."
      def domain_ref,
        do: Selecto.Domain.Ref.new(@selecto_domain_id, __MODULE__)

      @impl Selecto.Domain.Registry
      def ids, do: [@selecto_domain_id]

      @impl Selecto.Domain.Registry
      def fetch(id, _context) do
        if Selecto.Domain.Registry.same_id?(id, @selecto_domain_id) do
          {:ok, domain()}
        else
          {:error, :not_found}
        end
      end

      defoverridable fetch: 2, ids: 0
    end
  end

  @spec resolve(module(), id(), context()) ::
          {:ok, Selecto.Types.domain(), Ref.t()} | {:error, Selecto.Domain.RegistryError.t()}
  def resolve(registry, id, context \\ %{}) do
    with :ok <- validate_registry(registry, id),
         :ok <- validate_id(id, registry),
         :ok <- validate_context(context, registry, id),
         {:ok, domain, metadata} <- call_registry(registry, id, context),
         :ok <- validate_domain(domain, Ref.new(id, registry)) do
      {:ok, domain, build_ref(registry, id, domain, metadata)}
    end
  end

  @spec resolve!(module(), id(), context()) :: {Selecto.Types.domain(), Ref.t()}
  def resolve!(registry, id, context \\ %{}) do
    case resolve(registry, id, context) do
      {:ok, domain, ref} -> {domain, ref}
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec validate_domain(term(), Ref.t()) :: :ok | {:error, Selecto.Domain.RegistryError.t()}
  def validate_domain(domain, %Ref{} = ref) when is_map(domain) do
    with {:ok, _normalized, _diagnostics} <- Selecto.Domain.validate(domain),
         :ok <- Selecto.DomainValidator.validate_domain(domain) do
      :ok
    else
      {:error, %{errors: errors}} ->
        registry_error(ref.registry, ref.id, :invalid_domain_contract, %{errors: errors})

      {:error, errors} when is_list(errors) ->
        registry_error(ref.registry, ref.id, :invalid_runtime_domain, %{errors: errors})
    end
  end

  def validate_domain(_domain, %Ref{} = ref) do
    registry_error(ref.registry, ref.id, :invalid_domain, %{expected: :map})
  end

  @doc false
  @spec validate_domain!(term(), Ref.t()) :: :ok
  def validate_domain!(domain, %Ref{} = ref) do
    case validate_domain(domain, ref) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def same_id?(left, right)
      when (is_atom(left) or is_binary(left)) and (is_atom(right) or is_binary(right)) do
    id_string(left) == id_string(right)
  end

  def same_id?(_left, _right), do: false

  defp validate_registry(registry, id) when is_atom(registry) and not is_nil(registry) do
    if Code.ensure_loaded?(registry) and function_exported?(registry, :fetch, 2) do
      :ok
    else
      registry_error(registry, id, :invalid_registry)
    end
  end

  defp validate_registry(registry, id), do: registry_error(registry, id, :invalid_registry)

  defp validate_id(id, _registry)
       when is_atom(id) and not is_nil(id),
       do: :ok

  defp validate_id(id, registry) when is_binary(id) do
    if String.trim(id) == "" do
      registry_error(registry, id, :invalid_domain_id)
    else
      :ok
    end
  end

  defp validate_id(id, registry), do: registry_error(registry, id, :invalid_domain_id)

  defp validate_context(context, _registry, _id) when is_map(context), do: :ok

  defp validate_context(_context, registry, id),
    do: registry_error(registry, id, :invalid_registry_context)

  defp call_registry(registry, id, context) do
    registry
    |> apply(:fetch, [id, context])
    |> normalize_fetch_result(registry, id)
  rescue
    _exception -> registry_error(registry, id, :registry_failed)
  catch
    _kind, _reason -> registry_error(registry, id, :registry_failed)
  end

  defp normalize_fetch_result({:ok, domain}, _registry, _id) when is_map(domain),
    do: {:ok, domain, %{}}

  defp normalize_fetch_result({:ok, domain, metadata}, _registry, _id)
       when is_map(domain) and is_map(metadata),
       do: {:ok, domain, metadata}

  defp normalize_fetch_result({:error, reason}, registry, id),
    do: registry_error(registry, id, normalize_reason(reason))

  defp normalize_fetch_result(_result, registry, id),
    do: registry_error(registry, id, :invalid_registry_result)

  defp normalize_reason(reason) when reason in [:not_found, :forbidden], do: reason
  defp normalize_reason(_reason), do: :registry_failed

  defp build_ref(registry, id, domain, metadata) do
    version = map_value(metadata, :version) || map_value(domain, :domain_version)
    fingerprint = map_value(metadata, :fingerprint) || map_value(domain, :domain_fingerprint)

    Ref.new(id, registry,
      version: version,
      fingerprint: fingerprint,
      metadata: Map.drop(metadata, [:version, "version", :fingerprint, "fingerprint"])
    )
  end

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp id_string(id) when is_atom(id), do: Atom.to_string(id)
  defp id_string(id), do: id

  defp registry_error(registry, id, reason, details \\ %{}) do
    {:error,
     Selecto.Domain.RegistryError.exception(
       registry: registry,
       domain_id: id,
       reason: reason,
       details: details
     )}
  end
end

defmodule Selecto.Domain.RegistryError do
  @moduledoc """
  Raised when a named domain cannot be resolved or fails validation.
  """

  defexception [:message, :reason, :domain_id, :registry, details: %{}]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: atom(),
          domain_id: term(),
          registry: term(),
          details: map()
        }

  @impl Exception
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    domain_id = Keyword.get(opts, :domain_id)
    registry = Keyword.get(opts, :registry)

    %__MODULE__{
      message: message(reason, domain_id),
      reason: reason,
      domain_id: domain_id,
      registry: registry,
      details: Keyword.get(opts, :details, %{})
    }
  end

  defp message(:not_found, _id), do: "registered Selecto domain was not found"
  defp message(:forbidden, _id), do: "registered Selecto domain is not available"

  defp message(reason, id),
    do: "registered Selecto domain #{inspect(id)} could not be resolved (#{reason})"
end
