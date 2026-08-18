defmodule Selecto.Context do
  @moduledoc """
  Small adapters for building Phoenix-style contexts on top of Selecto.

  This module keeps context code focused on application policy by handling
  common boundary plumbing:

  * execute reads as maps with atom-safe keys
  * distinguish one, none, and many read results
  * normalize string- or atom-keyed input against an explicit allowlist
  * unwrap one returned record from a portable write result

  It deliberately does not infer authorization or tenant filters from a
  Phoenix scope. The host context must translate its caller scope into Selecto
  filters and the write context required by its domain.

  The module has no Phoenix, Ecto, or Selecto Updato dependency. `write_one/2`
  consumes the core `%Selecto.Write.Result{}` returned after a governed write
  has been compiled and executed by a companion such as Selecto Updato.
  """

  alias Selecto.Output.Formats
  alias Selecto.Write.Result

  @map_option_keys [:keys, :transform, :coerce_types, :null_handling]

  @type context_record :: %{optional(atom() | String.t()) => term()}
  @type read_error :: Selecto.Error.t() | :not_found | :multiple_results
  @type write_error ::
          term() | :no_returned_record | :multiple_returned_records | :invalid_write_result

  @doc """
  Executes a Selecto query and returns records as maps.

  Existing atom keys are used by default. Unknown result names remain strings;
  this function never creates atoms from database or user-controlled values.

  Map formatter options (`:keys`, `:transform`, `:coerce_types`, and
  `:null_handling`) may be supplied alongside normal `Selecto.execute/2`
  options.
  """
  @spec all(Selecto.t(), keyword()) :: {:ok, [context_record()]} | {:error, Selecto.Error.t()}
  def all(%Selecto{} = selecto, opts \\ []) when is_list(opts) do
    {map_opts, execute_opts} = Keyword.split(opts, @map_option_keys)

    execute_opts =
      execute_opts
      |> Keyword.delete(:format)
      |> Keyword.delete(:format_options)
      |> Keyword.put(:format, {:maps, Keyword.put_new(map_opts, :keys, :atoms)})

    Selecto.execute(selecto, execute_opts)
  end

  @doc """
  Executes a Selecto query that must return exactly one map.

  Returns `{:error, :not_found}` for no rows and
  `{:error, :multiple_results}` for more than one row. Database and
  transformation errors remain `%Selecto.Error{}` values.
  """
  @spec one(Selecto.t(), keyword()) :: {:ok, context_record()} | {:error, read_error()}
  def one(%Selecto{} = selecto, opts \\ []) when is_list(opts) do
    case all(selecto, opts) do
      {:ok, [record]} -> {:ok, record}
      {:ok, []} -> {:error, :not_found}
      {:ok, _records} -> {:error, :multiple_results}
      {:error, %Selecto.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Takes explicitly allowed attributes and normalizes their keys to atoms.

  Both atom and string input keys are accepted without dynamically creating
  atoms. If both forms are present, the atom-keyed value wins. Unknown fields
  are ignored.

  ## Example

      Selecto.Context.take_attrs(
        %{"name" => "Alpha", status: "active", "admin" => true},
        [:name, :status]
      )
      # => %{name: "Alpha", status: "active"}
  """
  @spec take_attrs(map(), [atom()]) :: %{optional(atom()) => term()}
  def take_attrs(attrs, allowed_fields) when is_map(attrs) and is_list(allowed_fields) do
    Enum.reduce(allowed_fields, %{}, fn field, selected ->
      unless is_atom(field) do
        raise ArgumentError, "allowed context fields must be atoms, got: #{inspect(field)}"
      end

      cond do
        Map.has_key?(attrs, field) ->
          Map.put(selected, field, Map.fetch!(attrs, field))

        Map.has_key?(attrs, Atom.to_string(field)) ->
          Map.put(selected, field, Map.fetch!(attrs, Atom.to_string(field)))

        true ->
          selected
      end
    end)
  end

  @doc """
  Unwraps exactly one returned map from a portable write result.

  The function accepts either a `%Selecto.Write.Result{}` or the tagged result
  returned by a write executor, which makes this pipeline possible:

      operation
      |> SelectoUpdato.execute(selecto)
      |> Selecto.Context.write_one()

  Keys use the same atom-safe behavior as `all/2`. Unknown returned column
  names remain strings.
  """
  @spec write_one(Result.t() | {:ok, Result.t()} | {:error, term()}, keyword()) ::
          {:ok, context_record()} | {:error, write_error()}
  def write_one(result, opts \\ [])

  def write_one({:ok, %Result{} = result}, opts), do: write_one(result, opts)
  def write_one({:error, reason}, _opts), do: {:error, reason}

  def write_one(%Result{rows: [record]}, opts) when is_map(record) do
    transform_record(record, opts)
  end

  def write_one(%Result{rows: []}, _opts), do: {:error, :no_returned_record}

  def write_one(%Result{rows: records}, _opts) when is_list(records),
    do: {:error, :multiple_returned_records}

  def write_one(_result, _opts), do: {:error, :invalid_write_result}

  defp transform_record(record, opts) do
    columns = Map.keys(record)
    row = Enum.map(columns, &Map.fetch!(record, &1))
    map_opts = opts |> Keyword.take(@map_option_keys) |> Keyword.put_new(:keys, :atoms)

    case Formats.transform({[row], columns, %{}}, {:maps, map_opts}) do
      {:ok, [transformed]} ->
        {:ok, transformed}

      {:error, reason} ->
        {:error,
         Selecto.Error.transformation_error("Context write result transformation failed", %{
           error: reason
         })}
    end
  end
end
