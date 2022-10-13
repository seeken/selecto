defmodule Listable.Components do

  use Phoenix.Component

  def view_panel(assigns) do
    ~H"""
      <div>
      View <%= inspect(@listable) %>
      </div>
    """
  end

  def filter_panel(assigns) do
    ~H"""
      <div>
      Filter <%= @listable.repo %>
      </div>
    """
  end

  def results_panel(assigns) do
    results = Listable.execute( assigns.listable )
    assigns = assign( assigns, results: results)
    ~H"""
      <div>
      Results <%= inspect( @results ) %>
      </div>
    """
  end

end