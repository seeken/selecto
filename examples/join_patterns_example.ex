defmodule Selecto.Examples.JoinPatternsExample do
  @moduledoc """
  Example configurations of Selecto's native join sugar (see
  docs/join_families.md). Every join reads an association; the sugar
  normalises onto the shared types (left, inner, right, full,
  star_dimension).
  """

  # Example domain configuration showing different join patterns
  def example_domain do
    %{
      schemas: %{
        # Main entities
        SelectoExample.Store.Order => order_schema(),
        SelectoExample.Store.Product => product_schema(),
        SelectoExample.Store.Customer => customer_schema(),
        SelectoExample.Store.Category => category_schema(),
        SelectoExample.Store.Tag => tag_schema(),
        SelectoExample.Store.Employee => employee_schema(),
        SelectoExample.Store.Department => department_schema()
      },
      # Different join pattern examples
      joins: %{
        # Many-to-many tagging example (a join_through association)
        products: %{
          type: :tagging,
          tag_field: :name,
          name: "Product Tags"
        },

        # Star schema dimension example (typical OLAP setup)
        customer: %{
          type: :star_dimension,
          display_field: :full_name,
          name: "Customer Dimension"
        },

        # Snowflake dimension: a star dimension; further normalised tables
        # are nested associations joined under it
        category: %{
          type: :snowflake_dimension,
          display_field: :name,
          name: "Category",
          joins: %{group: %{type: :left}}
        },

        # Hierarchical adjacency list example (organizational chart;
        # PostgreSQL only)
        manager: %{
          type: :hierarchical,
          hierarchy_type: :adjacency_list,
          parent_field: :manager_id,
          depth_limit: 5,
          name: "Management Chain"
        },

        # A dimension is a star_dimension whose `dimension` key is its
        # display field
        region: %{
          type: :dimension,
          dimension: :name,
          name: "Sales Region"
        }
      }
    }
  end

  # Schema configurations
  defp order_schema do
    %{
      source_table: "orders",
      fields: [:id, :total, :order_date, :customer_id, :region_id],
      redact_fields: [],
      associations: %{
        customer: %{
          field: :customer,
          owner_key: :customer_id,
          related_key: :id,
          queryable: SelectoExample.Store.Customer
        },
        products: %{
          field: :products,
          cardinality: :many,
          join_through: "order_items",
          join_keys: [{:order_id, :id}, {:product_id, :id}],
          queryable: SelectoExample.Store.Product
        },
        region: %{
          field: :region,
          owner_key: :region_id,
          related_key: :id,
          queryable: SelectoExample.Store.Region
        }
      }
    }
  end

  defp product_schema do
    %{
      source_table: "products",
      fields: [:id, :name, :price, :category_id],
      redact_fields: [],
      associations: %{
        category: %{
          field: :category,
          owner_key: :category_id,
          related_key: :id,
          queryable: SelectoExample.Store.Category
        },
        tags: %{
          field: :tags,
          cardinality: :many,
          join_through: "product_tags",
          join_keys: [{:product_id, :id}, {:tag_id, :id}],
          queryable: SelectoExample.Store.Tag
        }
      }
    }
  end

  defp customer_schema do
    %{
      source_table: "customers",
      fields: [:id, :first_name, :last_name, :full_name, :email],
      redact_fields: [:email],
      associations: %{}
    }
  end

  defp category_schema do
    %{
      source_table: "categories",
      fields: [:id, :name, :parent_id, :group_id],
      redact_fields: [],
      associations: %{
        group: %{
          field: :group,
          owner_key: :group_id,
          related_key: :id,
          queryable: SelectoExample.Store.CategoryGroup
        }
      }
    }
  end

  defp tag_schema do
    %{
      source_table: "tags",
      fields: [:id, :name, :color],
      redact_fields: [],
      associations: %{}
    }
  end

  defp employee_schema do
    %{
      source_table: "employees",
      fields: [:id, :name, :manager_id, :department_id],
      redact_fields: [],
      associations: %{
        manager: %{
          field: :manager,
          owner_key: :manager_id,
          related_key: :id,
          queryable: SelectoExample.Store.Employee
        },
        department: %{
          field: :department,
          owner_key: :department_id,
          related_key: :id,
          queryable: SelectoExample.Store.Department
        }
      }
    }
  end

  defp department_schema do
    %{
      source_table: "departments",
      fields: [:id, :name, :parent_id],
      redact_fields: [],
      associations: %{}
    }
  end

  @doc """
  Example usage showing how the join configuration would be used:

  ## Tagging Example
  ```elixir
  # Products with their tags aggregated
  domain = example_domain()
  selecto = Selecto.new(SelectoExample.Store.Product, domain)
    |> Selecto.select([:name, :price, "tags_list"])  # Uses the custom column from tagging config
    |> Selecto.filter([{"tags_filter", ["electronics", "gadgets"]}])  # Uses the custom filter
  ```

  ## Hierarchical Example
  ```elixir
  # Employees with their management chain
  selecto = Selecto.new(SelectoExample.Store.Employee, domain)
    |> Selecto.select([:name, "manager_path", "manager_level"])  # Uses hierarchical custom columns
    |> Selecto.filter([{"manager_level", {"<=", 3}}])  # Show only up to 3 levels deep
  ```

  ## Star Schema Example
  ```elixir
  # Orders with customer dimension for OLAP analysis
  selecto = Selecto.new(SelectoExample.Store.Order, domain)
    |> Selecto.select([:total, :order_date, "customer_display"])  # Uses dimension display field
    |> Selecto.group_by(["customer_display"])
    |> Selecto.filter([{"customer_facet", ["premium_customers"]}])  # Uses faceted filter
  ```
  """
  def usage_examples do
    :ok
  end
end
