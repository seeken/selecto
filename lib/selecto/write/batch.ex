defmodule Selecto.Write.Batch do
  @moduledoc "An atomic, ordered collection of portable write commands."

  alias Selecto.Write.{Command, Error}

  @type t :: %__MODULE__{commands: [Command.t()], atomic?: true, metadata: map()}

  @enforce_keys [:commands]
  defstruct commands: [], atomic?: true, metadata: %{}

  @spec new([Command.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(commands, opts \\ []) when is_list(commands) and is_list(opts) do
    batch = %__MODULE__{
      commands: commands,
      atomic?: Keyword.get(opts, :atomic?, true),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(batch) do
      :ok -> {:ok, batch}
      {:error, _} = error -> error
    end
  end

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{commands: commands, atomic?: true, metadata: metadata})
      when is_list(commands) and is_map(metadata) do
    if commands == [] do
      {:error, Error.new(:invalid_command, "write batch must contain at least one command")}
    else
      commands
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {command, index}, :ok ->
        case Command.validate(command) do
          :ok ->
            {:cont, :ok}

          {:error, %Error{} = error} ->
            {:halt, {:error, %{error | details: Map.put(error.details, :command_index, index)}}}
        end
      end)
    end
  end

  def validate(%__MODULE__{} = batch) do
    {:error,
     Error.new(:invalid_command, "write batches must be atomic and have map metadata",
       details: %{atomic?: batch.atomic?, metadata: batch.metadata}
     )}
  end
end
