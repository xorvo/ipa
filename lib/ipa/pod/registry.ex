defmodule Ipa.PodRegistry do
  @moduledoc """
  Registry for tracking active pods.

  Uses Elixir's built-in Registry with:
  - Unique keys (one pod per task_id)
  - Automatic cleanup on process termination
  - Fast ETS-based lookup

  Registry keys follow the pattern `{:pod, task_id}` where task_id is a string.
  Each pod stores metadata including status, started_at timestamp, and restart count.
  """

  @doc """
  Starts the registry.

  This function is called by the application supervision tree.
  """
  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @doc """
  Returns the child specification for the registry.

  This is used by the supervision tree to start the registry.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Registers a pod with the given task_id and metadata.

  ## Parameters
    - `task_id` - Unique identifier for the task
    - `metadata` - Map containing pod metadata (status, started_at, restarts)

  ## Returns
    - `{:ok, pid}` - Successfully registered
    - `{:error, {:already_registered, pid}}` - Pod already registered

  ## Examples

      iex> Ipa.PodRegistry.register("task-123", %{status: :starting, started_at: 1699564800})
      {:ok, #PID<0.123.0>}

      iex> Ipa.PodRegistry.register("task-123", %{status: :starting, started_at: 1699564800})
      {:error, {:already_registered, #PID<0.123.0>}}
  """
  def register(task_id, metadata \\ %{}) do
    Registry.register(__MODULE__, {:pod, task_id}, metadata)
  end

  @doc """
  Unregisters a pod with the given task_id.

  This is typically called automatically when a pod terminates.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `:ok` - Successfully unregistered

  ## Examples

      iex> Ipa.PodRegistry.unregister("task-123")
      :ok
  """
  def unregister(task_id) do
    Registry.unregister(__MODULE__, {:pod, task_id})
  end

  @doc """
  Looks up a pod by task_id.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `{:ok, pid, metadata}` - Pod found
    - `{:error, :not_found}` - Pod not found

  ## Examples

      iex> Ipa.PodRegistry.lookup("task-123")
      {:ok, #PID<0.123.0>, %{status: :active, started_at: 1699564800}}

      iex> Ipa.PodRegistry.lookup("nonexistent")
      {:error, :not_found}
  """
  def lookup(task_id) do
    case Registry.lookup(__MODULE__, {:pod, task_id}) do
      [{pid, metadata}] -> {:ok, pid, metadata}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all registered pods.

  ## Returns
    - List of tuples `{{:pod, task_id}, pid, metadata}`

  ## Examples

      iex> Ipa.PodRegistry.list_all()
      [
        {{:pod, "task-1"}, #PID<0.123.0>, %{status: :active, started_at: 1699564800}},
        {{:pod, "task-2"}, #PID<0.124.0>, %{status: :active, started_at: 1699564805}}
      ]
  """
  def list_all do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Updates the metadata for a registered pod.

  ## Parameters
    - `task_id` - Unique identifier for the task
    - `metadata` - New metadata map

  ## Returns
    - `:ok` - Successfully updated
    - `{:error, :not_found}` - Pod not found

  ## Examples

      iex> Ipa.PodRegistry.update_meta("task-123", %{status: :active})
      :ok
  """
  def update_meta(task_id, metadata) do
    case lookup(task_id) do
      {:ok, _pid, _old_meta} ->
        Registry.update_value(__MODULE__, {:pod, task_id}, fn _ -> metadata end)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Counts the number of registered pods.

  ## Returns
    - Integer count of registered pods

  ## Examples

      iex> Ipa.PodRegistry.count()
      3
  """
  def count do
    __MODULE__
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [true]}])
    |> length()
  end
end
