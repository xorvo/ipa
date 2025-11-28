defmodule Ipa.Pod.ExternalSync do
  @moduledoc """
  External Sync Manager for Pod - handles GitHub synchronization.

  Provides:
  - Automatic PR creation when task enters development phase
  - Polling for external changes (PR comments, status)
  - Sync queue with deduplication
  - Approval gates for sensitive operations

  ## Registration

  Registers via Registry with key `{:pod_sync, task_id}`.

  ## Pub-Sub

  Subscribes to `"pod:<task_id>:state"` for state change notifications.
  Broadcasts sync events to `"pod:<task_id>:sync"`.
  """

  use GenServer
  require Logger

  alias Ipa.Pod.ExternalSync.GitHubConnector
  alias Ipa.Pod.ExternalSync.SyncQueue
  alias Ipa.Pod.Manager

  @type task_id :: String.t()
  @type sync_status :: :idle | :syncing | :error
  @type github_config :: %{
          optional(:repo) => String.t(),
          optional(:base_branch) => String.t(),
          optional(:enabled) => boolean()
        }

  # Default polling interval: 5 minutes
  @default_poll_interval_ms 5 * 60 * 1000
  # Min polling interval: 1 minute
  @min_poll_interval_ms 60 * 1000
  # Max polling interval: 30 minutes
  @max_poll_interval_ms 30 * 60 * 1000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the External Sync Manager for a task.

  ## Options

  - `:task_id` - Required. Task UUID.
  - `:github` - Optional. GitHub configuration map.
    - `:repo` - Repository in "owner/repo" format
    - `:base_branch` - Base branch for PRs (default: "main")
    - `:enabled` - Whether GitHub sync is enabled (default: true)

  ## Examples

      {:ok, pid} = Ipa.Pod.ExternalSync.start_link(
        task_id: "task-123",
        github: %{repo: "xorvo/ipa", base_branch: "main"}
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc """
  Returns the current sync status for a task.

  ## Examples

      {:ok, status} = Ipa.Pod.ExternalSync.get_status(task_id)
      # => %{github: %{pr_number: 123, last_synced_at: ...}, status: :idle}
  """
  @spec get_status(task_id()) :: {:ok, map()} | {:error, :not_found}
  def get_status(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      _pid -> GenServer.call(via_tuple(task_id), :get_status)
    end
  end

  @doc """
  Triggers an immediate sync with GitHub.

  ## Examples

      :ok = Ipa.Pod.ExternalSync.sync_now(task_id)
  """
  @spec sync_now(task_id()) :: :ok | {:error, term()}
  def sync_now(task_id) do
    GenServer.call(via_tuple(task_id), :sync_now)
  end

  @doc """
  Creates a GitHub PR for the task.

  ## Options

  - `:title` - PR title (required)
  - `:body` - PR body/description
  - `:head_branch` - Head branch name
  - `:draft` - Create as draft PR (default: false)

  ## Examples

      {:ok, pr_number} = Ipa.Pod.ExternalSync.create_pr(task_id,
        title: "feat: Implement user authentication",
        body: "This PR implements...",
        head_branch: "feature/auth"
      )
  """
  @spec create_pr(task_id(), keyword()) :: {:ok, integer()} | {:error, term()}
  def create_pr(task_id, opts) do
    GenServer.call(via_tuple(task_id), {:create_pr, opts}, 30_000)
  end

  @doc """
  Updates an existing GitHub PR.

  ## Options

  - `:title` - New title
  - `:body` - New body
  - `:state` - "open" or "closed"

  ## Examples

      :ok = Ipa.Pod.ExternalSync.update_pr(task_id, title: "Updated title")
  """
  @spec update_pr(task_id(), keyword()) :: :ok | {:error, term()}
  def update_pr(task_id, opts) do
    GenServer.call(via_tuple(task_id), {:update_pr, opts}, 30_000)
  end

  @doc """
  Requests approval to merge the PR.

  This creates an approval request in the communications system.
  The actual merge happens when approval is given.

  ## Examples

      {:ok, approval_id} = Ipa.Pod.ExternalSync.request_merge_approval(task_id)
  """
  @spec request_merge_approval(task_id()) :: {:ok, String.t()} | {:error, term()}
  def request_merge_approval(task_id) do
    GenServer.call(via_tuple(task_id), :request_merge_approval)
  end

  @doc """
  Merges the PR (after approval).

  ## Options

  - `:merge_method` - "merge", "squash", or "rebase" (default: "squash")
  - `:commit_message` - Custom merge commit message

  ## Examples

      :ok = Ipa.Pod.ExternalSync.merge_pr(task_id, merge_method: "squash")
  """
  @spec merge_pr(task_id(), keyword()) :: :ok | {:error, term()}
  def merge_pr(task_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:merge_pr, opts}, 30_000)
  end

  @doc """
  Subscribes to sync events for a task.

  Messages received:
  - `{:sync_started, task_id}`
  - `{:sync_completed, task_id, result}`
  - `{:sync_error, task_id, error}`
  - `{:pr_created, task_id, pr_number}`
  - `{:pr_updated, task_id, pr_number}`
  - `{:external_change_detected, task_id, change}`

  ## Examples

      Ipa.Pod.ExternalSync.subscribe(task_id)
  """
  @spec subscribe(task_id()) :: :ok
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}:sync")
  end

  @doc """
  Unsubscribes from sync events.
  """
  @spec unsubscribe(task_id()) :: :ok
  def unsubscribe(task_id) do
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "pod:#{task_id}:sync")
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    github_config = Keyword.get(opts, :github, %{})

    # Subscribe to state changes
    Manager.subscribe(task_id)

    # Initialize sync queue
    {:ok, queue_pid} = SyncQueue.start_link(task_id: task_id)

    state = %{
      task_id: task_id,
      github: %{
        config: Map.merge(default_github_config(), github_config),
        pr_number: nil,
        pr_url: nil,
        last_synced_at: nil,
        last_error: nil
      },
      status: :idle,
      poll_interval_ms: @default_poll_interval_ms,
      poll_timer_ref: nil,
      queue_pid: queue_pid
    }

    # Load existing PR info from task state
    state = load_existing_pr_info(state)

    # Start polling if GitHub is enabled and configured
    state =
      if github_enabled?(state) do
        schedule_poll(state)
      else
        state
      end

    Logger.info("External Sync started for task #{task_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      status: state.status,
      github: %{
        enabled: github_enabled?(state),
        pr_number: state.github.pr_number,
        pr_url: state.github.pr_url,
        last_synced_at: state.github.last_synced_at,
        last_error: state.github.last_error
      },
      poll_interval_ms: state.poll_interval_ms
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    state = do_sync(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:create_pr, opts}, _from, state) do
    case create_github_pr(state, opts) do
      {:ok, pr_number, pr_url} ->
        # Record event in task state
        record_pr_created(state.task_id, pr_number, pr_url)

        # Update local state
        new_github = %{state.github | pr_number: pr_number, pr_url: pr_url}
        new_state = %{state | github: new_github}

        # Broadcast
        broadcast(state.task_id, {:pr_created, state.task_id, pr_number})

        {:reply, {:ok, pr_number}, new_state}

      {:error, reason} = error ->
        new_github = %{state.github | last_error: reason}
        {:reply, error, %{state | github: new_github}}
    end
  end

  @impl true
  def handle_call({:update_pr, opts}, _from, state) do
    case state.github.pr_number do
      nil ->
        {:reply, {:error, :no_pr_exists}, state}

      pr_number ->
        case GitHubConnector.update_pr(state.github.config.repo, pr_number, opts) do
          :ok ->
            broadcast(state.task_id, {:pr_updated, state.task_id, pr_number})
            {:reply, :ok, state}

          {:error, reason} = error ->
            new_github = %{state.github | last_error: reason}
            {:reply, error, %{state | github: new_github}}
        end
    end
  end

  @impl true
  def handle_call(:request_merge_approval, _from, state) do
    case state.github.pr_number do
      nil ->
        {:reply, {:error, :no_pr_exists}, state}

      pr_number ->
        # Create approval request via EventStore directly
        msg_id = Ecto.UUID.generate()

        result =
          Ipa.EventStore.append(
            state.task_id,
            "approval_requested",
            %{
              message_id: msg_id,
              question: "Ready to merge PR ##{pr_number}?",
              options: ["Merge", "Not yet"],
              author: "external_sync",
              blocking?: false,
              posted_at: System.system_time(:second)
            },
            actor_id: "external_sync"
          )

        case result do
          {:ok, _version} ->
            {:reply, {:ok, msg_id}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:merge_pr, opts}, _from, state) do
    case state.github.pr_number do
      nil ->
        {:reply, {:error, :no_pr_exists}, state}

      pr_number ->
        merge_method = Keyword.get(opts, :merge_method, "squash")

        case GitHubConnector.merge_pr(state.github.config.repo, pr_number, merge_method) do
          :ok ->
            # Record merge event
            record_pr_merged(state.task_id)
            broadcast(state.task_id, {:pr_merged, state.task_id, pr_number})
            {:reply, :ok, state}

          {:error, reason} = error ->
            new_github = %{state.github | last_error: reason}
            {:reply, error, %{state | github: new_github}}
        end
    end
  end

  # Handle state updates from Pod State Manager
  @impl true
  def handle_info({:state_updated, _task_id, new_state}, state) do
    # React to phase changes
    state = handle_phase_change(state, new_state.phase)
    {:noreply, state}
  end

  # Handle approval given events
  def handle_info({:approval_given, _task_id, _msg_id, data}, state) do
    # Check if this is a merge approval
    if data.choice == "Merge" && state.github.pr_number do
      # Auto-merge on approval
      case GitHubConnector.merge_pr(state.github.config.repo, state.github.pr_number, "squash") do
        :ok ->
          record_pr_merged(state.task_id)
          broadcast(state.task_id, {:pr_merged, state.task_id, state.github.pr_number})

        {:error, reason} ->
          Logger.error("Failed to merge PR after approval: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  # Polling timer
  def handle_info(:poll, state) do
    state = do_sync(state)
    state = schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "External Sync shutting down for task #{state.task_id}, reason: #{inspect(reason)}"
    )

    # Cancel poll timer
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    # Stop sync queue
    if state.queue_pid && Process.alive?(state.queue_pid) do
      GenServer.stop(state.queue_pid, :normal)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:pod_sync, task_id}}}
  end

  defp default_github_config do
    %{
      repo: nil,
      base_branch: "main",
      enabled: true
    }
  end

  defp github_enabled?(state) do
    state.github.config.enabled && state.github.config.repo != nil
  end

  defp load_existing_pr_info(state) do
    # External sync manages its own state, so we just return as-is
    # PR info is tracked internally and via events, not in Manager state
    state
  end

  defp schedule_poll(state) do
    # Cancel existing timer
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    # Schedule next poll
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %{state | poll_timer_ref: ref}
  end

  defp do_sync(state) do
    if not github_enabled?(state) do
      state
    else
      broadcast(state.task_id, {:sync_started, state.task_id})
      new_state = %{state | status: :syncing}

      case sync_github(new_state) do
        {:ok, updated_state} ->
          broadcast(state.task_id, {:sync_completed, state.task_id, :ok})

          %{
            updated_state
            | status: :idle,
              github: %{updated_state.github | last_synced_at: System.system_time(:second)}
          }

        {:error, reason} ->
          broadcast(state.task_id, {:sync_error, state.task_id, reason})

          # Adjust polling interval on errors (backoff)
          new_interval = min(state.poll_interval_ms * 2, @max_poll_interval_ms)

          %{
            state
            | status: :error,
              poll_interval_ms: new_interval,
              github: %{state.github | last_error: reason}
          }
      end
    end
  end

  defp sync_github(state) do
    case state.github.pr_number do
      nil ->
        # No PR yet, nothing to sync
        {:ok, state}

      pr_number ->
        # Fetch PR status and comments
        case GitHubConnector.get_pr(state.github.config.repo, pr_number) do
          {:ok, pr_data} ->
            # Check for new comments
            handle_pr_updates(state, pr_data)

          {:error, :rate_limited} ->
            # Increase polling interval
            new_interval = min(state.poll_interval_ms * 2, @max_poll_interval_ms)
            {:ok, %{state | poll_interval_ms: new_interval}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp handle_pr_updates(state, pr_data) do
    # Check if PR was merged externally
    if pr_data[:merged] && !pr_merged?(state.task_id) do
      record_pr_merged(state.task_id)
      broadcast(state.task_id, {:external_change_detected, state.task_id, :pr_merged})
    end

    # Check if PR was closed externally
    if pr_data[:state] == "closed" && !pr_data[:merged] do
      broadcast(state.task_id, {:external_change_detected, state.task_id, :pr_closed})
    end

    # Decrease polling interval on success (recover from backoff)
    new_interval = max(state.poll_interval_ms - 60_000, @min_poll_interval_ms)
    {:ok, %{state | poll_interval_ms: new_interval}}
  end

  defp create_github_pr(state, opts) do
    title = Keyword.fetch!(opts, :title)
    body = Keyword.get(opts, :body, "")
    head_branch = Keyword.get(opts, :head_branch, "task-#{state.task_id}")
    draft = Keyword.get(opts, :draft, false)

    GitHubConnector.create_pr(
      state.github.config.repo,
      title: title,
      body: body,
      head: head_branch,
      base: state.github.config.base_branch,
      draft: draft
    )
  end

  defp handle_phase_change(state, phase) do
    # Auto-create PR when entering workstream_execution phase
    if phase == :workstream_execution && state.github.pr_number == nil && github_enabled?(state) do
      # Queue PR creation
      SyncQueue.enqueue(state.queue_pid, :create_pr, %{
        task_id: state.task_id,
        title: get_pr_title(state.task_id),
        body: get_pr_body(state.task_id),
        draft: true
      })
    end

    state
  end

  defp get_pr_title(task_id) do
    case Manager.get_state(task_id) do
      {:ok, state} -> state.title || "Task #{String.slice(task_id, 0, 8)}"
      _ -> "Task #{String.slice(task_id, 0, 8)}"
    end
  end

  defp get_pr_body(task_id) do
    case Manager.get_state(task_id) do
      {:ok, state} ->
        """
        ## Task

        #{state.spec[:description] || "No description"}

        ## Requirements

        #{format_requirements(state.spec[:requirements] || [])}

        ---
        *Created by IPA (Intelligent Process Automation)*
        """

      _ ->
        "Created by IPA"
    end
  end

  defp format_requirements([]), do: "None specified"

  defp format_requirements(requirements) do
    requirements
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp record_pr_created(task_id, pr_number, pr_url) do
    Ipa.EventStore.append(
      task_id,
      "github_pr_created",
      %{pr_number: pr_number, pr_url: pr_url},
      actor_id: "external_sync"
    )
  end

  defp record_pr_merged(task_id) do
    Ipa.EventStore.append(
      task_id,
      "github_pr_merged",
      %{},
      actor_id: "external_sync"
    )
  end

  defp pr_merged?(task_id) do
    case Manager.get_state(task_id) do
      {:ok, state} -> state.external_sync.github.pr_merged?
      _ -> false
    end
  end

  defp broadcast(task_id, message) do
    Phoenix.PubSub.broadcast(Ipa.PubSub, "pod:#{task_id}:sync", message)
  end
end
