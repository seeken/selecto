defmodule Selecto.QueryLibrary.DSL do
  @moduledoc """
  Declarative authoring DSL for portable named query definitions.

  The DSL produces a `query_library/0` map that can be embedded in a Selecto
  domain. Definitions remain data rather than arbitrary query callbacks, so
  they can be validated, inspected, exported, and reused by other runtimes.

      defmodule MyApp.CatalogQueries do
        use Selecto.QueryLibrary.DSL

        defsegment active_products do
          where(:status, eq: "active")
        end

        defprojection product_card do
          fields([:id, :name, :price, :status])
        end

        defordering newest_first do
          order_by(:inserted_at, :desc)
          order_by(:id, :desc)
        end

        defview active_catalog do
          segment(:active_products)
          projection(:product_card)
          ordering(:newest_first)
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Selecto.QueryLibrary.DSL

      Module.register_attribute(__MODULE__, :selecto_query_segments, accumulate: true)
      Module.register_attribute(__MODULE__, :selecto_query_projections, accumulate: true)
      Module.register_attribute(__MODULE__, :selecto_query_orderings, accumulate: true)
      Module.register_attribute(__MODULE__, :selecto_query_views, accumulate: true)

      @before_compile Selecto.QueryLibrary.DSL
    end
  end

  defmacro __before_compile__(env) do
    library = %{
      segments: definition_map(env.module, :selecto_query_segments),
      projections: definition_map(env.module, :selecto_query_projections),
      orderings: definition_map(env.module, :selecto_query_orderings),
      views: definition_map(env.module, :selecto_query_views)
    }

    Selecto.QueryLibrary.validate_library!(library)

    quote do
      @doc "Returns the portable named query definitions authored by this module."
      @spec query_library() :: Selecto.QueryLibrary.library()
      def query_library, do: unquote(Macro.escape(library))
    end
  end

  @doc "Defines a named row-membership predicate."
  defmacro defsegment(signature, do: block) do
    define(:segment, signature, block, __CALLER__)
  end

  @doc "Short alias for `defsegment/2`."
  defmacro defseg(signature, do: block) do
    define(:segment, signature, block, __CALLER__)
  end

  @doc "Defines a named result selection shape."
  defmacro defprojection(signature, do: block) do
    define(:projection, signature, block, __CALLER__)
  end

  @doc "Defines a named deterministic ordering."
  defmacro defordering(signature, do: block) do
    define(:ordering, signature, block, __CALLER__)
  end

  @doc "Defines a named composition of segments, a projection, and an ordering."
  defmacro defview(signature, do: block) do
    define(:view, signature, block, __CALLER__)
  end

  defp define(kind, signature, block, caller) do
    id = definition_id!(signature, kind)
    spec = compile_definition(kind, block, caller)
    attribute = definition_attribute(kind)

    quote do
      Module.put_attribute(
        __MODULE__,
        unquote(attribute),
        {unquote(id), unquote(Macro.escape(spec))}
      )
    end
  end

  defp definition_id!(id, _kind) when is_atom(id) and not is_nil(id), do: id
  defp definition_id!(id, _kind) when is_binary(id) and id != "", do: id

  defp definition_id!({name, _meta, context}, _kind)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: name

  defp definition_id!(signature, kind) do
    raise ArgumentError,
          "#{kind} definition names must be non-empty atoms or strings, got: #{Macro.to_string(signature)}"
  end

  defp compile_definition(:segment, block, caller) do
    block
    |> expressions()
    |> Enum.reduce(%{filters: [], parameters: %{}, segments: []}, fn expression, spec ->
      compile_segment_directive(expression, spec, caller)
    end)
    |> validate_segment_parameters!()
  end

  defp compile_definition(:projection, block, caller) do
    block
    |> expressions()
    |> Enum.reduce(%{fields: [], associations: []}, fn expression, spec ->
      compile_projection_directive(expression, spec, caller)
    end)
  end

  defp compile_definition(:ordering, block, caller) do
    block
    |> expressions()
    |> Enum.reduce(%{order_by: []}, fn expression, spec ->
      compile_ordering_directive(expression, spec, caller)
    end)
  end

  defp compile_definition(:view, block, caller) do
    block
    |> expressions()
    |> Enum.reduce(%{segments: []}, fn expression, spec ->
      compile_view_directive(expression, spec, caller)
    end)
  end

  defp compile_segment_directive({:where, _, [field_ast, condition_ast]}, spec, caller) do
    field = literal!(field_ast, caller)

    filter =
      case condition_ast do
        [{operator, value_ast}] when is_atom(operator) ->
          {operator, field, definition_value(value_ast, caller)}

        value_ast ->
          {:eq, field, definition_value(value_ast, caller)}
      end

    Map.update!(spec, :filters, &(&1 ++ [filter]))
  end

  defp compile_segment_directive(
         {:where, _, [field_ast, operator_ast, value_ast]},
         spec,
         caller
       ) do
    filter =
      {literal!(operator_ast, caller), literal!(field_ast, caller),
       definition_value(value_ast, caller)}

    Map.update!(spec, :filters, &(&1 ++ [filter]))
  end

  defp compile_segment_directive({:param, _, [name_ast, type_ast]}, spec, caller) do
    compile_segment_directive({:param, [], [name_ast, type_ast, []]}, spec, caller)
  end

  defp compile_segment_directive(
         {:param, _, [name_ast, type_ast, opts_ast]},
         spec,
         caller
       ) do
    name = literal!(name_ast, caller)
    type = literal!(type_ast, caller)
    opts = literal!(opts_ast, caller)

    unless (is_atom(name) and not is_nil(name)) or (is_binary(name) and name != "") do
      raise ArgumentError, "segment parameter names must be non-empty atoms or strings"
    end

    unless is_atom(type) or is_binary(type) do
      raise ArgumentError, "segment parameter #{inspect(name)} type must be an atom or string"
    end

    unless Keyword.keyword?(opts) do
      raise ArgumentError, "segment parameter #{inspect(name)} options must be a keyword list"
    end

    parameter =
      opts
      |> Map.new()
      |> Map.put(:type, type)
      |> Map.put_new(:required, not Keyword.has_key?(opts, :default))

    if equivalent_key?(spec.parameters, name) do
      raise ArgumentError, "duplicate segment parameter #{inspect(name)}"
    end

    put_in(spec, [:parameters, name], parameter)
  end

  defp compile_segment_directive({:include_segment, _, [id_ast]}, spec, caller) do
    id = literal!(id_ast, caller)
    Map.update!(spec, :segments, &(&1 ++ [id]))
  end

  defp compile_segment_directive(expression, spec, caller) do
    compile_metadata_directive(expression, spec, caller, :segment)
  end

  defp compile_projection_directive({:fields, _, [fields_ast]}, spec, caller) do
    fields = literal!(fields_ast, caller)

    unless is_list(fields) do
      raise ArgumentError, "projection fields must be a list"
    end

    Map.put(spec, :fields, fields)
  end

  defp compile_projection_directive({:field, _, [field_ast]}, spec, caller) do
    field = literal!(field_ast, caller)
    Map.update!(spec, :fields, &(&1 ++ [field]))
  end

  defp compile_projection_directive(
         {:association, _, [association_ast, [do: block]]},
         spec,
         caller
       ) do
    association = literal!(association_ast, caller)

    association_spec =
      block
      |> expressions()
      |> Enum.reduce(%{name: association, fields: [], associations: []}, fn expression, acc ->
        compile_projection_directive(expression, acc, caller)
      end)

    Map.update!(spec, :associations, &(&1 ++ [association_spec]))
  end

  defp compile_projection_directive(expression, spec, caller) do
    compile_metadata_directive(expression, spec, caller, :projection)
  end

  defp compile_ordering_directive(
         {:order_by, _, [field_ast, direction_ast]},
         spec,
         caller
       ) do
    order = {literal!(field_ast, caller), literal!(direction_ast, caller)}
    Map.update!(spec, :order_by, &(&1 ++ [order]))
  end

  defp compile_ordering_directive({:orders, _, [orders_ast]}, spec, caller) do
    orders = literal!(orders_ast, caller)

    unless is_list(orders) do
      raise ArgumentError, "ordering orders must be a list"
    end

    Map.put(spec, :order_by, orders)
  end

  defp compile_ordering_directive(expression, spec, caller) do
    compile_metadata_directive(expression, spec, caller, :ordering)
  end

  defp compile_view_directive({:segment, _, [segment_ast]}, spec, caller) do
    segment = literal!(segment_ast, caller)
    Map.update!(spec, :segments, &(&1 ++ [segment]))
  end

  defp compile_view_directive({:segments, _, [segments_ast]}, spec, caller) do
    segments = literal!(segments_ast, caller)

    unless is_list(segments) do
      raise ArgumentError, "view segments must be a list"
    end

    Map.put(spec, :segments, segments)
  end

  defp compile_view_directive({:projection, _, [projection_ast]}, spec, caller) do
    Map.put(spec, :projection, literal!(projection_ast, caller))
  end

  defp compile_view_directive({:ordering, _, [ordering_ast]}, spec, caller) do
    Map.put(spec, :ordering, literal!(ordering_ast, caller))
  end

  defp compile_view_directive(expression, spec, caller) do
    compile_metadata_directive(expression, spec, caller, :view)
  end

  defp compile_metadata_directive({directive, _, [value_ast]}, spec, caller, _kind)
       when directive in [:label, :description, :capability] do
    Map.put(spec, directive, literal!(value_ast, caller))
  end

  defp compile_metadata_directive(expression, _spec, _caller, kind) do
    raise ArgumentError,
          "unsupported #{kind} directive: #{Macro.to_string(expression)}"
  end

  defp validate_segment_parameters!(spec) do
    declared = spec.parameters |> Map.keys() |> Enum.map(&definition_key/1) |> MapSet.new()

    referenced =
      spec.filters
      |> collect_parameter_references([])
      |> Enum.map(&definition_key/1)
      |> MapSet.new()

    case MapSet.difference(referenced, declared) |> MapSet.to_list() do
      [] ->
        spec

      missing ->
        raise ArgumentError, "segment references undeclared parameters: #{inspect(missing)}"
    end
  end

  defp collect_parameter_references({:param, name}, acc), do: [name | acc]

  defp collect_parameter_references(value, acc) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_parameter_references/2)
  end

  defp collect_parameter_references(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_parameter_references/2)
  end

  defp collect_parameter_references(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, item}, refs ->
      refs = collect_parameter_references(key, refs)
      collect_parameter_references(item, refs)
    end)
  end

  defp collect_parameter_references(_value, acc), do: acc

  defp definition_value({:param, _, [name_ast]}, caller),
    do: {:param, literal!(name_ast, caller)}

  defp definition_value(value_ast, caller), do: literal!(value_ast, caller)

  defp literal!(ast, caller) do
    {value, _binding} = Code.eval_quoted(ast, [], caller)
    value
  rescue
    error ->
      raise ArgumentError,
            "query-library directives require compile-time data, got #{Macro.to_string(ast)}: #{Exception.message(error)}"
  end

  defp expressions({:__block__, _, expressions}), do: expressions
  defp expressions(expression), do: [expression]

  defp definition_attribute(:segment), do: :selecto_query_segments
  defp definition_attribute(:projection), do: :selecto_query_projections
  defp definition_attribute(:ordering), do: :selecto_query_orderings
  defp definition_attribute(:view), do: :selecto_query_views

  defp definition_map(module, attribute) do
    definitions = module |> Module.get_attribute(attribute) |> Enum.reverse()

    duplicates =
      definitions
      |> Enum.group_by(fn {id, _spec} -> definition_key(id) end)
      |> Enum.filter(fn {_id, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "duplicate query-library definitions: #{inspect(duplicates)}"
    end

    Map.new(definitions)
  end

  defp equivalent_key?(map, key) do
    key = definition_key(key)
    Enum.any?(Map.keys(map), &(definition_key(&1) == key))
  end

  defp definition_key(value) when is_atom(value), do: Atom.to_string(value)
  defp definition_key(value) when is_binary(value), do: value
  defp definition_key(value), do: inspect(value)

  # Directive placeholders consumed by the definition macros above.
  defmacro where(_field, _condition), do: quote(do: nil)
  defmacro where(_field, _operator, _value), do: quote(do: nil)
  defmacro param(_name), do: quote(do: nil)
  defmacro param(_name, _type, _opts \\ []), do: quote(do: nil)
  defmacro include_segment(_id), do: quote(do: nil)
  defmacro fields(_fields), do: quote(do: nil)
  defmacro field(_field), do: quote(do: nil)
  defmacro association(_association, do: _block), do: quote(do: nil)
  defmacro order_by(_field, _direction), do: quote(do: nil)
  defmacro orders(_orders), do: quote(do: nil)
  defmacro segment(_segment), do: quote(do: nil)
  defmacro segments(_segments), do: quote(do: nil)
  defmacro projection(_projection), do: quote(do: nil)
  defmacro ordering(_ordering), do: quote(do: nil)
  defmacro label(_label), do: quote(do: nil)
  defmacro description(_description), do: quote(do: nil)
  defmacro capability(_capability), do: quote(do: nil)
end
