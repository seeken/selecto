defmodule Mix.Tasks.Selecto.Gen.Domain do
  @moduledoc "The hello mix task: `mix help hello`"
  use Mix.Task

  @shortdoc "Simply calls the Hello.say/0 function."
  def run(_) do
    # calling our Hello.say() function from earlier
    IO.puts("HERE")
  end
end
