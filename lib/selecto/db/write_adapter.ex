defmodule Selecto.DB.WriteAdapter do
  @moduledoc """
  Optional write behavior for a `Selecto.DB.Adapter` implementation.

  Implementing this behavior means the adapter can preserve the complete
  semantics of a portable `Selecto.Write.Command` or atomic
  `Selecto.Write.Batch`/`Selecto.Write.Graph`. Read-only adapters simply omit it.

  ## Governed execution

  `execute_write/3` and `execute_prepared_write/3` are the governed entry
  points. They must refuse any write that does not carry a
  `Selecto.Write.Authorization` for exactly that payload, returning
  `{:error, %Selecto.Write.Error{type: :ungoverned_write}}` before touching the
  database. Only the governed entry point (`SelectoUpdato`) issues
  authorizations, so a raw command handed to an adapter cannot skip domain
  governance.

  The raw implementations live in `execute_write_unsafe/3` and
  `execute_prepared_write_unsafe/3`, reserved for trusted tooling and adapter
  tests. A conforming adapter delegates:

      @impl Selecto.DB.WriteAdapter
      def execute_write(connection, write, opts) do
        with :ok <- Selecto.Write.Authorization.require_for(write, opts) do
          execute_write_unsafe(connection, write, opts)
        end
      end

      @impl Selecto.DB.WriteAdapter
      def execute_prepared_write(connection, prepare_fun, opts)
          when is_function(prepare_fun, 1) do
        execute_prepared_write_unsafe(
          connection,
          Selecto.Write.Authorization.governed_preparation(prepare_fun),
          opts
        )
      end

  `preview_write/3` compiles without executing and needs no authorization.
  """

  @type connection :: term()
  @type command ::
          Selecto.Write.Command.t() | Selecto.Write.Batch.t() | Selecto.Write.Graph.t()
  @type execution_result :: Selecto.Write.Result.t() | [Selecto.Write.Result.t()]
  @type prepared_state_loader ::
          (Selecto.Write.CandidateRequest.t() ->
             {:ok, Selecto.Write.CandidateState.t()} | {:error, Selecto.Write.Error.t()})
          | (Selecto.Write.RecordRequest.t() ->
               {:ok, Selecto.Write.RecordState.t()} | {:error, Selecto.Write.Error.t()})
          | (Selecto.Write.RuleCandidateRequest.t() ->
               {:ok, Selecto.Write.RecordState.t()} | {:error, Selecto.Write.Error.t()})
          | (Selecto.Write.UpsertCandidateRequest.t() ->
               {:ok, Selecto.Write.UpsertCandidateState.t()} | {:error, Selecto.Write.Error.t()})
  @typedoc "A governed preparation: returns the write with its authorization."
  @type prepare_fun ::
          (prepared_state_loader() ->
             {:ok, command(), map(), Selecto.Write.Authorization.t()}
             | {:error, Selecto.Write.Error.t()}
             | {:error, term()})
  @typedoc "An unsafe preparation for trusted tooling: returns the raw write."
  @type unsafe_prepare_fun ::
          (prepared_state_loader() ->
             {:ok, command(), map()} | {:error, Selecto.Write.Error.t()} | {:error, term()})

  @callback write_capabilities(connection()) :: map()

  @callback preview_write(connection(), command(), keyword()) ::
              {:ok, Selecto.Write.Preview.t()} | {:error, Selecto.Write.Error.t()}

  @doc """
  Executes a governed write. `opts[:authorization]` must cover exactly the
  write; otherwise the adapter returns `:ungoverned_write` without executing.
  """
  @callback execute_write(connection(), command(), keyword()) ::
              {:ok, execution_result()} | {:error, Selecto.Write.Error.t()}

  @doc "Executes a write without domain governance. Trusted tooling and adapter tests only."
  @callback execute_write_unsafe(connection(), command(), keyword()) ::
              {:ok, execution_result()} | {:error, Selecto.Write.Error.t()}

  @doc """
  Executes a governed prepared write. The preparation must return the write
  with an authorization for it; otherwise the adapter returns
  `:ungoverned_write` and rolls back.
  """
  @callback execute_prepared_write(connection(), prepare_fun(), keyword()) ::
              {:ok, execution_result()} | {:error, Selecto.Write.Error.t()} | {:error, term()}

  @doc "Executes a prepared write without domain governance. Trusted tooling and adapter tests only."
  @callback execute_prepared_write_unsafe(connection(), unsafe_prepare_fun(), keyword()) ::
              {:ok, execution_result()} | {:error, Selecto.Write.Error.t()} | {:error, term()}

  @doc "Prepares a preview against protected native state, always rolling back private projections."
  @callback preview_prepared_write(connection(), unsafe_prepare_fun(), keyword()) ::
              {:ok, Selecto.Write.Preview.t()}
              | {:error, Selecto.Write.Error.t()}
              | {:error, term()}

  @optional_callbacks preview_prepared_write: 3,
                      execute_write_unsafe: 3,
                      execute_prepared_write: 3,
                      execute_prepared_write_unsafe: 3
end
