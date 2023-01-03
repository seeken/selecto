defmodule Mix.Tasks.Selecto.Gen.Domain do
  @moduledoc "The hello mix task: `mix help hello`"
  use Mix.Task

  @doc """
  switches:
   --db get metadata from the DB instead of ecto
   --extender module #source a module to integrate into this domain
   --join table:local_key:remote_key:extender
   --umb_live app:module #same as below, for umbrella apps
   --live module #create liveview module and component (require selecto_components)
   source
   module_name


  """

  @shortdoc "Generate a Selecto Domain module."
  def run(args) do
    # calling our Hello.say() function from earlier
    IO.puts("HERE")

    {_parsed, rest} = OptionParser.parse!(args)

    IO.inspect( rest )

  end
end
