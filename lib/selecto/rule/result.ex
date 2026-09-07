defmodule Selecto.Rule.Result do
  @moduledoc """
  Deterministic result from evaluating a compiled Selecto data-rule contract.

  `:passed` is the only disposition that authorizes a required rule boundary.
  Other dispositions remain distinct so hosts cannot turn pending, unsupported,
  or failed work into truthy success.
  """

  @type disposition ::
          :passed | :failed | :pending | :unsupported | :error | :not_applicable

  @type t :: %__MODULE__{
          schema: String.t(),
          disposition: disposition(),
          values: term(),
          outcomes: [map()],
          obligations: [map()]
        }

  defstruct schema: "selecto.rule_evaluation_result.v1",
            disposition: :passed,
            values: %{},
            outcomes: [],
            obligations: []
end
