defmodule Selecto.Schema.JoinSimpleTest do
  use ExUnit.Case

  alias Selecto.Schema.Join

  # Simplified tests focused on the core Join logic without Column integration
  # These tests use very minimal mock structures to avoid Column.configure issues

  describe "recurse_joins/2 core functionality" do
    test "handles empty joins map" do
      domain = %{joins: %{}, schemas: %{}}
      source = %{associations: %{}}

      result = Join.recurse_joins(source, domain)

      assert result == %{}
    end

    test "processes basic join configuration" do
      # Mock with minimal required fields to avoid Column.configure
      domain = %{
        schemas: %{
          posts: %{
            name: "Post",
            source_table: "posts",
            # Empty fields to avoid Column.configure call
            fields: [],
            redact_fields: [],
            columns: %{}
          }
        },
        joins: %{
          posts: %{type: :left, name: "posts"}
        }
      }

      source = %{
        associations: %{
          posts: %{queryable: :posts, field: :posts, owner_key: :id, related_key: :user_id}
        }
      }

      result = Join.recurse_joins(source, domain)

      assert is_map(result)
      assert Map.has_key?(result, :posts)

      join = result[:posts]
      assert join.id == :posts
      assert join.name == "posts"
      assert join.source == "posts"
      assert join.owner_key == :id
      assert join.my_key == :user_id
      assert join.requires_join == :selecto_root
    end

    test "assigns unique ids to each join" do
      domain = %{
        schemas: %{
          posts: %{
            name: "Post",
            source_table: "posts",
            fields: [],
            redact_fields: [],
            columns: %{}
          },
          tags: %{name: "Tag", source_table: "tags", fields: [], redact_fields: [], columns: %{}}
        },
        joins: %{
          posts: %{type: :left},
          tags: %{type: :left}
        }
      }

      source = %{
        associations: %{
          posts: %{queryable: :posts, field: :posts, owner_key: :id, related_key: :user_id},
          tags: %{queryable: :tags, field: :tags, owner_key: :id, related_key: :post_id}
        }
      }

      result = Join.recurse_joins(source, domain)

      # Each join should have its key as the id
      Enum.each(result, fn {key, join} ->
        assert join.id == key
      end)
    end
  end

  describe "join type configurations" do
    test "dimension join creates custom columns configuration" do
      domain = %{
        schemas: %{
          categories: %{
            name: "Category",
            source_table: "categories",
            # Need field for dimension join
            fields: [:name],
            redact_fields: [],
            columns: %{
              name: %{type: :string}
            }
          }
        },
        joins: %{
          category: %{type: :dimension, dimension: :name, name: "Category"}
        }
      }

      source = %{
        associations: %{
          category: %{
            queryable: :categories,
            field: :category,
            owner_key: :category_id,
            related_key: :id
          }
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:category]

      # A dimension join is a star dimension whose display field is its
      # `dimension` key.
      assert join.join_type == :star_dimension
      assert join.display_field == :name
      custom_columns = join.config.custom_columns
      assert custom_columns["category_display"].name == "Category"
      assert custom_columns["category_display"].select == "category.name"
    end

    test "tagging join creates aggregation columns and filters" do
      domain = %{
        schemas: %{
          tags: %{
            name: "Tag",
            source_table: "tags",
            fields: [:id, :name, :post_id],
            redact_fields: [],
            columns: %{id: %{type: :integer}, name: %{type: :string}, post_id: %{type: :integer}}
          }
        },
        joins: %{
          tags: %{type: :tagging, tag_field: :name, name: "Tags"}
        }
      }

      source = %{
        associations: %{
          tags: %{queryable: :tags, field: :tags, owner_key: :id, related_key: :post_id}
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:tags]

      assert join.join_type == :tagging
      assert join.type == :left

      # Check custom columns for tag aggregation
      custom_columns = join.config.custom_columns
      assert Map.has_key?(custom_columns, "tags_list")
      assert custom_columns["tags_list"].name == "Tags List"
      assert custom_columns["tags_list"].select == {:string_agg, "tags.name", ", "}
      assert custom_columns["tags_list"].filterable == false

      # Check faceted filters
      custom_filters = join.config.custom_filters
      assert Map.has_key?(custom_filters, "tags_filter")
      assert custom_filters["tags_filter"].facet == true
      assert custom_filters["tags_filter"].filter_type == :multi_select
      assert custom_filters["tags_filter"].source_field == :name
    end

    test "hierarchical adjacency list join creates CTE column references" do
      domain = %{
        schemas: %{
          categories: %{
            name: "Category",
            source_table: "categories",
            fields: [:id, :parent_id, :name],
            redact_fields: [],
            columns: %{
              id: %{type: :integer},
              parent_id: %{type: :integer},
              name: %{type: :string}
            }
          }
        },
        joins: %{
          parent: %{type: :hierarchical, hierarchy_type: :adjacency_list, depth_limit: 3}
        }
      }

      source = %{
        associations: %{
          parent: %{
            queryable: :categories,
            field: :parent,
            owner_key: :parent_id,
            related_key: :id
          }
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:parent]

      assert join.join_type == :hierarchical_adjacency
      assert join.hierarchy_depth == 3

      # Check custom columns for hierarchy navigation
      custom_columns = join.config.custom_columns
      assert Map.has_key?(custom_columns, "parent_path")
      assert Map.has_key?(custom_columns, "parent_level")
      assert Map.has_key?(custom_columns, "parent_path_array")

      # Verify CTE references
      assert custom_columns["parent_path"].select == "parent.path"
      assert custom_columns["parent_level"].select == "parent.level"
      assert custom_columns["parent_level"].filterable == true
    end

    test "star dimension join creates OLAP-optimized configuration" do
      domain = %{
        schemas: %{
          customers: %{
            name: "Customer",
            source_table: "customers",
            fields: [:id, :full_name],
            redact_fields: [],
            columns: %{id: %{type: :integer}, full_name: %{type: :string}}
          }
        },
        joins: %{
          customer: %{type: :star_dimension, display_field: :full_name, name: "Customer"}
        }
      }

      source = %{
        associations: %{
          customer: %{
            queryable: :customers,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id
          }
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:customer]

      assert join.join_type == :star_dimension
      assert join.display_field == :full_name

      # Check custom columns optimized for OLAP
      custom_columns = join.config.custom_columns
      assert Map.has_key?(custom_columns, "customer_display")
      assert custom_columns["customer_display"].is_dimension == true
      assert custom_columns["customer_display"].select == "customer.full_name"

      # Check faceted filters
      custom_filters = join.config.custom_filters
      assert Map.has_key?(custom_filters, "customer_facet")
      assert custom_filters["customer_facet"].facet == true
      assert custom_filters["customer_facet"].is_dimension == true
      assert custom_filters["customer_facet"].filter_type == :select_facet
    end

    test "snowflake dimension join is a star dimension; normalization lists refuse" do
      domain = %{
        schemas: %{
          regions: %{
            name: "Region",
            source_table: "regions",
            fields: [:id, :name],
            redact_fields: [],
            columns: %{id: %{type: :integer}, name: %{type: :string}}
          }
        },
        joins: %{region: %{type: :snowflake_dimension, display_field: :name}}
      }

      source = %{
        associations: %{
          region: %{queryable: :regions, field: :region, owner_key: :region_id, related_key: :id}
        }
      }

      join = Join.recurse_joins(source, domain)[:region]
      assert join.join_type == :star_dimension
      assert join.display_field == :name

      listed =
        put_in(domain, [:joins, :region, :normalization_joins], [
          %{table: "countries", alias: "co"}
        ])

      assert_raise ArgumentError, ~r/normalization_joins were removed/, fn ->
        Join.recurse_joins(source, listed)
      end
    end
  end

  describe "join type defaults and variations" do
    test "hierarchical join defaults to adjacency list with depth 5" do
      domain = %{
        schemas: %{
          categories: %{
            name: "Category",
            source_table: "categories",
            fields: [:id, :parent_id],
            redact_fields: [],
            columns: %{id: %{type: :integer}, parent_id: %{type: :integer}}
          }
        },
        joins: %{
          # No hierarchy_type specified
          parent: %{type: :hierarchical}
        }
      }

      source = %{
        associations: %{
          parent: %{
            queryable: :categories,
            field: :parent,
            owner_key: :parent_id,
            related_key: :id
          }
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:parent]

      # Should default
      assert join.join_type == :hierarchical_adjacency
      # Should use default depth
      assert join.hierarchy_depth == 5
    end

    test "star dimension defaults display_field to :name" do
      domain = %{
        schemas: %{
          customers: %{
            name: "Customer",
            source_table: "customers",
            fields: [:id, :name],
            redact_fields: [],
            columns: %{id: %{type: :integer}, name: %{type: :string}}
          }
        },
        joins: %{
          # No display_field specified
          customer: %{type: :star_dimension}
        }
      }

      source = %{
        associations: %{
          customer: %{
            queryable: :customers,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id
          }
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:customer]

      # Should default to :name
      assert join.display_field == :name
    end

    test "join name defaults to id when not provided" do
      domain = %{
        schemas: %{
          posts: %{
            name: "Post",
            source_table: "posts",
            fields: [],
            redact_fields: [],
            columns: %{}
          }
        },
        joins: %{
          # No name provided
          posts: %{}
        }
      }

      source = %{
        associations: %{
          posts: %{queryable: :posts, field: :posts, owner_key: :id, related_key: :user_id}
        }
      }

      result = Join.recurse_joins(source, domain)
      join = result[:posts]

      # Should default to join id
      assert join.name == :posts
    end
  end

  describe "nested joins processing" do
    test "handles nested join configurations correctly" do
      domain = %{
        schemas: %{
          posts: %{
            name: "Post",
            source_table: "posts",
            fields: [],
            redact_fields: [],
            columns: %{},
            associations: %{
              tags: %{queryable: :tags, field: :tags, owner_key: :id, related_key: :post_id}
            }
          },
          tags: %{
            name: "Tag",
            source_table: "tags",
            fields: [:id, :name, :post_id],
            redact_fields: [],
            columns: %{id: %{type: :integer}, name: %{type: :string}, post_id: %{type: :integer}}
          }
        },
        joins: %{
          posts: %{
            type: :left,
            # Nested joins
            joins: %{
              tags: %{type: :tagging}
            }
          }
        }
      }

      source = %{
        associations: %{
          posts: %{queryable: :posts, field: :posts, owner_key: :id, related_key: :user_id}
        }
      }

      result = Join.recurse_joins(source, domain)

      # Should have both parent and nested join
      assert Map.has_key?(result, :posts)
      assert Map.has_key?(result, :tags)

      # Nested join should reference parent
      tags_join = result[:tags]
      assert tags_join.requires_join == :posts
      assert tags_join.join_type == :tagging
    end
  end

  describe "error handling" do
    test "handles missing association gracefully" do
      domain = %{
        schemas: %{},
        joins: %{
          nonexistent: %{type: :left}
        }
      }

      source = %{
        # Missing association
        associations: %{}
      }

      # Current implementation raises when it cannot dereference association config
      assert_raise(ArgumentError, ~r/invalid_domain/, fn ->
        Join.recurse_joins(source, domain)
      end)
    end

    test "handles missing queryable schema" do
      domain = %{
        # Missing schema
        schemas: %{},
        joins: %{
          posts: %{type: :left}
        }
      }

      source = %{
        associations: %{
          posts: %{queryable: :posts, field: :posts, owner_key: :id, related_key: :user_id}
        }
      }

      # Current implementation raises when queryable schema cannot be resolved
      assert_raise(ArgumentError, ~r/invalid_domain/, fn ->
        Join.recurse_joins(source, domain)
      end)
    end
  end
end
