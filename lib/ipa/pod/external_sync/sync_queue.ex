defmodule Ipa.Pod.ExternalSync.SyncQueue do
  @moduledoc """
  Sync Queue for External Sync operations.

  Provides:
  - Queued execution of sync operations
  - Deduplication of identical pending operations
  - Retry with exponential backoff
  - Rate limit awareness

  Operations are processed sequentially to avoid race conditions
  and respect rate limits.
  """

  use GenServer
  require Logger

  alias Ipa.Pod.ExternalSync.GitHubConnector

  @type task_id :: String.t()
  @type operation :: :create_pr | :update_pr | :merge_pr | :close_pr | :add_comment
  @type queue_item :: %{
          operation: operation(),
          data: map(),
          retry_count: non_neg_integer(),
          queued_at: integer()
        }

  # Max retries before giving up
  @max_retries 3
  # Base delay for exponential backoff (ms)
  @base_delay_ms 5_000
  # Process queue every N ms
  @process_interval_ms 1_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the sync queue for a task.

  ## Options

  - `:task_id` - Required. Task UUID.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc """
  Enqueues an operation for processing.

  Duplicate operations (same operation + data) are deduplicated.

  ## Parameters

  - `queue` - Queue PID or task_id
  - `operation` - Operation atom (:create_pr, :update_pr, etc.)
  - `data` - Operation-specific data map

  ## Examples

      SyncQueue.enqueue(queue_pid, :create_pr, %{
        task_id: "task-123",
        title: "My PR",
        body: "Description"
      })
  """
  @spec enqueue(pid() | task_id(), operation(), map()) :: :ok
  def enqueue(queue, operation, data) when is_pid(queue) do
    GenServer.cast(queue, {:enqueue, operation, data})
  end

  def enqueue(task_id, operation, data) when is_binary(task_id) do
    GenServer.cast(via_tuple(task_id), {:enqueue, operation, data})
  end

  @doc """
  Returns the current queue status.

  ## Returns

  - `{:ok, status}` with queue info
  """
  @spec get_status(pid() | task_id()) :: {:ok, map()}
  def get_status(queue) when is_pid(queue) do
    GenServer.call(queue, :get_status)
  end

  def get_status(task_id) when is_binary(task_id) do
    GenServer.call(via_tuple(task_id), :get_status)
  end

  @doc """
  Clears all pending operations from the queue.
  """
  @spec clear(pid() | task_id()) :: :ok
  def clear(queue) when is_pid(queue) do
    GenServer.call(queue, :clear)
  end

  def clear(task_id) when is_binary(task_id) do
    GenServer.call(via_tuple(task_id), :clear)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    state = %{
      task_id: task_id,
      queue: :queue.new(),
      processing: false,
      last_error: nil,
      processed_count: 0,
      failed_count: 0
    }

    # Schedule queue processing
    schedule_process()

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, operation, data}, state) do
    item = %{
      operation: operation,
      data: data,
      retry_count: 0,
      queued_at: System.system_time(:second)
    }

    # Check for duplicate
    if duplicate_exists?(state.queue, item) do
      Logger.debug("Skipping duplicate operation: #{operation}")
      {:noreply, state}
    else
      Logger.debug("Enqueued operation: #{operation}")
      new_queue = :queue.in(item, state.queue)
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      pending: :queue.len(state.queue),
      processing: state.processing,
      processed_count: state.processed_count,
      failed_count: state.failed_count,
      last_error: state.last_error
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | queue: :queue.new()}}
  end

  @impl true
  def handle_info(:process_queue, state) do
    state = process_next(state)
    schedule_process()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:sync_queue, task_id}}}
  end

  defp schedule_process do
    Process.send_after(self(), :process_queue, @process_interval_ms)
  end

  defp process_next(%{processing: true} = state), do: state

  defp process_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, item}, new_queue} ->
        state = %{state | queue: new_queue, processing: true}

        case execute_operation(item) do
          :ok ->
            Logger.info("Operation #{item.operation} completed successfully")
            %{state | processing: false, processed_count: state.processed_count + 1}

          {:retry, reason} ->
            if item.retry_count < @max_retries do
              # Re-queue with incremented retry count and delay
              delayed_item = %{item | retry_count: item.retry_count + 1}
              delay = calculate_backoff(item.retry_count)

              Logger.warning(
                "Operation #{item.operation} failed, retrying in #{delay}ms: #{inspect(reason)}"
              )

              # Schedule re-queue after delay
              Process.send_after(self(), {:requeue, delayed_item}, delay)
              %{state | processing: false, last_error: reason}
            else
              Logger.error("Operation #{item.operation} failed after #{@max_retries} retries")
              %{state | processing: false, failed_count: state.failed_count + 1, last_error: reason}
            end

          {:error, reason} ->
            Logger.error("Operation #{item.operation} failed permanently: #{inspect(reason)}")
            %{state | processing: false, failed_count: state.failed_count + 1, last_error: reason}
        end
    end
  end

  defp execute_operation(%{operation: :create_pr, data: data}) do
    # Check if GitHub is enabled
    case Ipa.Pod.ExternalSync.get_status(data.task_id) do
      {:ok, %{github: %{enabled: true}}} ->
        with_repo(data, fn repo ->
          case GitHubConnector.create_pr(repo,
                 title: data.title,
                 body: data[:body] || "",
                 head: data[:head_branch] || "workstream-#{data.workstream_id}",
                 base: data[:base_branch] || "main",
                 draft: data[:draft] || false
               ) do
            {:ok, pr_number, pr_url} ->
              Ipa.EventStore.append(
                data.task_id,
                "github_pr_created",
                %{workstream_id: data.workstream_id, pr_number: pr_number, pr_url: pr_url},
                actor_id: "sync_queue"
              )
              :ok

            {:error, :rate_limited} ->
              {:retry, :rate_limited}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      {:ok, _} ->
        {:error, :github_not_enabled}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_operation(%{operation: :update_pr, data: data}) do
    with_repo(data, fn repo ->
      pr_number = data.pr_number

      case GitHubConnector.update_pr(repo, pr_number, Map.to_list(data.updates)) do
        :ok -> :ok
        {:error, :rate_limited} -> {:retry, :rate_limited}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp execute_operation(%{operation: :merge_pr, data: data}) do
    with_repo(data, fn repo ->
      pr_number = data.pr_number
      method = data[:merge_method] || "squash"

      case GitHubConnector.merge_pr(repo, pr_number, method) do
        :ok ->
          # Record merge
          Ipa.EventStore.append(
            data.task_id,
            "github_pr_merged",
            %{workstream_id: data.workstream_id},
            actor_id: "sync_queue"
          )

          :ok

        {:error, :rate_limited} ->
          {:retry, :rate_limited}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp execute_operation(%{operation: :close_pr, data: data}) do
    with_repo(data, fn repo ->
      pr_number = data.pr_number

      case GitHubConnector.close_pr(repo, pr_number) do
        :ok -> :ok
        {:error, :rate_limited} -> {:retry, :rate_limited}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp execute_operation(%{operation: :add_comment, data: data}) do
    with_repo(data, fn repo ->
      pr_number = data.pr_number
      body = data.body

      case GitHubConnector.add_pr_comment(repo, pr_number, body) do
        :ok -> :ok
        {:error, :rate_limited} -> {:retry, :rate_limited}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp execute_operation(%{operation: op}) do
    Logger.warning("Unknown operation: #{op}")
    {:error, :unknown_operation}
  end

  defp with_repo(data, fun) do
    case get_repo_for_workstream(data.task_id, data.workstream_id) do
      nil -> {:error, :no_repo_configured}
      repo -> fun.(repo)
    end
  end

  defp get_repo_for_workstream(task_id, workstream_id) do
    # Get repo from workstream (each workstream can target a different repo)
    case Ipa.Pod.Manager.get_state(task_id) do
      {:ok, state} ->
        case Map.get(state.workstreams, workstream_id) do
          %{repo: repo} when is_binary(repo) -> repo
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp duplicate_exists?(queue, item) do
    :queue.any(
      fn existing ->
        existing.operation == item.operation &&
          existing.data == item.data
      end,
      queue
    )
  end

  defp calculate_backoff(retry_count) do
    # Exponential backoff: 5s, 10s, 20s, etc.
    @base_delay_ms * :math.pow(2, retry_count) |> round()
  end
end
