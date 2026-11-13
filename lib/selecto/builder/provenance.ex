defmodule Selecto.Builder.Provenance do
  @moduledoc false

  # What a compile saw, in the building process: whether any builder emitted
  # text it did not generate, and how many filters it compiled. Text is unsafe
  # unless proved otherwise: a builder that takes text it does not resolve
  # passes it through reference/1 or marks, and configuration is walked whole
  # (config_text?/1), so a name that is not a plain name counts wherever it
  # would land. Selecto's executor stamps a read as generated only when
  # nothing marked it. A marked read is still Selecto's statement, carrying a host
  # fragment (`selecto_raw_sql`): an adapter keeps its pin and guards and leaves the
  # text verbatim. Only text with neither mark is wholly the host's.

  @raw :selecto_builder_raw_sql
  @nodes :selecto_builder_filter_nodes

  # A dotted path of plain names can only be a column: nothing in it can
  # carry an operator or a literal.
  @name_part ~S/(?:[A-Za-z_][A-Za-z0-9_$]*|"(?:[^"]|"")+")/
  @name_path Regex.compile!("\\A" <> @name_part <> "(?:\\." <> @name_part <> ")*\\z")

  @comparison ~w(= != <> < > <= >=)

  # Join configuration that is not SQL text, or that its own builder resolves
  # or marks.
  @not_sql_text [
    :name,
    :label,
    :description,
    :display_name,
    :filters,
    :fields,
    :columns,
    :on,
    :subquery,
    :subquery_params,
    :subquery_adapter,
    :subquery_read,
    :lateral_query,
    :conditions,
    :path_separator,
    :root_path,
    :parameters,
    :parameter_values,
    :dimension,
    :metadata
  ]

  @secret :selecto_builder_generated_filter

  def mark, do: Process.put(@raw, true)

  @doc "`text` as given, marking the compile unless it is a plain name path."
  def reference(text) do
    unless name?(text), do: mark()
    text
  end

  @doc "`operator` as given, marking the compile unless it is a comparison."
  def operator(operator) do
    unless to_string(operator) in @comparison, do: mark()
    operator
  end

  defp name?(text) when is_atom(text), do: name?(Atom.to_string(text))

  defp name?(text) when is_binary(text) or is_list(text) do
    Regex.match?(@name_path, IO.iodata_to_binary(text))
  rescue
    ArgumentError -> false
  end

  defp name?(_text), do: false

  @doc """
  Whether any join or schema of `selecto` carries text that is not a plain
  name: every builder that reads such configuration interpolates it.
  """
  def config_text?(%{domain: domain} = selecto) when is_map(domain) do
    schemas = domain |> Map.get(:schemas, %{}) |> map_values()
    set = Map.get(selecto, :set) || %{}

    Enum.any?(schemas, &(not name?(Map.get(&1, :source_table, "t")))) or
      unnamed?(Map.get(domain, :joins, %{})) or
      unnamed?(selecto |> Map.get(:config) |> joins()) or
      unnamed?(Map.get(set, :dynamic_joins, %{}))
  end

  def config_text?(_selecto), do: false

  defp joins(%{joins: joins}), do: joins
  defp joins(_config), do: %{}

  defp map_values(map) when is_map(map), do: Map.values(map)
  defp map_values(_other), do: []

  defp unnamed?(%_{}), do: false

  defp unnamed?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> key not in @not_sql_text and unnamed?(value) end)
  end

  defp unnamed?(list) when is_list(list) do
    if Keyword.keyword?(list),
      do: list |> Map.new() |> unnamed?(),
      else: Enum.any?(list, &unnamed?/1)
  end

  defp unnamed?(value) when is_binary(value), do: not name?(value)
  defp unnamed?(_value), do: false

  @doc """
  A filter Selecto built itself. The wrapper carries this VM's secret, so a
  filter that reaches the public API as data cannot claim it.
  """
  def generated_filter(filter), do: {:selecto_generated, secret(), filter}

  @doc """
  A segment filter whose values its domain fixed: it may name a redacted source
  field (segments give safe access to withheld fields). It carries the same
  secret as generated_filter/1, so filter data cannot claim it.
  """
  def domain_filter(filter), do: {:selecto_domain_filter, secret(), filter}

  @doc "`selecto` resolving its source's redacted fields, for a domain filter."
  def unredacted(%{config: %{source: source} = config} = selecto) when is_map(source),
    do: %{selecto | config: %{config | source: Map.put(source, :redact_fields, [])}}

  def unredacted(selecto), do: selecto

  @doc "Whether `tag` is the secret of generated_filter/1."
  def generated_tag?(tag), do: tag == secret()

  defp secret do
    case :persistent_term.get(@secret, nil) do
      nil ->
        value = :crypto.strong_rand_bytes(16)
        :persistent_term.put(@secret, value)
        value

      value ->
        value
    end
  end

  def count_filter, do: Process.put(@nodes, Process.get(@nodes, 0) + 1)

  @doc "Runs `fun`: `{result, marked?, filter_nodes}`, adding to any outer capture."
  def capture(fun) do
    raw = Process.get(@raw, false)
    nodes = Process.get(@nodes, 0)
    Process.put(@raw, false)
    Process.put(@nodes, 0)

    try do
      result = fun.()
      {result, Process.get(@raw, false), Process.get(@nodes, 0)}
    after
      Process.put(@raw, raw or Process.get(@raw, false))
      Process.put(@nodes, nodes + Process.get(@nodes, 0))
    end
  end

  @doc "Runs `fun`, whose text Selecto generated, without marking."
  def generated(fun) do
    raw = Process.get(@raw, false)

    try do
      fun.()
    after
      Process.put(@raw, raw)
    end
  end
end
