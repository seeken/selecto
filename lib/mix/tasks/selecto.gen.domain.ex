defmodule Mix.Tasks.Selecto.Gen.Domain do
  @moduledoc "The hello mix task: `mix help hello`"
  use Mix.Task

  @shortdoc "Generate a Selecto Domain module."
  def run(args) do
    # calling our Hello.say() function from earlier
    IO.puts("HERE")

    {_parsed, rest} = OptionParser.parse!(args)

    IO.inspect( rest )

  end
end
