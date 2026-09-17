defmodule Selecto.FieldPolicy do
  @moduledoc """
  Resolves a governed field profile into effective UI states.

  Visibility, write authority, request-scoped capability decisions, and current
  record eligibility are evaluated independently. The result is presentation
  metadata only; write execution must still enforce the domain contract.
  """

  alias Selecto.Domain
  alias Selecto.Error

  @enforce_keys [:domain, :authorize]
  defstruct [:domain, :authorize]

  @operations ~w(insert update upsert view)
  @modes ~w(auto hidden read_only editable action)
  @entry_keys ~w(field label control required nullable placeholder rows options mode action view_capability edit_capability eligible reason)

  @type t :: %__MODULE__{domain: map(), authorize: (map() -> map())}

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(domain, opts \\ []) do
    authorize = Keyword.get(opts, :authorize, fn _request -> %{status: :enabled} end)

    with true <- is_function(authorize, 1),
         {:ok, normalized, _diagnostics} <- Domain.validate(domain) do
      {:ok, %__MODULE__{domain: normalized, authorize: authorize}}
    else
      false ->
        invalid("field policy authorize must be a one-arity function")

      {:error, diagnostics} ->
        invalid("field policy requires a valid Selecto domain", %{diagnostics: diagnostics})
    end
  end

  @spec resolve(t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def resolve(%__MODULE__{} = policy, opts) do
    operation = opts |> Keyword.get(:operation, :update) |> id()
    profile = Keyword.get(opts, :profile)
    snapshot = Keyword.get(opts, :snapshot, %{})

    cond do
      operation not in @operations ->
        invalid("field policy operation is not supported", %{operation: operation})

      not is_list(profile) ->
        invalid("field policy profile must be a list")

      not is_map(snapshot) ->
        invalid("field policy snapshot must be a map")

      true ->
        resolve_entries(policy, profile, snapshot, operation, opts)
    end
  end

  @spec visible(t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def visible(policy, opts) do
    with {:ok, fields} <- resolve(policy, opts) do
      {:ok, Enum.reject(fields, &(&1.state == :hidden))}
    end
  end

  @spec accepted_fields(t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def accepted_fields(policy, opts) do
    with {:ok, fields} <- resolve(policy, opts) do
      {:ok, for(field <- fields, field.state == :editable, do: field.field)}
    end
  end

  defp resolve_entries(policy, profile, snapshot, operation, opts) do
    profile
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {raw, index}, {:ok, acc, seen} ->
      entry = if is_atom(raw) or is_binary(raw), do: %{field: raw}, else: raw

      with :ok <- valid_entry(entry, index),
           field when is_binary(field) <- id(get(entry, :field)),
           false <- MapSet.member?(seen, field),
           {:ok, definition} <- field_definition(policy.domain, field),
           {:ok, view} <-
             decision(
               policy,
               get(entry, :view_capability),
               :view,
               field,
               operation,
               snapshot,
               opts
             ),
           {:ok, edit} <-
             decision(
               policy,
               get(entry, :edit_capability),
               :edit,
               field,
               operation,
               snapshot,
               opts
             ) do
        resolved =
          resolve_entry(policy.domain, entry, field, definition, snapshot, operation, view, edit)

        {:cont, {:ok, acc ++ [resolved], MapSet.put(seen, field)}}
      else
        true ->
          {:halt, invalid("field policy profile contains a duplicate field", %{index: index})}

        nil ->
          {:halt, invalid("field policy field is invalid", %{index: index})}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, fields, _seen} -> {:ok, fields}
      error -> error
    end
  end

  defp valid_entry(entry, index) when is_map(entry) do
    unknown = Enum.reject(Map.keys(entry), &(to_string(&1) in @entry_keys))

    cond do
      unknown != [] ->
        invalid_entry("field policy profile contains unsupported settings", index, %{
          settings: unknown
        })

      Enum.any?(~w(required nullable eligible)a, fn key ->
        present?(entry, key) and not is_boolean(get(entry, key))
      end) ->
        invalid_entry("field policy boolean setting is invalid", index)

      present?(entry, :rows) and
          (not is_integer(get(entry, :rows)) or get(entry, :rows) not in 2..20) ->
        invalid_entry("field policy rows must be from 2 to 20", index)

      present?(entry, :options) and not is_list(get(entry, :options)) ->
        invalid_entry("field policy options must be a list", index)

      id(get(entry, :mode) || :auto) not in @modes ->
        invalid_entry("field policy mode is not supported", index)

      true ->
        :ok
    end
  end

  defp valid_entry(_entry, index),
    do: invalid_entry("field policy profile entries must be maps", index)

  defp resolve_entry(domain, entry, field, definition, snapshot, operation, view, edit) do
    public? = not definition.internal?
    requested_mode = id(get(entry, :mode) || :auto)
    root? = definition.root?
    writes = domain.writes || %{}
    operation_spec = fetch(get(writes, :operations), operation)

    operation_enabled? =
      operation != "view" and is_map(operation_spec) and get(operation_spec, :enabled) == true

    write_spec = if root?, do: fetch(get(writes, :fields), field) || %{}, else: %{}
    permission = if operation in ~w(insert upsert), do: :insertable, else: :updatable
    writable? = operation_enabled? and root? and get(write_spec, permission) == true
    eligible? = not present?(entry, :eligible) or get(entry, :eligible) == true

    {state, reason, reason_code} =
      cond do
        not public? ->
          {:hidden, nil, "field_not_public"}

        requested_mode == "hidden" ->
          {:hidden, nil, "profile_hidden"}

        status(view) != :enabled ->
          {:hidden, get(view, :reason), get(view, :reason_code) || "view_denied"}

        requested_mode == "action" or present?(entry, :action) ->
          action_state(entry, edit, eligible?)

        requested_mode == "read_only" ->
          {:read_only, get(entry, :reason), "profile_read_only"}

        not writable? ->
          {:read_only, get(entry, :reason), "write_not_permitted"}

        status(edit) != :enabled ->
          {:read_only, get(entry, :reason) || get(edit, :reason),
           get(edit, :reason_code) || "edit_denied"}

        not eligible? ->
          {:read_only, get(entry, :reason), "state_ineligible"}

        true ->
          {:editable, nil, nil}
      end

    type = definition.type

    required? =
      get(entry, :required) == true or
        (operation in ~w(insert upsert) and get(write_spec, :required) == true)

    %{
      field: field,
      label: get(entry, :label) || definition.label || humanize(field),
      type: type,
      state: state,
      control: get(entry, :control) || control_for(type),
      required: required?,
      nullable: get(entry, :nullable) == true,
      writable: writable?,
      value: fetch(snapshot, field)
    }
    |> maybe_put(:action, id(get(entry, :action)))
    |> maybe_put(:placeholder, get(entry, :placeholder))
    |> maybe_put(:rows, get(entry, :rows))
    |> maybe_put(:options, get(entry, :options))
    |> maybe_put(:view_capability, get(entry, :view_capability))
    |> maybe_put(:edit_capability, get(entry, :edit_capability))
    |> maybe_put(:reason, reason)
    |> maybe_put(:reason_code, reason_code)
  end

  defp action_state(entry, edit, eligible?) do
    if status(edit) == :enabled and eligible? do
      {:action_backed, nil, nil}
    else
      reason =
        get(entry, :reason) || get(edit, :reason) || "This workflow is not currently available."

      code = if eligible?, do: get(edit, :reason_code) || "edit_denied", else: "state_ineligible"
      {:read_only, reason, code}
    end
  end

  defp decision(_policy, nil, _phase, _field, _operation, _snapshot, _opts),
    do: {:ok, %{status: :enabled}}

  defp decision(_policy, "", _phase, _field, _operation, _snapshot, _opts),
    do: {:ok, %{status: :enabled}}

  defp decision(policy, capability, phase, field, operation, snapshot, opts) do
    value =
      policy.authorize.(%{
        capability: to_string(capability),
        phase: phase,
        field: field,
        operation: operation,
        context: Keyword.get(opts, :context),
        snapshot: snapshot
      })

    if is_map(value) and status(value) in [:enabled, :disabled, :hidden] do
      {:ok, value}
    else
      invalid("field policy authorization returned an invalid decision", %{
        field: field,
        capability: capability
      })
    end
  rescue
    _ -> invalid("field policy authorization failed", %{field: field, capability: capability})
  end

  defp field_definition(domain, field) do
    parts = String.split(field, ".")
    source = domain.source || %{}

    case parts do
      [name] ->
        column_definition(source, name, true)

      [association, name] ->
        assoc = fetch(get(source, :associations), association)
        schema = if is_map(assoc), do: fetch(domain.schemas || %{}, get(assoc, :queryable))
        column_definition(schema, name, false)

      _ ->
        invalid("field policy references an unknown field", %{field: field})
    end
  end

  defp column_definition(container, name, root?) do
    column = if is_map(container), do: fetch(get(container, :columns), name)

    if is_map(column) do
      {:ok,
       %{
         root?: root?,
         type: id(get(column, :type) || :string),
         label: get(column, :label),
         internal?: get(column, :internal) == true
       }}
    else
      invalid("field policy references an unknown field", %{field: name})
    end
  end

  defp status(value) do
    case value |> get(:status) |> id() do
      "enabled" -> :enabled
      "disabled" -> :disabled
      "hidden" -> :hidden
      _ -> nil
    end
  end

  defp control_for(type) when type == "boolean", do: "checkbox"

  defp control_for(type)
       when type in ~w(integer bigint smallint decimal number float double numeric), do: "number"

  defp control_for("date"), do: "date"

  defp control_for(type) when type in ~w(datetime utc_datetime naive_datetime),
    do: "datetime-local"

  defp control_for(_), do: "text"

  defp humanize(value),
    do:
      value
      |> String.replace([".", "_"], " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

  defp invalid_entry(message, index, details \\ %{}),
    do: invalid(message, Map.put(details, :index, index))

  defp invalid(message, details \\ %{}),
    do: {:error, Error.validation_error(message, Map.put(details, :code, :invalid_field_policy))}

  defp id(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp id(value) when is_binary(value) and value != "", do: value
  defp id(_), do: nil
  defp get(value, key) when is_map(value), do: Map.get(value, key, Map.get(value, to_string(key)))
  defp get(_, _), do: nil

  defp fetch(value, key) when is_map(value),
    do:
      Enum.find_value(value, fn {candidate, entry} -> if id(candidate) == id(key), do: entry end)

  defp fetch(_, _), do: nil

  defp present?(value, key) when is_map(value),
    do: Map.has_key?(value, key) or Map.has_key?(value, to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
