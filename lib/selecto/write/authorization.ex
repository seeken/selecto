defmodule Selecto.Write.Authorization do
  @moduledoc """
  Single-use proof that a governed entry point validated one exact write.

  A portable `Selecto.Write.Command`, `Selecto.Write.Batch`, or
  `Selecto.Write.Graph` is plain data that anyone can build. Domain governance
  happens in the governed entry point, `SelectoUpdato`, which validates the
  write against the governing domain's `writes` contract every time it
  executes. It then issues an authorization for exactly the validated payload
  and hands both to `Selecto.Write`. `Selecto.Write.execute/3`,
  `Selecto.Write.execute_prepared/3`, and the `execute_write/3` and
  `execute_prepared_write/3` callbacks of every write adapter refuse to run a
  write without one and return `{:error, %Selecto.Write.Error{type:
  :ungoverned_write}}`.

  An authorization is:

    * opaque: the struct only names an entry in the issuing process's
      registry, so building a lookalike authorizes nothing;
    * bound to the exact payload it was issued for: any change to the
      command, batch, or graph invalidates it;
    * single-use: the adapter consumes it before executing, and
      `Selecto.Write` revokes it once dispatch returns;
    * local to the process that issued it.

  Only the governed entry point may issue one; any other caller gets
  `:ungoverned_write`. Trusted tooling and adapter tests that must run a raw
  command use `Selecto.Write.execute_unsafe/3` or an adapter's
  `execute_write_unsafe/3` instead. Application code never needs either.

  Adapter authors call `require_for/2` at the top of `execute_write/3` and wrap
  a prepared write's preparation function with `governed_preparation/1`; see
  `Selecto.DB.WriteAdapter`.
  """

  alias Selecto.Write.{Batch, Command, Error, Graph}

  # The governed entry point. Like the caller check in selecto-perl's
  # Selecto::Write::Authorization, this keeps a raw caller from minting an
  # authorization for an arbitrary command instead of going through
  # governance. The module must call issue/1 from a non-tail position so its
  # frame is on the stack.
  @issuers [SelectoUpdato.GovernedWrite]

  @registry __MODULE__
  @pending {__MODULE__, :pending}

  @enforce_keys [:ref]
  @derive {Inspect, only: []}
  defstruct [:ref]

  @opaque t :: %__MODULE__{ref: reference()}

  @type subject :: Command.t() | Batch.t() | Graph.t()

  @doc false
  @spec issue(subject()) :: {:ok, t()} | {:error, Error.t()}
  def issue(subject) do
    cond do
      not issued_by_governed_entry_point?() ->
        {:error, ungoverned_error()}

      not governable?(subject) ->
        {:error,
         Error.new(:invalid_command, "only a portable write command, batch, or graph is governed")}

      true ->
        ref = make_ref()
        Process.put({@registry, ref}, subject)
        {:ok, %__MODULE__{ref: ref}}
    end
  end

  @doc """
  Consumes the authorization when it covers exactly `subject`.

  `authorization` is either the authorization itself or the keyword options
  passed to `execute_write/3`, which carry it under `:authorization`. Returns
  `:ok` once, for the payload the authorization was issued for, and
  `{:error, %Selecto.Write.Error{type: :ungoverned_write}}` otherwise.
  """
  @spec require_for(term(), t() | keyword() | nil) :: :ok | {:error, Error.t()}
  def require_for(subject, authorization) do
    with {:ok, key} <- authorized_key(subject, authorization) do
      Process.delete(key)
      :ok
    end
  end

  @doc """
  Checks, without consuming it, that `authorization` covers exactly `subject`.
  """
  @spec check(term(), t() | keyword() | nil) :: :ok | {:error, Error.t()}
  def check(subject, authorization) do
    with {:ok, _key} <- authorized_key(subject, authorization), do: :ok
  end

  @doc """
  Revokes an unused authorization. Revoking a consumed, revoked, or forged
  authorization does nothing.
  """
  @spec revoke(t() | keyword() | nil) :: :ok
  def revoke(authorization) do
    case authorization_ref(authorization) do
      {:ok, ref} -> Process.delete({@registry, ref})
      :error -> nil
    end

    :ok
  end

  @doc """
  Wraps a prepared write's preparation function for an adapter's governed
  `execute_prepared_write/3`.

  The governed entry point's preparation returns `{:ok, write, context,
  authorization}`. The wrapper consumes the authorization for that exact write
  and returns the `{:ok, write, context}` shape the adapter's unsafe
  implementation expects. A preparation that returns an unauthorized write
  yields `:ungoverned_write`; errors pass through unchanged.
  """
  @spec governed_preparation((term() -> term())) :: (term() -> term())
  def governed_preparation(prepare_fun) when is_function(prepare_fun, 1) do
    fn loader ->
      case prepare_fun.(loader) do
        {:ok, write, context, authorization} ->
          with :ok <- require_for(write, authorization), do: {:ok, write, context}

        {:ok, _write, _context} ->
          {:error, ungoverned_error()}

        other ->
          other
      end
    end
  end

  @doc false
  # Selecto.Write.execute_prepared/3 checks the preparation's authorization
  # before the adapter sees it and revokes it if the adapter leaves it unused.
  @spec dispatch_prepared((term() -> term()), ((term() -> term()) -> result)) :: result
        when result: term()
  def dispatch_prepared(prepare_fun, dispatch)
      when is_function(prepare_fun, 1) and is_function(dispatch, 1) do
    marker = make_ref()

    checked = fn loader ->
      case prepare_fun.(loader) do
        {:ok, write, _context, authorization} = result ->
          with :ok <- check(write, authorization) do
            Process.put({@pending, marker}, authorization)
            result
          end

        {:ok, _write, _context} ->
          {:error, ungoverned_error()}

        other ->
          other
      end
    end

    try do
      dispatch.(checked)
    after
      revoke(Process.delete({@pending, marker}))
    end
  end

  @doc false
  @spec ungoverned_error() :: Error.t()
  def ungoverned_error do
    Error.new(
      :ungoverned_write,
      "writes run through a governed entry point such as SelectoUpdato; " <>
        "trusted tooling may use the *_unsafe functions"
    )
  end

  defp authorized_key(subject, authorization) do
    with {:ok, ref} <- authorization_ref(authorization),
         key = {@registry, ref},
         issued when issued !== nil <- Process.get(key),
         true <- governable?(subject) and issued === subject do
      {:ok, key}
    else
      _ -> {:error, ungoverned_error()}
    end
  end

  defp authorization_ref(%__MODULE__{ref: ref}) when is_reference(ref), do: {:ok, ref}

  defp authorization_ref(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: authorization_ref(Keyword.get(opts, :authorization)),
      else: :error
  end

  defp authorization_ref(_authorization), do: :error

  defp governable?(%Command{}), do: true
  defp governable?(%Batch{}), do: true
  defp governable?(%Graph{}), do: true
  defp governable?(_subject), do: false

  defp issued_by_governed_entry_point? do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)

    frames
    |> Enum.drop_while(fn {module, _function, _arity, _location} ->
      module in [__MODULE__, Process]
    end)
    |> case do
      [{module, _function, _arity, _location} | _frames] -> module in @issuers
      [] -> false
    end
  end
end
