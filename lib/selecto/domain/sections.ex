defmodule Selecto.Domain.Sections do
  @moduledoc """
  Top-level Selecto domain section classification.

  The registry is intentionally diagnostic-only. It tells callers how a domain's
  authored top-level keys are understood without changing runtime configuration
  behavior.
  """

  @categories [:canonical, :projection, :proposed, :unknown]

  @canonical_sections MapSet.new([
                        "schema_version",
                        "domain_version",
                        "domain_fingerprint",
                        "name",
                        "source",
                        "schemas",
                        "joins",
                        "default_selected",
                        "required_selected",
                        "required_filters",
                        "required_order_by",
                        "required_group_by",
                        "filters",
                        "functions",
                        "query_members",
                        "query_library",
                        "published_views",
                        "detail_actions",
                        "components",
                        "domain_data",
                        "extensions"
                      ])

  @projection_sections MapSet.new([
                         "columns",
                         "custom_columns",
                         "json_schemas",
                         "subfilters",
                         "window_functions",
                         "pagination",
                         "retarget",
                         "redact_fields"
                       ])

  @proposed_sections MapSet.new([
                       "writes",
                       "actions",
                       "events",
                       "capabilities",
                       "source_relationships",
                       "choice_sources"
                     ])

  @doc """
  Returns the diagnostic section categories in stable order.
  """
  @spec categories() :: [:canonical | :projection | :proposed | :unknown]
  def categories, do: @categories

  @doc """
  Returns the finite, recognized top-level domain sections grouped by category.

  Section names are strings in stable order. The open-ended `:unknown`
  diagnostic category is intentionally omitted so documentation and
  certification tooling can compare their coverage against the complete known
  vocabulary without creating atoms from external input.
  """
  @spec sections() :: %{
          canonical: [String.t()],
          projection: [String.t()],
          proposed: [String.t()]
        }
  def sections do
    %{
      canonical: sorted_sections(@canonical_sections),
      projection: sorted_sections(@projection_sections),
      proposed: sorted_sections(@proposed_sections)
    }
  end

  @doc """
  Classifies a single top-level domain section key.
  """
  @spec classify(term()) :: :canonical | :projection | :proposed | :unknown
  def classify(section) do
    section_name = section_name(section)

    cond do
      MapSet.member?(@canonical_sections, section_name) -> :canonical
      MapSet.member?(@projection_sections, section_name) -> :projection
      MapSet.member?(@proposed_sections, section_name) -> :proposed
      true -> :unknown
    end
  end

  @doc """
  Classifies all authored top-level keys in a domain map.

  Returned section lists preserve the authored key values while sorting them for
  deterministic diagnostics and tests.
  """
  @spec classify_top_level_keys(map()) :: %{
          canonical: [term()],
          projection: [term()],
          proposed: [term()],
          unknown: [term()]
        }
  def classify_top_level_keys(domain) when is_map(domain) do
    domain
    |> Map.keys()
    |> Enum.reduce(empty_sections(), fn key, acc ->
      Map.update!(acc, classify(key), &[key | &1])
    end)
    |> Enum.into(%{}, fn {category, keys} ->
      {category, Enum.sort_by(keys, &sort_value/1)}
    end)
  end

  @doc false
  @spec empty_sections() :: %{
          canonical: [],
          projection: [],
          proposed: [],
          unknown: []
        }
  def empty_sections do
    %{
      canonical: [],
      projection: [],
      proposed: [],
      unknown: []
    }
  end

  defp section_name(section) when is_atom(section), do: Atom.to_string(section)
  defp section_name(section) when is_binary(section), do: section
  defp section_name(section), do: inspect(section)

  defp sort_value(section), do: section_name(section)

  defp sorted_sections(sections), do: sections |> MapSet.to_list() |> Enum.sort()
end
