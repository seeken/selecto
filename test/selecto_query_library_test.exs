defmodule Selecto.QueryLibraryTest do
  use ExUnit.Case, async: true

  defmodule Definitions do
    use Selecto.QueryLibrary.DSL

    defsegment active_projects do
      where(:status, eq: "active")
    end

    defsegment priority_at_least do
      param(:minimum, :integer)
      where(:priority, gte: param(:minimum))
    end

    defsegment archived_projects do
      where(:status, eq: "archived")
    end

    defseg active_priority_projects do
      all_of do
        segment(:active_projects)
        segment(:priority_at_least)
      end
    end

    defsegment active_or_archived_projects do
      any_of([:active_projects, :archived_projects])
    end

    defsegment inactive_projects do
      not_segment(:active_projects)
    end

    defsegment neither_active_nor_archived_projects do
      nor_segments([:active_projects, :archived_projects])
    end

    defsegment active_xor_archived_projects do
      xor_segments([:active_projects, :archived_projects])
    end

    defprojection project_identity do
      fields([:id, :name])
    end

    defprojection project_status do
      fields([:status, :priority])
    end

    defprojection project_summary do
      include_projections([:project_identity, :project_status])
    end

    defprojection item_identity do
      association(:items) do
        fields([:id])
      end
    end

    defprojection item_name do
      association(:items) do
        fields([:name])
      end
    end

    defprojection project_with_items do
      include_projection(:project_identity)
      include_projections([:item_identity, :item_name])
    end

    defordering highest_priority do
      order_by(:priority, :desc)
      order_by(:id, :asc)
    end

    defview active_project_summaries do
      segment(:active_priority_projects)
      projection(:project_summary)
      ordering(:highest_priority)
    end
  end

  test "DSL emits portable segment, projection, ordering, and view data" do
    library = Definitions.query_library()

    assert library.segments.active_projects.filters == [{:eq, :status, "active"}]

    assert library.segments.priority_at_least == %{
             filters: [{:gte, :priority, {:param, :minimum}}],
             parameters: %{minimum: %{required: true, type: :integer}},
             segment_groups: [],
             segments: []
           }

    assert library.segments.active_priority_projects.segment_groups == [
             %{operator: :and, segments: [:active_projects, :priority_at_least]}
           ]

    assert library.segments.active_or_archived_projects.segment_groups == [
             %{operator: :or, segments: [:active_projects, :archived_projects]}
           ]

    assert library.segments.inactive_projects.segment_groups == [
             %{operator: :not, segments: [:active_projects]}
           ]

    assert library.segments.neither_active_nor_archived_projects.segment_groups == [
             %{operator: :nor, segments: [:active_projects, :archived_projects]}
           ]

    assert library.segments.active_xor_archived_projects.segment_groups == [
             %{operator: :xor, segments: [:active_projects, :archived_projects]}
           ]

    assert library.projections.project_summary.projections == [
             :project_identity,
             :project_status
           ]

    assert library.projections.project_with_items.projections == [
             :project_identity,
             :item_identity,
             :item_name
           ]

    assert library.orderings.highest_priority.order_by == [
             {:priority, :desc},
             {:id, :asc}
           ]

    assert library.views.active_project_summaries == %{
             segments: [:active_priority_projects],
             projection: :project_summary,
             ordering: :highest_priority
           }
  end

  test "segments compose, cast parameters, and preserve required filters" do
    query =
      configured()
      |> Selecto.apply_segment(:active_priority_projects, minimum: "2")

    assert {"visible", true} in Selecto.query_filters(query, validate_tenant: false)
    assert {:status, "active"} in Selecto.query_filters(query, validate_tenant: false)
    assert {:priority, {:gte, 2}} in Selecto.query_filters(query, validate_tenant: false)

    assert Selecto.applied_query_library(query).segments == [
             "active_projects",
             "priority_at_least",
             "active_priority_projects"
           ]
  end

  test "segments compose with OR, NOT, NOR, and XOR while required filters remain outside" do
    assert_segment_filter(
      :active_or_archived_projects,
      {:or, [{:status, "active"}, {:status, "archived"}]}
    )

    assert_segment_filter(:inactive_projects, {:not, {:status, "active"}})

    assert_segment_filter(
      :neither_active_nor_archived_projects,
      {:not, {:or, [{:status, "active"}, {:status, "archived"}]}}
    )

    assert_segment_filter(
      :active_xor_archived_projects,
      {:and,
       [
         {:or, [{:status, "active"}, {:status, "archived"}]},
         {:not, {:and, [{:status, "active"}, {:status, "archived"}]}}
       ]}
    )
  end

  test "a projection replaces optional selections and preserves required selections" do
    query =
      configured()
      |> Selecto.select([:inserted_at])
      |> Selecto.apply_projection(:project_summary)

    assert query.set.selected == [:id, :name, :status, :priority]
    assert query.set.selection_shape.selected_count == 4
    assert Selecto.applied_query_library(query).projection == "project_summary"
  end

  test "nested projections compile through SelectionShape" do
    query = configured() |> Selecto.apply_projection(:project_with_items)

    assert query.set.selected == [:id, :name]
    assert query.set.selection_shape.selected_count == 2
    assert query.set.selection_shape.subselect_count == 1

    assert [subselect] = query.set.subselected
    assert subselect.fields == ["id", "name"]

    assert Selecto.applied_query_library(query).projections == [
             "project_identity",
             "item_identity",
             "item_name",
             "project_with_items"
           ]
  end

  test "multiple projections merge fields at application time" do
    query = configured() |> Selecto.apply_projection([:project_identity, :project_status])

    assert query.set.selected == [:id, :name, :status, :priority]

    assert Selecto.applied_query_library(query).projections == [
             "project_identity",
             "project_status"
           ]
  end

  test "an ordering replaces optional order entries while preserving required ordering" do
    query =
      configured()
      |> Selecto.order_by({:name, :asc})
      |> Selecto.apply_ordering(:highest_priority)

    assert query.set.order_by == [
             {:id, :asc},
             {:priority, :desc}
           ]

    assert Selecto.applied_query_library(query).ordering == "highest_priority"
  end

  test "views apply their definitions in semantic order" do
    query = Selecto.apply_view(configured(), :active_project_summaries, minimum: "3")

    assert {"visible", true} in Selecto.query_filters(query, validate_tenant: false)
    assert {:status, "active"} in Selecto.query_filters(query, validate_tenant: false)
    assert {:priority, {:gte, 3}} in Selecto.query_filters(query, validate_tenant: false)
    assert query.set.selected == [:id, :name, :status, :priority]

    assert Selecto.applied_query_library(query) == %{
             segments: [
               "active_projects",
               "priority_at_least",
               "active_priority_projects"
             ],
             projection: "project_summary",
             projections: ["project_identity", "project_status", "project_summary"],
             ordering: "highest_priority",
             views: ["active_project_summaries"]
           }
  end

  test "unknown definitions and invalid parameters fail before SQL generation" do
    assert_raise ArgumentError, ~r/unknown query-library segment/, fn ->
      Selecto.apply_segment(configured(), :missing)
    end

    assert_raise ArgumentError, ~r/missing required segment parameter/, fn ->
      Selecto.apply_segment(configured(), :priority_at_least)
    end

    assert_raise ArgumentError, ~r/must be :integer/, fn ->
      Selecto.apply_segment(configured(), :priority_at_least, minimum: "not-an-integer")
    end

    string_typed =
      put_in(
        domain(),
        [:query_library, :segments, :priority_at_least, :parameters, :minimum, :type],
        "integer"
      )

    assert_raise ArgumentError, ~r/must be "integer"/, fn ->
      string_typed
      |> Selecto.configure(:mock_connection)
      |> Selecto.apply_segment(:priority_at_least, minimum: "not-an-integer")
    end
  end

  test "domain normalization and query-contract projection retain the portable library" do
    assert {:ok, normalized, diagnostics} = Selecto.Domain.validate(domain())
    assert diagnostics.unknown_sections == []
    assert normalized.query.query_library == Definitions.query_library()

    assert {:ok, query_contract, _diagnostics} = Selecto.Domain.query_contract(domain())
    assert query_contract.query_library == Definitions.query_library()
  end

  test "domain validation rejects missing fields and missing composed definitions" do
    invalid =
      put_in(domain(), [:query_library, :projections, :broken], %{fields: [:missing_field]})

    assert {:error, diagnostics} = Selecto.Domain.validate(invalid)

    assert Enum.any?(diagnostics.errors, fn error ->
             error.code == :query_field_not_found and
               error.path == [:query_library, :projections, :broken, :fields, 0]
           end)

    invalid =
      put_in(domain(), [:query_library, :views, :broken], %{segments: [:missing_segment]})

    assert {:error, diagnostics} = Selecto.Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :query_definition_not_found))

    invalid =
      put_in(
        domain(),
        [:query_library, :projections, :project_summary, :projections],
        [:missing_projection]
      )

    assert {:error, diagnostics} = Selecto.Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :query_projection_not_found))
  end

  test "segment and projection composition cycles fail closed" do
    segment_cycle =
      put_in(
        domain(),
        [:query_library, :segments, :active_projects, :segment_groups],
        [%{operator: :and, segments: [:active_priority_projects]}]
      )

    assert {:error, diagnostics} = Selecto.Domain.validate(segment_cycle)
    assert Enum.any?(diagnostics.errors, &(&1.code == :query_segment_cycle))

    projection_cycle =
      put_in(
        domain(),
        [:query_library, :projections, :project_identity, :projections],
        [:project_summary]
      )

    assert {:error, diagnostics} = Selecto.Domain.validate(projection_cycle)
    assert Enum.any?(diagnostics.errors, &(&1.code == :query_projection_cycle))

    invalid_xor =
      put_in(
        domain(),
        [:query_library, :segments, :active_xor_archived_projects, :segment_groups],
        [%{operator: :xor, segments: [:active_projects]}]
      )

    assert {:error, diagnostics} = Selecto.Domain.validate(invalid_xor)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_query_segment_group))
  end

  defp configured do
    Selecto.configure(domain(), :mock_connection)
  end

  defp assert_segment_filter(segment, expected) do
    filters =
      configured()
      |> Selecto.apply_segment(segment)
      |> Selecto.query_filters(validate_tenant: false)

    assert {"visible", true} in filters
    assert expected in filters
  end

  defp domain do
    %{
      name: "Query Library Projects",
      source: %{
        source_table: "projects",
        primary_key: :id,
        fields: [:id, :name, :status, :priority, :visible, :inserted_at],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          status: %{type: :string},
          priority: %{type: :integer},
          visible: %{type: :boolean},
          inserted_at: %{type: :utc_datetime}
        },
        associations: %{
          items: %{
            queryable: :items,
            field: :items,
            owner_key: :id,
            related_key: :project_id
          }
        }
      },
      schemas: %{
        items: %{
          source_table: "items",
          primary_key: :id,
          fields: [:id, :name, :project_id],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            name: %{type: :string},
            project_id: %{type: :integer}
          },
          associations: %{}
        }
      },
      joins: %{items: %{name: "Items", type: :left}},
      required_filters: [{"visible", true}],
      required_selected: [:id],
      required_order_by: [{:id, :asc}],
      query_library: Definitions.query_library()
    }
  end
end
