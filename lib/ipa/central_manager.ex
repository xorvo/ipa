defmodule Ipa.CentralManager do
  @moduledoc """
  Central Task Manager (Component 3.1)

  Manages pod lifecycle from a central location. This is the main entry point
  for creating, starting, stopping, and listing tasks/pods.

  This module provides:
  - Task creation with event store initialization
  - Pod lifecycle management (start/stop)
  - Task listing with summary information
  - Active pod queries

  ## Architecture

  The CentralManager delegates pod supervision to `Ipa.PodSupervisor` (DynamicSupervisor)
  and task state to `Ipa.Pod.Manager`. It provides a unified API for the Central Dashboard UI.

  ## Examples

      # Create a new task
      {:ok, task_id} = Ipa.CentralManager.create_task("Build authentication system", "user-123")

      # Start the pod for the task
      {:ok, pod_pid} = Ipa.CentralManager.start_pod(task_id)

      # List all tasks with their status
      tasks = Ipa.CentralManager.list_tasks()

      # Stop a pod
      :ok = Ipa.CentralManager.stop_pod(task_id)
  """

  require Logger

  alias Ipa.EventStore
  alias Ipa.PodSupervisor

  @doc """
  Creates a new task with the given title.

  This creates an event stream for the task and appends the initial `task_created` event.
  The task is created but the pod is not started - call `start_pod/1` to start it.

  ## Parameters
    - `title` - The title/description of the task
    - `created_by` - User ID of who created the task

  ## Returns
    - `{:ok, task_id}` - Task created successfully
    - `{:error, reason}` - Failed to create task

  ## Examples

      iex> {:ok, task_id} = Ipa.CentralManager.create_task("Implement user auth", "user-123")
      iex> is_binary(task_id)
      true
  """
  def create_task(title, created_by) when is_binary(title) and is_binary(created_by) do
    task_id = generate_task_id()

    with {:ok, ^task_id} <- EventStore.start_stream("task", task_id),
         {:ok, _version} <- EventStore.append(
           task_id,
           "task_created",
           %{title: title, created_by: created_by},
           actor_id: created_by
         ) do
      Logger.info("Created task #{task_id}: #{title}")
      {:ok, task_id}
    else
      {:error, reason} ->
        Logger.error("Failed to create task: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts a pod for the given task.

  The task must exist (created via `create_task/2` or have an existing event stream).
  Starting a pod initializes all pod components (State Manager, etc.) and begins
  processing the task.

  ## Parameters
    - `task_id` - The task ID to start a pod for

  ## Returns
    - `{:ok, pid}` - Pod started successfully
    - `{:error, :already_started}` - Pod is already running
    - `{:error, :stream_not_found}` - Task doesn't exist
    - `{:error, reason}` - Other error

  ## Examples

      iex> {:ok, pid} = Ipa.CentralManager.start_pod("task-uuid-123")
      iex> is_pid(pid)
      true
  """
  def start_pod(task_id) when is_binary(task_id) do
    case PodSupervisor.start_pod(task_id) do
      {:ok, pid} ->
        Logger.info("Started pod for task #{task_id}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.warning("Failed to start pod for task #{task_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops a running pod.

  This gracefully shuts down the pod and all its components.
  The task data remains in the event store and can be resumed later.

  ## Parameters
    - `task_id` - The task ID whose pod to stop

  ## Returns
    - `:ok` - Pod stopped successfully
    - `{:error, :not_running}` - Pod is not running
    - `{:error, reason}` - Other error

  ## Examples

      iex> :ok = Ipa.CentralManager.stop_pod("task-uuid-123")
  """
  def stop_pod(task_id) when is_binary(task_id) do
    case PodSupervisor.stop_pod(task_id) do
      :ok ->
        Logger.info("Stopped pod for task #{task_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to stop pod for task #{task_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Restarts a pod (stop + start).

  ## Parameters
    - `task_id` - The task ID whose pod to restart

  ## Returns
    - `{:ok, pid}` - Pod restarted successfully
    - `{:error, reason}` - Error occurred
  """
  def restart_pod(task_id) when is_binary(task_id) do
    PodSupervisor.restart_pod(task_id)
  end

  @doc """
  Gets a list of all active pod task IDs.

  ## Returns
    - List of task IDs with running pods

  ## Examples

      iex> Ipa.CentralManager.get_active_pods()
      ["task-1", "task-2"]
  """
  def get_active_pods do
    PodSupervisor.list_pods()
    |> Enum.map(& &1.task_id)
  end

  @doc """
  Checks if a pod is currently running for the given task.

  ## Parameters
    - `task_id` - The task ID to check

  ## Returns
    - `true` - Pod is running
    - `false` - Pod is not running

  ## Examples

      iex> Ipa.CentralManager.pod_running?("task-uuid-123")
      true
  """
  def pod_running?(task_id) when is_binary(task_id) do
    PodSupervisor.pod_running?(task_id)
  end

  @doc """
  Lists all tasks with their summary information.

  This queries the event store for all task streams and provides
  summary information including:
  - Task ID
  - Title
  - Current phase
  - Pod running status
  - Created at timestamp
  - Workstream count
  - Unread message count

  ## Options
    - `:include_completed` - Include completed/cancelled tasks (default: false)
    - `:limit` - Maximum number of tasks to return (default: 100)

  ## Returns
    - List of task summary maps

  ## Examples

      iex> Ipa.CentralManager.list_tasks()
      [
        %{
          task_id: "task-1",
          title: "Build auth system",
          phase: :executing,
          pod_running: true,
          created_at: ~U[2025-01-15 10:00:00Z],
          workstream_count: 3,
          unread_count: 2
        }
      ]
  """
  def list_tasks(opts \\ []) do
    include_completed = Keyword.get(opts, :include_completed, false)
    limit = Keyword.get(opts, :limit, 100)

    # Get all task streams from the event store
    {:ok, streams} = EventStore.list_streams("task")

    streams
    |> Enum.take(limit)
    |> Enum.map(fn stream -> build_task_summary(stream.id) end)
    |> Enum.reject(&is_nil/1)
    |> maybe_filter_completed(include_completed)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc """
  Gets detailed information about a specific task.

  ## Parameters
    - `task_id` - The task ID to get info for

  ## Returns
    - `{:ok, task_info}` - Task information map
    - `{:error, :not_found}` - Task doesn't exist

  ## Examples

      iex> {:ok, info} = Ipa.CentralManager.get_task("task-uuid-123")
      iex> info.title
      "Build authentication system"
  """
  def get_task(task_id) when is_binary(task_id) do
    case EventStore.stream_exists?(task_id) do
      true ->
        {:ok, build_task_summary(task_id)}

      false ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the count of active pods.

  ## Returns
    - Integer count of running pods
  """
  def count_active_pods do
    PodSupervisor.count_pods()
  end

  # Private Functions

  defp generate_task_id do
    "task-#{UUID.uuid4()}"
  end

  defp build_task_summary(task_id) when is_binary(task_id) do
    case EventStore.read_stream(task_id) do
      {:ok, [_ | _] = events} ->
        # Build summary from events
        task_created = Enum.find(events, fn e -> e.event_type == "task_created" end)

        if task_created do
          state = project_basic_state(events)

          %{
            task_id: task_id,
            title: get_in(task_created.data, [:title]) || get_in(task_created.data, ["title"]) || "Untitled",
            phase: state.phase,
            pod_running: pod_running?(task_id),
            created_at: unix_to_datetime(task_created.inserted_at),
            workstream_count: state.workstream_count,
            unread_count: state.unread_count,
            completed: state.phase in [:completed, :cancelled]
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp project_basic_state(events) do
    initial = %{
      phase: :spec_clarification,
      workstream_count: 0,
      unread_count: 0
    }

    Enum.reduce(events, initial, fn event, acc ->
      case event.event_type do
        "transition_approved" ->
          to_phase = get_in(event.data, [:to_phase]) || get_in(event.data, ["to_phase"])
          phase = if is_binary(to_phase), do: String.to_atom(to_phase), else: to_phase
          %{acc | phase: phase || acc.phase}

        "task_completed" ->
          %{acc | phase: :completed}

        "task_cancelled" ->
          %{acc | phase: :cancelled}

        "workstream_created" ->
          %{acc | workstream_count: acc.workstream_count + 1}

        "notification_created" ->
          %{acc | unread_count: acc.unread_count + 1}

        "notification_read" ->
          %{acc | unread_count: max(0, acc.unread_count - 1)}

        _ ->
          acc
      end
    end)
  end

  defp maybe_filter_completed(tasks, true), do: tasks
  defp maybe_filter_completed(tasks, false) do
    Enum.reject(tasks, & &1.completed)
  end

  defp unix_to_datetime(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
  end
  defp unix_to_datetime(_), do: DateTime.utc_now()
end
