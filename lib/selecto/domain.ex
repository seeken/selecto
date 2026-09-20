defmodule Selecto.Domain do
  @moduledoc """
  Normalization, validation, projection, composition, and inspection for the
  versioned Selecto domain contract.

  `Selecto.configure/3` consumes and separately validates the authored runtime
  map; it does not replace that map with this module's normalized envelope.
  Callers use this module when they need the complete schema-v1 contract or a
  stable, read-only consumer projection.
  """

  use Selecto.Domain.Constants

  alias Selecto.Domain.Diagnostics
  alias Selecto.Domain.Sections
  alias Selecto.Domain.Shared.Map, as: MapHelpers
  alias Selecto.Domain.Shorthand
  alias Selecto.Domain.Inspector
  alias Selecto.Domain.Projector
  alias Selecto.Domain.Compose
  alias Selecto.Domain.CompositionContract
  alias Selecto.Domain.ConsumerProjectionRelease
  alias Selecto.Domain.Values
  alias Selecto.Analytics.Unit

  @current_schema_version 1
  @map_sections [
    :source,
    :schemas,
    :joins,
    :filters,
    :functions,
    :query_members,
    :query_library,
    :rules,
    :operations,
    :experiences,
    :published_views,
    :detail_actions,
    :editors,
    :components,
    :imports,
    :columns,
    :custom_columns,
    :json_schemas,
    :subfilters,
    :window_functions,
    :pagination,
    :retarget,
    :writes,
    :actions,
    :events,
    :capabilities,
    :source_relationships,
    :choice_sources,
    :co_domains
  ]
  @list_sections [
    :default_selected,
    :required_selected,
    :required_filters,
    :required_order_by,
    :required_group_by,
    :domain_dependencies,
    :redact_fields
  ]

  @doc """
  Normalizes an authored domain map into a compatibility-safe contract.

  The normalizer currently:

  - infers `schema_version` as `1` when it is missing
  - preserves optional `domain_version` metadata as an opaque authored-domain
    version label
  - preserves optional `domain_fingerprint` metadata as an opaque authored-domain
    content identity label
  - expands supported field-level choice-source shorthand into canonical
    `source_relationships`, `choice_sources`, and field reference bindings
  - expands `source.columns.*.write` and `source.associations.*.write`
    authoring shorthand into canonical `writes.fields` and
    `writes.relationships` registries
  - reports duplicate colocated/canonical write declarations as fail-closed
    authoring errors rather than choosing precedence
  - classifies authored top-level sections as canonical, projection, proposed,
    or unknown
  - exposes current query, write, action, capability, relationship, choice,
    dependency, operation, experience, and import registries without rewriting existing
    runtime behavior

  Returns `{:ok, normalized, diagnostics}` for maps and `{:error, diagnostics}`
  for non-map inputs.
  """
  @spec normalize(term()) :: {:ok, map(), Diagnostics.t()} | {:error, Diagnostics.t()}
  def normalize(domain) when is_map(domain) do
    {schema_version, schema_version_inferred, schema_version_warnings} = schema_version(domain)
    domain_version = domain_version(domain)
    domain_fingerprint = domain_fingerprint(domain)
    sections = Sections.classify_top_level_keys(domain)

    diagnostics =
      Diagnostics.new(
        errors: Shorthand.authoring_errors(domain),
        warnings: schema_version_warnings ++ section_shape_warnings(domain),
        sections: sections,
        schema_version: schema_version,
        schema_version_inferred: schema_version_inferred
      )

    canonical_domain =
      domain
      |> Map.put(:schema_version, schema_version)
      |> maybe_put_domain_version(domain_version)
      |> maybe_put_domain_fingerprint(domain_fingerprint)
      |> Shorthand.normalize_authoring_shorthand()
      |> Unit.normalize_domain_columns()
      |> Values.decorate()

    {:ok,
     normalized_domain(
       domain,
       canonical_domain,
       schema_version,
       domain_version,
       domain_fingerprint,
       sections
     ), diagnostics}
  end

  def normalize(_domain) do
    diagnostics =
      Diagnostics.new(
        errors: [
          %{
            code: :invalid_domain,
            message: "Selecto domains must be maps"
          }
        ]
      )

    {:error, diagnostics}
  end

  @doc "Applies a declared string field's text_case to a scalar write or import value."
  @spec normalize_field_value(map(), atom() | String.t(), term()) :: term()
  def normalize_field_value(domain, field, value)
      when is_map(domain) and (is_atom(field) or is_binary(field)) and is_binary(value) do
    path = field |> to_string() |> String.split(".")

    column =
      case path do
        [name] ->
          domain
          |> MapHelpers.map_value(:source)
          |> MapHelpers.map_value(:columns)
          |> fetch_domain_entry(name)

        [association, name] ->
          root = MapHelpers.map_value(domain, :source)
          association_spec = MapHelpers.relation_association(root, association)
          schema_id = MapHelpers.map_value(association_spec, :queryable)
          schemas = MapHelpers.map_value(domain, :schemas)

          schemas
          |> fetch_domain_entry(schema_id)
          |> MapHelpers.map_value(:columns)
          |> fetch_domain_entry(name)

        _ ->
          nil
      end

    case MapHelpers.map_value(column, :text_case) do
      case_mode when case_mode in [:uppercase, "uppercase"] -> String.upcase(value)
      case_mode when case_mode in [:lowercase, "lowercase"] -> String.downcase(value)
      _ -> value
    end
  end

  def normalize_field_value(_domain, _field, value), do: value

  @doc "Returns declared one-to-one inline-values foreign keys by owner field."
  @spec values_foreign_keys(map()) :: map()
  def values_foreign_keys(domain) when is_map(domain) do
    {keys, _errors} = Values.foreign_keys(domain)

    Map.new(keys, fn {field, spec} ->
      {field,
       %{
         association: spec.association,
         display_name: spec.display_name,
         value_field: spec.value_field,
         values: Enum.map(spec.options, & &1.value)
       }}
    end)
  end

  defp fetch_domain_entry(map, key) when is_map(map) and not is_nil(key) do
    case MapHelpers.fetch_key(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_domain_entry(_, _), do: nil

  @doc """
  Normalizes an authored domain and validates it against the schema-v1 contract.

  Runtime configuration uses `Selecto.DomainValidator` for its authored-map
  checks. Domain producers should use this function as the portable contract
  boundary in addition to runtime validation.
  """
  @spec validate(term()) :: {:ok, map(), Diagnostics.t()} | {:error, Diagnostics.t()}
  def validate(domain) do
    with {:ok, normalized, diagnostics} <- normalize(domain) do
      case Selecto.Domain.Contract.errors(normalized) do
        [] ->
          if diagnostics.errors == [] do
            {:ok, normalized, diagnostics}
          else
            {:error, diagnostics}
          end

        errors ->
          {:error, %{diagnostics | errors: diagnostics.errors ++ errors}}
      end
    end
  end

  @doc """
  Composes an authored domain with one or more domain overlays.

  This is the Stage 2 composition boundary. It is opt-in and does not participate
  in `Selecto.configure/3` yet. Composition uses explicit, deterministic merge
  semantics:

  - maps deep-merge by section
  - `redact_fields`, including `source.redact_fields`, are unioned
  - `extensions` are appended uniquely
  - other lists and scalar values are replaced by later overlays

  After overlays are merged, declared extension `merge_domain/2` callbacks are
  applied in declaration order and the result is normalized again.
  """
  @spec compose(term(), term()) :: {:ok, map(), Diagnostics.t()} | {:error, Diagnostics.t()}
  def compose(domain, overlays \\ []) do
    Compose.compose(domain, overlays, &normalize/1)
  end

  @doc """
  Returns structured inspection output for an authored or normalized domain.

  The inspection map is intentionally compact and deterministic so generators,
  Studio, docs, and tests can reason about the normalized contract without
  walking the whole domain map directly.
  """
  @spec describe(term()) :: {:ok, map(), Diagnostics.t()} | {:error, Diagnostics.t()}
  def describe(
        %{
          schema_version: schema_version,
          domain: %{} = _domain,
          query: %{} = _query,
          projection: %{} = _projection,
          sections: sections
        } = normalized
      ) do
    diagnostics =
      Diagnostics.new(
        sections: sections,
        schema_version: schema_version,
        schema_version_inferred: false
      )

    {:ok, Inspector.inspection_output(normalized, diagnostics), diagnostics}
  end

  def describe(domain) do
    with {:ok, normalized, diagnostics} <- normalize(domain) do
      {:ok, Inspector.inspection_output(normalized, diagnostics), diagnostics}
    end
  end

  @doc """
  Returns the constrained query contract projection for an authored or normalized
  domain.

  This is a convenience wrapper around `normalize/1` and
  `project(normalized, :query_contract)` for Components, AI tooling, and other
  consumers that should not need to walk the normalized domain map directly.
  """
  @spec query_contract(term()) :: {:ok, map(), Diagnostics.t()} | {:error, Diagnostics.t()}
  def query_contract(
        %{
          schema_version: schema_version,
          domain: %{} = _domain,
          query: %{} = _query,
          projection: %{} = _projection,
          sections: sections
        } = normalized
      ) do
    diagnostics =
      Diagnostics.new(
        sections: sections,
        schema_version: schema_version,
        schema_version_inferred: false
      )

    {:ok, Projector.project(normalized, :query_contract), diagnostics}
  end

  def query_contract(domain) do
    with {:ok, normalized, diagnostics} <- normalize(domain) do
      {:ok, Projector.project(normalized, :query_contract), diagnostics}
    end
  end

  @doc """
  Projects a normalized domain into a read-only consumer view.

  Projection helpers reshape the normalized map into explicit consumer
  contracts. Runtime query configuration does not consume these projections.

  Supported projections:

  - `:query` - query/runtime-facing sections
  - `:write` - write/action/reference sections
  - `:ui` - display defaults, choices, actions, and detail actions
  - `:api` - read/write/action contract for API-style consumers
  - `:import` - governed importer policy with derived write and action metadata
  - `:query_contract` - constrained query metadata for tools, Components, and AI
  """
  @spec project(map(), :query | :write | :ui | :api | :import | :query_contract) :: map()
  defdelegate project(normalized, projection), to: Projector

  @doc "Compiles the canonical nested relationship composition contract."
  @spec composition_contract(term()) :: {:ok, map()} | {:error, [map()]}
  def composition_contract(domain), do: CompositionContract.compile(domain)

  @doc "Compiles an immutable projection-specific nested consumer release."
  @spec consumer_projection_release(term(), keyword()) ::
          {:ok, map()} | {:error, map() | [map()]}
  def consumer_projection_release(domain, opts \\ []),
    do: ConsumerProjectionRelease.compile(domain, opts)

  @doc "Returns the published nested runtime/adapter capability matrix."
  @spec nested_capability_matrix() :: [map()]
  def nested_capability_matrix, do: Selecto.Domain.NestedCapabilityMatrix.profiles()

  @doc "Classifies compatibility changes between nested consumer releases."
  @spec diff_consumer_projection_releases(map(), map()) :: map()
  def diff_consumer_projection_releases(previous, current),
    do: ConsumerProjectionRelease.diff(previous, current)

  def normalized_domain(
        authored_domain,
        canonical_domain,
        schema_version,
        domain_version,
        domain_fingerprint,
        sections
      ) do
    %{
      schema_version: schema_version,
      domain_version: domain_version,
      domain_fingerprint: domain_fingerprint,
      authored_domain: authored_domain,
      domain: canonical_domain,
      sections: sections,
      source: MapHelpers.section(canonical_domain, :source),
      schemas: MapHelpers.section(canonical_domain, :schemas, %{}),
      joins: MapHelpers.section(canonical_domain, :joins, %{}),
      query: Projector.query_sections(canonical_domain),
      projection: Projector.projection_sections(canonical_domain),
      writes: MapHelpers.section(canonical_domain, :writes, %{}),
      rules: MapHelpers.section(canonical_domain, :rules, %{}),
      actions: MapHelpers.section(canonical_domain, :actions, %{}),
      events: MapHelpers.section(canonical_domain, :events, %{}),
      capabilities: MapHelpers.section(canonical_domain, :capabilities, %{}),
      source_relationships: MapHelpers.section(canonical_domain, :source_relationships, %{}),
      choice_sources: MapHelpers.section(canonical_domain, :choice_sources, %{}),
      co_domains: MapHelpers.section(canonical_domain, :co_domains, %{}),
      domain_dependencies: MapHelpers.section(canonical_domain, :domain_dependencies, []),
      operations: MapHelpers.section(canonical_domain, :operations, %{}),
      experiences: MapHelpers.section(canonical_domain, :experiences, %{}),
      detail_actions: MapHelpers.section(canonical_domain, :detail_actions, %{}),
      editors: MapHelpers.section(canonical_domain, :editors, %{}),
      components: MapHelpers.section(canonical_domain, :components, %{}),
      imports: MapHelpers.section(canonical_domain, :imports, %{}),
      domain_data: MapHelpers.section(canonical_domain, :domain_data, %{}),
      extensions: MapHelpers.section(canonical_domain, :extensions, [])
    }
  end

  def domain_version(domain) do
    case MapHelpers.fetch_section(domain, :domain_version) do
      {:ok, version} when is_binary(version) ->
        case String.trim(version) do
          "" -> nil
          trimmed -> trimmed
        end

      {:ok, version} when is_atom(version) or is_integer(version) ->
        version

      {:ok, _version} ->
        nil

      :error ->
        nil
    end
  end

  def maybe_put_domain_version(domain, nil), do: domain

  def maybe_put_domain_version(domain, domain_version),
    do: MapHelpers.put_section(domain, :domain_version, domain_version)

  def domain_fingerprint(domain) do
    case MapHelpers.fetch_section(domain, :domain_fingerprint) do
      {:ok, fingerprint} when is_binary(fingerprint) ->
        case String.trim(fingerprint) do
          "" -> nil
          trimmed -> trimmed
        end

      {:ok, _fingerprint} ->
        nil

      :error ->
        nil
    end
  end

  def maybe_put_domain_fingerprint(domain, nil), do: domain

  def maybe_put_domain_fingerprint(domain, domain_fingerprint),
    do: MapHelpers.put_section(domain, :domain_fingerprint, domain_fingerprint)

  def schema_version(domain) do
    case MapHelpers.fetch_section(domain, :schema_version) do
      {:ok, version} -> normalize_schema_version(version)
      :error -> {@current_schema_version, true, []}
    end
  end

  def normalize_schema_version(version) do
    case parse_schema_version(version) do
      version when is_integer(version) and version > @current_schema_version ->
        {version, false, [unsupported_schema_version_warning(version)]}

      version when is_integer(version) and version > 0 ->
        {version, false, []}

      _invalid ->
        {@current_schema_version, false, [invalid_schema_version_warning(version)]}
    end
  end

  def parse_schema_version(version) when is_integer(version), do: version

  def parse_schema_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {integer, ""} -> integer
      _ -> version
    end
  end

  def parse_schema_version(version), do: version

  def unsupported_schema_version_warning(version) do
    %{
      code: :unsupported_schema_version,
      message: "schema_version is newer than this Selecto release understands",
      schema_version: version,
      supported_schema_version: @current_schema_version
    }
  end

  def invalid_schema_version_warning(version) do
    %{
      code: :invalid_schema_version,
      message: "schema_version must be a positive integer; using the current schema version",
      value: version,
      schema_version: @current_schema_version
    }
  end

  def section_shape_warnings(domain) do
    []
    |> Kernel.++(shape_warnings(domain, [:name], "atom or string", &name?/1))
    |> Kernel.++(
      shape_warnings(
        domain,
        [:domain_version],
        "non-empty atom, string, or integer",
        &domain_version?/1
      )
    )
    |> Kernel.++(
      shape_warnings(domain, [:domain_fingerprint], "non-empty string", &domain_fingerprint?/1)
    )
    |> Kernel.++(shape_warnings(domain, @map_sections, "map", &is_map/1))
    |> Kernel.++(shape_warnings(domain, @list_sections, "list", &is_list/1))
    |> Kernel.++(
      shape_warnings(domain, [:extensions], "list or map", &(is_list(&1) or is_map(&1)))
    )
  end

  def shape_warnings(domain, sections, expected, valid?) do
    Enum.flat_map(sections, fn section ->
      case MapHelpers.fetch_section(domain, section) do
        {:ok, value} ->
          if valid?.(value) do
            []
          else
            [invalid_section_shape_warning(section, expected, value)]
          end

        :error ->
          []
      end
    end)
  end

  def invalid_section_shape_warning(section, expected, value) do
    %{
      code: :invalid_section_shape,
      message: "domain section #{inspect(section)} should be a #{expected}",
      section: section,
      expected: expected,
      actual: MapHelpers.value_type(value)
    }
  end

  def name?(value), do: is_atom(value) or is_binary(value)
  def domain_version?(value) when is_binary(value), do: String.trim(value) != ""
  def domain_version?(value), do: is_atom(value) or is_integer(value)
  def domain_fingerprint?(value) when is_binary(value), do: String.trim(value) != ""
  def domain_fingerprint?(_value), do: false
end
