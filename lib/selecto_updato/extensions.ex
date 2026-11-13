defmodule SelectoUpdato.Extensions do
  @moduledoc """
  `selecto_updato` extension integration helpers.
  """

  @spec apply_domain_extensions(map()) :: {map(), [{module(), keyword()}]}
  def apply_domain_extensions(%{} = domain) do
    specs = Selecto.Extensions.from_domain(domain)
    {Selecto.Extensions.merge_updato_domain_extensions(domain, specs), specs}
  end

  def apply_domain_extensions(domain), do: {domain, []}
end
