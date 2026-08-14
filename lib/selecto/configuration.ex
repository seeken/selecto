defmodule Selecto.Configuration do
  @moduledoc """
  Domain configuration and initialization for Selecto.

  This module handles the setup and configuration of Selecto instances,
  including domain validation, connection pooling, and adapter initialization.
  """

  require Logger

  @doc """
  Generate a Selecto structure from a domain configuration and connection input.

  ## Parameters

  - `domain` - Domain configuration map (see domain configuration docs)
  - `connection_input` - Adapter-specific connection options, an Ecto repo,
    a live connection pid/name, or a pooled connection reference.
  - `opts` - Configuration options

  ## Options

  - `:validate` - (boolean, default: true) Whether to validate the domain configuration
  - `:pool` - (boolean, default: false) Whether to enable connection pooling
  - `:pool_options` - Connection pool configuration options
  - `:adapter` - database adapter module. It must be passed explicitly unless
    the host application configures `config :selecto, :default_adapter, ...`.
  - `:rollup_sort_fix` - (`true | false | :auto`, default: `:auto`) whether to
    wrap `GROUP BY ROLLUP ... ORDER BY` queries in a compatibility subquery;
    `:auto` delegates version-specific behavior to the configured adapter.

  ## Examples

      # Basic usage (validation enabled by default)
      selecto =
        Selecto.Configuration.configure(domain, connection_input,
          adapter: MyApp.SelectoAdapter
        )

      # With connection pooling
      selecto =
        Selecto.Configuration.configure(domain, connection_input,
          adapter: MyApp.SelectoAdapter,
          pool: true
        )

      # Disable validation for performance
      selecto =
        Selecto.Configuration.configure(domain, connection_input,
          adapter: MyApp.SelectoAdapter,
          validate: false
        )
  """
  @spec configure(Selecto.Types.domain(), term(), keyword()) :: Selecto.Types.t()
  def configure(domain, connection_input, opts \\ []) do
    configure_input(domain, nil, connection_input, opts)
  end

  @doc false
  @spec configure_registered(
          Selecto.Types.domain(),
          Selecto.Domain.Ref.t(),
          term(),
          keyword()
        ) :: Selecto.Types.t()
  def configure_registered(domain, %Selecto.Domain.Ref{} = ref, connection_input, opts) do
    configure_input(domain, ref, connection_input, opts)
  end

  defp configure_input(domain, domain_ref, connection_input, opts) do
    Selecto.OptionsValidator.validate_configure_opts!(opts)
    :ok = Selecto.Policy.ensure_configuration_options!(opts)

    validate? = Keyword.get(opts, :validate, true)
    use_pool? = Keyword.get(opts, :pool, false)
    adapter = resolve_adapter!(opts, connection_input)
    pool_options = opts |> Keyword.get(:pool_options, []) |> Keyword.put_new(:adapter, adapter)

    extension_specs = Selecto.Extensions.from_domain(domain)
    domain = Selecto.Extensions.merge_domain_extensions(domain, extension_specs)

    if domain_ref do
      :ok = Selecto.Domain.Registry.validate_domain!(domain, domain_ref)
    end

    if validate? do
      Selecto.DomainValidator.validate_domain!(domain)
    end

    # Handle connection pooling
    final_connection_input =
      if use_pool? and not match?({:pool, _}, connection_input) and
           not match?(%Selecto.Runtime.Context{}, connection_input) do
        case Selecto.ConnectionPool.start_pool(connection_input, pool_options) do
          {:ok, pool_ref} ->
            {:pool, pool_ref}

          {:error, reason} ->
            Logger.warning(
              "Failed to start connection pool: #{inspect(reason)}. Falling back to direct connection."
            )

            connection_input
        end
      else
        connection_input
      end

    connection = initialize_connection!(adapter, final_connection_input)
    runtime = runtime_context(adapter, connection, final_connection_input)

    rollup_sort_fix = resolve_rollup_sort_fix(adapter, connection, opts)

    config =
      configure_domain(domain, extension_specs)
      |> Map.put(:rollup_sort_fix, rollup_sort_fix)

    policy = Selecto.Policy.new!(domain, config, opts)

    %Selecto{
      runtime: runtime,
      adapter: adapter,
      connection: connection,
      domain: domain,
      domain_ref: domain_ref,
      config: config,
      extensions: extension_specs,
      policy: policy,
      set: %{
        selected: Map.get(domain, :required_selected, []),
        filtered: [],
        required_filters: Map.get(domain, :required_filters, []),
        post_retarget_filters: [],
        order_by: Map.get(domain, :required_order_by, []),
        group_by: Map.get(domain, :required_group_by, [])
      }
    }
  end

  defp resolve_adapter!(opts, connection_input) do
    configured_adapter =
      Keyword.get(opts, :adapter) ||
        Selecto.Runtime.Context.adapter(connection_input) ||
        Selecto.AdapterSupport.default_adapter()

    case configured_adapter do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        adapter

      _ ->
        raise ArgumentError,
              "Selecto.configure/3 requires an explicit :adapter or a configured " <>
                "application default"
    end
  end

  defp initialize_connection!(adapter, %Selecto.Runtime.Context{
         adapter: adapter,
         connection: connection
       }),
       do: connection

  defp initialize_connection!(adapter, %Selecto.Runtime.Context{adapter: context_adapter}) do
    raise ArgumentError,
          "configured adapter #{inspect(adapter)} does not match runtime context adapter " <>
            inspect(context_adapter)
  end

  defp initialize_connection!(adapter, {:pool, %{adapter: adapter} = pool_ref}), do: pool_ref

  defp initialize_connection!(adapter, connection_input) do
    unless Selecto.AdapterSupport.callback_available?(adapter, :connect, 1) do
      raise ArgumentError, "adapter #{inspect(adapter)} does not implement connect/1"
    end

    case adapter.connect(connection_input) do
      {:ok, connection} ->
        connection

      {:error, reason} ->
        raise "Failed to connect with adapter #{inspect(adapter)}: #{inspect(reason)}"
    end
  end

  defp runtime_context(
         adapter,
         connection,
         %Selecto.Runtime.Context{adapter: adapter, connection: connection} = runtime
       ),
       do: runtime

  defp runtime_context(adapter, connection, _connection_input),
    do: Selecto.Runtime.Context.new(adapter, connection)

  defp resolve_rollup_sort_fix(adapter, connection, opts) do
    case Keyword.get(opts, :rollup_sort_fix, :auto) do
      value when value in [true, false] ->
        value

      _auto_or_invalid ->
        auto_rollup_sort_fix(adapter, connection)
    end
  end

  defp auto_rollup_sort_fix(adapter, connection) do
    if Selecto.AdapterSupport.callback_available?(adapter, :rollup_sort_fix, 1) do
      adapter.rollup_sort_fix(connection)
    else
      false
    end
  end

  @doc """
  Configure Selecto from an Ecto repository and schema.

  This convenience function automatically introspects the Ecto schema
  and configures Selecto with the appropriate domain and database connection.

  ## Parameters

  - `repo` - The Ecto repository module (e.g., MyApp.Repo)
  - `schema` - The Ecto schema module to use as the source table
  - `opts` - Configuration options (passed to EctoAdapter.configure/3)

  ## Examples

      # Basic usage
      selecto =
        Selecto.Configuration.from_ecto(MyApp.Repo, MyApp.User,
          adapter: MyApp.SelectoAdapter
        )

      # With joins and options
      selecto = Selecto.Configuration.from_ecto(MyApp.Repo, MyApp.User,
        adapter: MyApp.SelectoAdapter,
        joins: [:posts, :profile],
        redact_fields: [:password_hash]
      )
  """
  @spec from_ecto(module(), module(), keyword()) :: Selecto.Types.t()
  def from_ecto(repo, schema, opts \\ []) do
    Selecto.EctoAdapter.configure(repo, schema, opts)
  end

  @doc """
  Generate the selecto configuration from a domain map.

  Processes domain configuration to extract fields, joins, and filters.
  This is called internally during configure/3.
  """
  @spec configure_domain(Selecto.Types.domain()) :: Selecto.Types.processed_config()
  def configure_domain(%{source: _source} = domain) do
    configure_domain(domain, Selecto.Extensions.from_domain(domain))
  end

  @spec configure_domain(Selecto.Types.domain(), [{module(), keyword()}]) ::
          Selecto.Types.processed_config()
  def configure_domain(%{source: source} = domain, extension_specs)
      when is_list(extension_specs) do
    primary_key = source.primary_key

    fields =
      Selecto.Schema.Column.configure_columns(
        :selecto_root,
        source.fields -- Map.get(source, :redact_fields, []),
        source,
        domain
      )

    joins = Selecto.Schema.Join.recurse_joins(source, domain)

    # Combine fields from Joins into fields list
    fields =
      List.flatten([fields | Enum.map(Map.values(joins), fn e -> e.fields end)])
      |> Enum.reduce(%{}, fn m, acc -> Map.merge(m, acc) end)

    # Extra filters (all normal fields can be a filter)
    # These are custom filters passed to Selecto Components
    filters = Map.get(domain, :filters, %{})

    filters =
      Enum.reduce(
        Map.values(joins),
        filters,
        fn e, acc ->
          Map.merge(Map.get(e, :filters, %{}), acc)
        end
      )
      |> Enum.map(fn {f, v} -> {f, Map.put(v, :id, f)} end)
      |> Enum.into(%{})

    %{
      source: source,
      source_table: source.source_table,
      primary_key: primary_key,
      columns: fields,
      joins: joins,
      filters: filters,
      functions: Map.get(domain, :functions, %{}),
      domain_data: Map.get(domain, :domain_data),
      extensions: extension_specs
    }
  end
end
