defmodule Ipa.Pod.State do
  @moduledoc """
  Pod State Manager - Event-sourced state management for task pods.

  The Pod State Manager sits on top of the generic Event Store and provides:
  - Event-sourced state management (loads events, replays to build in-memory state)
  - High-level event API with business-aware validation
  - Pub-sub broadcasting for state changes
  - Optimistic concurrency control
  - Fast state queries via in-memory projection

  Each task has one State Manager that maintains the complete task state including:
  - Task lifecycle and phase
  - Spec and plan data
  - Agent status
  - Workstreams (parallel work execution)
  - Messages and inbox (communications)
  - External sync status

  ## Registration

  State Managers register via Registry with key `{:pod_state, task_id}`.

  ## Pub-Sub

  Broadcasts state changes to topic `"pod:<task_id>:state"` with messages:
  `{:state_updated, task_id, new_state}`
  """

  use GenServer
  require Logger

  @type task_id :: String.t()
  @type state :: map()
  @type event_type :: String.t()
  @type event_data :: map()
  @type version :: integer()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the State Manager for a task.

  Called by Pod Supervisor. Loads events from Event Store and builds initial state.

  ## Options

  - `:task_id` - Required. Task UUID.

  ## Examples

      {:ok, pid} = Ipa.Pod.State.start_link(task_id: "task-123")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc """
  Appends an event to the task stream with optimistic concurrency control.

  ## Parameters

  - `task_id` - Task UUID
  - `event_type` - Event type string (e.g., "spec_approved", "agent_started")
  - `event_data` - Event payload map
  - `expected_version` - Current version for conflict detection (optional)
  - `opts` - Optional keyword list for metadata:
    - `:actor_id` - Who/what caused this event
    - `:correlation_id` - For tracing related events
    - `:metadata` - Additional context

  ## Returns

  - `{:ok, new_version}` - Event appended successfully
  - `{:error, :version_conflict}` - Expected version doesn't match
  - `{:error, {:validation_failed, reason}}` - Event data invalid
  - `{:error, :stream_not_found}` - Task doesn't exist

  ## Examples

      # Without version check
      {:ok, version} = Ipa.Pod.State.append_event(
        task_id,
        "spec_approved",
        %{approved_by: user_id},
        nil
      )

      # With optimistic concurrency (recommended)
      {:ok, state} = Ipa.Pod.State.get_state(task_id)
      {:ok, version} = Ipa.Pod.State.append_event(
        task_id,
        "spec_approved",
        %{approved_by: user_id},
        state.version
      )
  """
  @spec append_event(task_id(), event_type(), event_data(), version() | nil, keyword()) ::
          {:ok, version()} | {:error, term()}
  def append_event(task_id, event_type, event_data, expected_version, opts \\ []) do
    GenServer.call(
      via_tuple(task_id),
      {:append_event, event_type, event_data, expected_version, opts}
    )
  end

  @doc """
  Returns the current in-memory state for a task.

  ## Returns

  - `{:ok, state}` - State map
  - `{:error, :not_found}` - State Manager not running

  ## Examples

      {:ok, state} = Ipa.Pod.State.get_state(task_id)
      # => %{task_id: "uuid", version: 42, phase: :planning, ...}
  """
  @spec get_state(task_id()) :: {:ok, state()} | {:error, :not_found}
  def get_state(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      _pid -> GenServer.call(via_tuple(task_id), :get_state)
    end
  end

  @doc """
  Reconstructs state from events without requiring a running Pod.

  This is useful for viewing task state when the pod is not running.
  Unlike `get_state/1`, this directly reads from the Event Store and
  projects the state without caching.

  ## Parameters

  - `task_id` - Task UUID

  ## Returns

  - `{:ok, state}` - State reconstructed from events
  - `{:error, :not_found}` - No events found for this task

  ## Examples

      {:ok, state} = Ipa.Pod.State.get_state_from_events("task-123")
  """
  @spec get_state_from_events(task_id()) :: {:ok, state()} | {:error, :not_found}
  def get_state_from_events(task_id) do
    case Ipa.EventStore.read_stream(task_id) do
      {:ok, [_ | _] = events} ->
        # Events are already decoded with atom keys by EventStore
        state = Enum.reduce(events, nil, &apply_event/2)
        {:ok, state}

      {:ok, []} ->
        {:error, :not_found}

      {:error, :stream_not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Subscribes the calling process to state change notifications.

  Messages received: `{:state_updated, task_id, new_state}`

  ## Examples

      Ipa.Pod.State.subscribe(task_id)
      # Process will now receive {:state_updated, ...} messages
  """
  @spec subscribe(task_id()) :: :ok
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}:state")
  end

  @doc """
  Unsubscribes the calling process from state change notifications.
  """
  @spec unsubscribe(task_id()) :: :ok
  def unsubscribe(task_id) do
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "pod:#{task_id}:state")
  end

  @doc """
  Forces a reload of state from Event Store. Used for error recovery.

  ## Examples

      {:ok, new_state} = Ipa.Pod.State.reload_state(task_id)
  """
  @spec reload_state(task_id()) :: {:ok, state()} | {:error, term()}
  def reload_state(task_id) do
    GenServer.call(via_tuple(task_id), :reload_state)
  end

  @doc """
  Returns a single workstream by ID.

  ## Examples

      {:ok, workstream} = Ipa.Pod.State.get_workstream(task_id, "ws-1")
  """
  @spec get_workstream(task_id(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_workstream(task_id, workstream_id) do
    GenServer.call(via_tuple(task_id), {:get_workstream, workstream_id})
  end

  @doc """
  Returns all workstreams for a task as a map.

  ## Examples

      {:ok, workstreams} = Ipa.Pod.State.list_workstreams(task_id)
      # => %{"ws-1" => %{...}, "ws-2" => %{...}}
  """
  @spec list_workstreams(task_id()) :: {:ok, map()}
  def list_workstreams(task_id) do
    GenServer.call(via_tuple(task_id), :list_workstreams)
  end

  @doc """
  Returns only workstreams with status `:in_progress`.

  ## Examples

      {:ok, active} = Ipa.Pod.State.get_active_workstreams(task_id)
  """
  @spec get_active_workstreams(task_id()) :: {:ok, [map()]}
  def get_active_workstreams(task_id) do
    GenServer.call(via_tuple(task_id), :get_active_workstreams)
  end

  @doc """
  Returns messages with optional filtering.

  ## Options

  - `:thread_id` - Return only messages in this thread
  - `:workstream_id` - Return only messages for this workstream
  - `:type` - Return only messages of this type
  - `:limit` - Maximum number of messages to return

  ## Examples

      {:ok, messages} = Ipa.Pod.State.get_messages(task_id)
      {:ok, thread} = Ipa.Pod.State.get_messages(task_id, thread_id: "msg-123")
  """
  @spec get_messages(task_id(), keyword()) :: {:ok, [map()]}
  def get_messages(task_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:get_messages, opts})
  end

  @doc """
  Returns inbox notifications with optional filtering.

  ## Options

  - `:unread_only?` - If true, return only unread notifications
  - `:recipient` - Filter by recipient (user_id or agent_id)

  ## Examples

      {:ok, inbox} = Ipa.Pod.State.get_inbox(task_id)
      {:ok, unread} = Ipa.Pod.State.get_inbox(task_id, unread_only?: true)
  """
  @spec get_inbox(task_id(), keyword()) :: {:ok, [map()]}
  def get_inbox(task_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:get_inbox, opts})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    case load_initial_state(task_id) do
      {:ok, projection} ->
        Logger.info("Pod State Manager started for task #{task_id}, version #{projection.version}")
        {:ok, %{task_id: task_id, projection: projection}}

      {:error, reason} ->
        Logger.error("Failed to start Pod State Manager for task #{task_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append_event, event_type, event_data, expected_version, opts}, _from, state) do
    # Validate event
    case validate_event(event_type, event_data, state.projection) do
      :ok ->
        # Append to Event Store
        append_opts = build_append_opts(expected_version, opts)

        case Ipa.EventStore.append(state.task_id, event_type, event_data, append_opts) do
          {:ok, new_version} ->
            # Load the newly appended event to get full metadata (including inserted_at timestamp)
            {:ok, events} =
              Ipa.EventStore.read_stream(
                state.task_id,
                from_version: new_version,
                to_version: new_version
              )

            # Apply the event to update state
            new_projection =
              case events do
                [event] ->
                  apply_event(event, state.projection)

                [] ->
                  # Fallback: construct event manually if read fails
                  # This shouldn't happen but provides resilience
                  event = %{
                    stream_id: state.task_id,
                    event_type: event_type,
                    data: event_data,
                    version: new_version,
                    inserted_at: System.system_time(:second)
                  }

                  apply_event(event, state.projection)
              end

            # Broadcast state change (best effort)
            broadcast_state_update(state.task_id, new_projection)

            {:reply, {:ok, new_version}, %{state | projection: new_projection}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state.projection}, state}
  end

  @impl true
  def handle_call(:reload_state, _from, state) do
    case load_initial_state(state.task_id) do
      {:ok, new_projection} ->
        broadcast_state_update(state.task_id, new_projection)
        {:reply, {:ok, new_projection}, %{state | projection: new_projection}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_workstream, workstream_id}, _from, state) do
    case Map.get(state.projection.workstreams, workstream_id) do
      nil -> {:reply, {:error, :not_found}, state}
      workstream -> {:reply, {:ok, workstream}, state}
    end
  end

  @impl true
  def handle_call(:list_workstreams, _from, state) do
    {:reply, {:ok, state.projection.workstreams}, state}
  end

  @impl true
  def handle_call(:get_active_workstreams, _from, state) do
    active =
      state.projection.workstreams
      |> Map.values()
      |> Enum.filter(fn ws -> ws.status == :in_progress end)

    {:reply, {:ok, active}, state}
  end

  @impl true
  def handle_call({:get_messages, opts}, _from, state) do
    messages =
      state.projection.messages
      |> maybe_filter_by_thread_id(opts[:thread_id])
      |> maybe_filter_by_workstream_id(opts[:workstream_id])
      |> maybe_filter_by_type(opts[:type])
      |> Enum.sort_by(& &1.posted_at, :desc)
      |> maybe_limit(opts[:limit])

    {:reply, {:ok, messages}, state}
  end

  @impl true
  def handle_call({:get_inbox, opts}, _from, state) do
    inbox =
      state.projection.inbox
      |> maybe_filter_unread_only(opts[:unread_only?])
      |> maybe_filter_by_recipient(opts[:recipient])
      |> Enum.sort_by(& &1.created_at, :desc)

    {:reply, {:ok, inbox}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Pod State Manager shutting down for task #{state.task_id}, reason: #{inspect(reason)}")

    # Save snapshot on shutdown (if configured)
    config = Application.get_env(:ipa, __MODULE__, [])

    if Keyword.get(config, :snapshot_on_shutdown, true) do
      # Use Task.async with timeout to prevent hanging
      task =
        Task.async(fn ->
          Ipa.EventStore.save_snapshot(
            state.task_id,
            state.projection,
            state.projection.version
          )
        end)

      case Task.yield(task, 4_000) || Task.shutdown(task) do
        {:ok, :ok} ->
          Logger.info(
            "Saved snapshot for task #{state.task_id} at version #{state.projection.version}"
          )

        {:ok, {:error, reason}} ->
          Logger.error("Failed to save snapshot for task #{state.task_id}: #{inspect(reason)}")

        nil ->
          Logger.warning("Snapshot save timed out for task #{state.task_id}")
      end
    end

    :ok
  end

  # ============================================================================
  # Private Functions - State Loading
  # ============================================================================

  defp load_initial_state(task_id) do
    # Check if stream exists first
    unless Ipa.EventStore.stream_exists?(task_id) do
      {:error, :stream_not_found}
    else
      # Try loading snapshot first (optimization)
      case Ipa.EventStore.load_snapshot(task_id) do
        {:ok, %{state: snapshot_state, version: snapshot_version}} ->
          # Load events since snapshot
          case Ipa.EventStore.read_stream(task_id, from_version: snapshot_version + 1) do
            {:ok, events} ->
              projection = Enum.reduce(events, snapshot_state, &apply_event/2)
              {:ok, projection}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, _reason} ->
          # No snapshot, load all events
          case Ipa.EventStore.read_stream(task_id) do
            {:ok, events} ->
              if Enum.empty?(events) do
                {:error, :stream_not_found}
              else
                projection = Enum.reduce(events, nil, &apply_event/2)
                {:ok, projection}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp build_append_opts(expected_version, opts) do
    base_opts = [
      actor_id: opts[:actor_id] || "system",
      metadata: opts[:metadata] || %{}
    ]

    base_opts =
      if expected_version do
        Keyword.put(base_opts, :expected_version, expected_version)
      else
        base_opts
      end

    if opts[:correlation_id] do
      Keyword.put(base_opts, :correlation_id, opts[:correlation_id])
    else
      base_opts
    end
  end

  defp broadcast_state_update(task_id, new_state) do
    case Phoenix.PubSub.broadcast(
           Ipa.PubSub,
           "pod:#{task_id}:state",
           {:state_updated, task_id, new_state}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to broadcast state update for task #{task_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ============================================================================
  # Private Functions - Event Application
  # ============================================================================

  # Initial state (no events yet)
  defp apply_event(event, nil) do
    apply_event(event, initial_state())
  end

  # Task Lifecycle Events
  defp apply_event(
         %{
           event_type: "task_created",
           data: data,
           version: version,
           inserted_at: timestamp,
           stream_id: stream_id
         },
         _state
       ) do
    %{
      task_id: stream_id,
      version: version,
      created_at: timestamp,
      updated_at: timestamp,
      phase: :spec_clarification,
      title: data[:title] || "",
      spec: initial_spec(),
      plan: nil,
      agents: [],
      external_sync: initial_external_sync(),
      pending_transitions: [],
      workstreams: %{},
      max_workstream_concurrency: data[:max_workstream_concurrency] || 3,
      active_workstream_count: 0,
      messages: [],
      inbox: []
    }
  end

  defp apply_event(
         %{event_type: "task_completed", version: version, inserted_at: timestamp},
         state
       ) do
    %{state | phase: :completed, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "task_cancelled", version: version, inserted_at: timestamp},
         state
       ) do
    %{state | phase: :cancelled, version: version, updated_at: timestamp}
  end

  # Phase Transition Events
  defp apply_event(
         %{
           event_type: "transition_requested",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    transition = %{
      from_phase: data.from_phase,
      to_phase: data.to_phase,
      requested_at: timestamp,
      reason: data[:reason] || ""
    }

    %{state |
      pending_transitions: [transition | state.pending_transitions],
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{
           event_type: "transition_approved",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    %{state |
      phase: normalize_phase(data.to_phase),
      pending_transitions: [],
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{event_type: "transition_rejected", version: version, inserted_at: timestamp},
         state
       ) do
    %{state | pending_transitions: [], version: version, updated_at: timestamp}
  end

  # Direct phase change (used for manual phase transitions without approval workflow)
  defp apply_event(
         %{
           event_type: "phase_changed",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    to_phase = data[:to_phase] || data["to_phase"]
    %{state | phase: normalize_phase(to_phase), version: version, updated_at: timestamp}
  end

  # Spec Phase Events
  defp apply_event(
         %{event_type: "spec_updated", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    spec_data = data.spec || data

    new_spec = %{
      description: spec_data[:description],
      requirements: spec_data[:requirements] || [],
      acceptance_criteria: spec_data[:acceptance_criteria] || [],
      approved?: false,
      approved_by: nil,
      approved_at: nil
    }

    %{state | spec: new_spec, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "spec_approved", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_spec = %{
      state.spec
      | approved?: true,
        approved_by: data[:approved_by],
        approved_at: timestamp
    }

    %{state | spec: new_spec, version: version, updated_at: timestamp}
  end

  # Plan Phase Events
  defp apply_event(
         %{event_type: "plan_updated", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    plan_data = data.plan || data

    new_plan = %{
      steps: plan_data[:steps] || [],
      total_estimated_hours: plan_data[:total_estimated_hours] || 0.0,
      workstreams: plan_data[:workstreams],
      approved?: false,
      approved_by: nil,
      approved_at: nil
    }

    %{state | plan: new_plan, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "plan_approved", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    # Defensive: if plan is nil (shouldn't happen with validation), skip this event
    if state.plan == nil do
      Logger.warning("Skipping plan_approved event: plan is nil",
        task_id: state.task_id,
        version: version
      )

      %{state | version: version, updated_at: timestamp}
    else
      new_plan = %{
        state.plan
        | approved?: true,
          approved_by: data[:approved_by],
          approved_at: timestamp
      }

      %{state | plan: new_plan, version: version, updated_at: timestamp}
    end
  end

  # Agent Events
  defp apply_event(
         %{event_type: "agent_started", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agent = %{
      agent_id: data.agent_id,
      agent_type: data.agent_type,
      workstream_id: data[:workstream_id],
      status: :running,
      workspace: data.workspace,
      started_at: timestamp,
      completed_at: nil,
      duration_ms: nil,
      result: nil,
      error: nil
    }

    %{state | agents: [agent | state.agents], version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "agent_completed", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agents =
      Enum.map(state.agents, fn agent ->
        if agent.agent_id == data.agent_id do
          %{
            agent
            | status: :completed,
              completed_at: timestamp,
              duration_ms: data[:duration_ms],
              result: data[:result]
          }
        else
          agent
        end
      end)

    %{state | agents: agents, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "agent_failed", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agents =
      Enum.map(state.agents, fn agent ->
        if agent.agent_id == data.agent_id do
          %{agent | status: :failed, completed_at: timestamp, error: data.error}
        else
          agent
        end
      end)

    %{state | agents: agents, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "agent_interrupted", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agents =
      Enum.map(state.agents, fn agent ->
        if agent.agent_id == data.agent_id do
          %{agent | status: :interrupted, completed_at: timestamp}
        else
          agent
        end
      end)

    %{state | agents: agents, version: version, updated_at: timestamp}
  end

  # External Sync Events
  defp apply_event(
         %{event_type: "github_pr_created", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_github = %{
      state.external_sync.github
      | pr_number: data.pr_number,
        pr_url: data.pr_url,
        synced_at: timestamp
    }

    new_external_sync = %{state.external_sync | github: new_github}
    %{state | external_sync: new_external_sync, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "github_pr_merged", version: version, inserted_at: timestamp},
         state
       ) do
    new_github = %{state.external_sync.github | pr_merged?: true, synced_at: timestamp}
    new_external_sync = %{state.external_sync | github: new_github}
    %{state | external_sync: new_external_sync, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "jira_ticket_updated", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_jira = %{
      state.external_sync.jira
      | ticket_id: data[:ticket_id] || state.external_sync.jira.ticket_id,
        status: data[:status] || state.external_sync.jira.status,
        synced_at: timestamp
    }

    new_external_sync = %{state.external_sync | jira: new_jira}
    %{state | external_sync: new_external_sync, version: version, updated_at: timestamp}
  end

  # Workstream Events
  defp apply_event(
         %{event_type: "workstream_created", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_workstream = %{
      workstream_id: data.workstream_id,
      spec: data.spec,
      repo: data[:repo],
      branch: data[:branch] || "main",
      status: :pending,
      agent_id: nil,
      dependencies: data[:dependencies] || [],
      blocking_on:
        Enum.filter(data[:dependencies] || [], fn dep_id ->
          case Map.get(state.workstreams, dep_id) do
            nil -> true
            dep -> dep.status != :completed
          end
        end),
      workspace: nil,
      started_at: nil,
      completed_at: nil,
      result: nil,
      error: nil
    }

    %{state |
      workstreams: Map.put(state.workstreams, data.workstream_id, new_workstream),
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{
           event_type: "workstream_spec_generated",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    updated_workstreams =
      Map.update!(state.workstreams, data.workstream_id, fn ws ->
        %{ws | spec: data.spec}
      end)

    %{state | workstreams: updated_workstreams, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{
           event_type: "workstream_agent_started",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    # Update workstream status (workspace is optional - may be set separately)
    # First check event data, then fall back to workspaces_by_agent map populated by workspace_created event
    workspaces_by_agent = Map.get(state, :workspaces_by_agent, %{})
    workspace = data[:workspace] || data["workspace"] || Map.get(workspaces_by_agent, data.agent_id)

    # Get existing workstream or create a minimal one if not found (defensive)
    existing_workstream = state.workstreams[data.workstream_id] || %{
      workstream_id: data.workstream_id,
      status: :pending,
      dependencies: [],
      blocking_on: []
    }

    updated_workstream =
      existing_workstream
      |> Map.put(:status, :in_progress)
      |> Map.put(:agent_id, data.agent_id)
      |> Map.put(:workspace, workspace)
      |> Map.put(:started_at, timestamp)

    # Also add agent to agents list
    new_agent = %{
      agent_id: data.agent_id,
      agent_type: "workstream_executor",
      workstream_id: data.workstream_id,
      status: :running,
      workspace: workspace,
      started_at: timestamp,
      completed_at: nil,
      duration_ms: nil,
      result: nil,
      error: nil
    }

    %{state |
      workstreams: Map.put(state.workstreams, data.workstream_id, updated_workstream),
      agents: [new_agent | state.agents],
      active_workstream_count: state.active_workstream_count + 1,
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{event_type: "workstream_completed", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    # Update completed workstream
    updated_workstream =
      state.workstreams[data.workstream_id]
      |> Map.put(:status, :completed)
      |> Map.put(:completed_at, timestamp)
      |> Map.put(:result, data[:result])

    # Update blocking_on for dependent workstreams
    updated_workstreams =
      state.workstreams
      |> Map.put(data.workstream_id, updated_workstream)
      |> Enum.map(fn {id, ws} ->
        if data.workstream_id in ws.blocking_on do
          {id, %{ws | blocking_on: List.delete(ws.blocking_on, data.workstream_id)}}
        else
          {id, ws}
        end
      end)
      |> Map.new()

    %{state |
      workstreams: updated_workstreams,
      active_workstream_count: max(0, state.active_workstream_count - 1),
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{event_type: "workstream_failed", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    # Update failed workstream
    updated_workstream =
      state.workstreams[data.workstream_id]
      |> Map.put(:status, :failed)
      |> Map.put(:completed_at, timestamp)
      |> Map.put(:error, data.error)

    # Find all transitively affected workstreams (recursive)
    affected_ids = find_transitively_blocked_workstreams(data.workstream_id, state.workstreams)

    # Mark all affected workstreams as blocked
    updated_workstreams =
      state.workstreams
      |> Map.put(data.workstream_id, updated_workstream)
      |> Enum.map(fn {id, ws} ->
        if id in affected_ids do
          {id, %{ws | status: :blocked}}
        else
          {id, ws}
        end
      end)
      |> Map.new()

    %{state |
      workstreams: updated_workstreams,
      active_workstream_count: max(0, state.active_workstream_count - 1),
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{event_type: "workstream_blocked", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    updated_workstreams =
      Map.update!(state.workstreams, data.workstream_id, fn ws ->
        %{ws | status: :blocked, blocking_on: data.blocked_by}
      end)

    %{state | workstreams: updated_workstreams, version: version, updated_at: timestamp}
  end

  # Communication Events
  defp apply_event(
         %{event_type: "message_posted", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_message = %{
      message_id: data.message_id,
      type: data.type,
      content: data.content,
      author: data.author,
      thread_id: data[:thread_id],
      workstream_id: data[:workstream_id],
      posted_at: timestamp,
      read_by: [],
      approval_options: nil,
      approval_choice: nil,
      approval_given_by: nil,
      approval_given_at: nil,
      approved?: false,
      blocking?: nil
    }

    %{state | messages: [new_message | state.messages], version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "approval_requested", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    new_message = %{
      message_id: data.message_id,
      type: :approval,
      content: data.question,
      author: data.author,
      thread_id: nil,
      workstream_id: data[:workstream_id],
      posted_at: timestamp,
      read_by: [],
      approval_options: data.options,
      approval_choice: nil,
      approval_given_by: nil,
      approval_given_at: nil,
      approved?: false,
      blocking?: data[:blocking?] || false
    }

    %{state | messages: [new_message | state.messages], version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "approval_given", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    # Update approval message
    updated_messages =
      Enum.map(state.messages, fn msg ->
        if msg.message_id == data.message_id do
          %{
            msg
            | approval_choice: data.choice,
              approval_given_by: data.approved_by,
              approval_given_at: timestamp,
              approved?: true
          }
        else
          msg
        end
      end)

    # Remove notification from inbox
    updated_inbox =
      Enum.reject(state.inbox, fn notif ->
        notif.message_id == data.message_id && notif.type == :needs_approval
      end)

    %{state |
      messages: updated_messages,
      inbox: updated_inbox,
      version: version,
      updated_at: timestamp
    }
  end

  defp apply_event(
         %{
           event_type: "notification_created",
           data: data,
           version: version,
           inserted_at: timestamp
         },
         state
       ) do
    new_notification = %{
      notification_id: data.notification_id,
      recipient: data.recipient,
      message_id: data.message_id,
      type: data.type,
      message_preview: data.message_preview,
      read?: false,
      created_at: timestamp
    }

    %{state | inbox: [new_notification | state.inbox], version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "notification_read", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    updated_inbox =
      Enum.map(state.inbox, fn notif ->
        if notif.notification_id == data.notification_id do
          %{notif | read?: true}
        else
          notif
        end
      end)

    %{state | inbox: updated_inbox, version: version, updated_at: timestamp}
  end

  defp apply_event(
         %{event_type: "notification_cleared", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    updated_inbox =
      Enum.reject(state.inbox, fn notif ->
        notif.notification_id == data.notification_id
      end)

    %{state | inbox: updated_inbox, version: version, updated_at: timestamp}
  end

  # Workspace created - store workspace path for agent
  # The workspace is created before the agent_started event, so we store it
  # in a workspaces map and merge it when the agent is created
  defp apply_event(
         %{event_type: "workspace_created", data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agent_id = data[:agent_id] || data["agent_id"]
    workspace_path = data[:workspace_path] || data["workspace_path"]

    # Store workspace path in workspaces map (keyed by agent_id)
    workspaces = Map.get(state, :workspaces_by_agent, %{})
    updated_workspaces = Map.put(workspaces, agent_id, workspace_path)

    # Also try to update existing agent if it exists
    updated_agents =
      Enum.map(state.agents || [], fn agent ->
        if agent.agent_id == agent_id do
          Map.put(agent, :workspace, workspace_path)
        else
          agent
        end
      end)

    state
    |> Map.put(:workspaces_by_agent, updated_workspaces)
    |> Map.put(:agents, updated_agents)
    |> Map.put(:version, version)
    |> Map.put(:updated_at, timestamp)
  end

  # Workstream started - mark workstream as in_progress
  defp apply_event(
         %{event_type: "workstream_started", event_data: data, version: version, inserted_at: timestamp},
         state
       ) do
    workstream_id = data["workstream_id"] || data[:workstream_id]

    updated_workstreams =
      Map.update(state.workstreams, workstream_id, %{status: :in_progress}, fn ws ->
        Map.put(ws, :status, :in_progress)
      end)

    %{state | workstreams: updated_workstreams, version: version, updated_at: timestamp}
  end

  # Agent spawned - track agent assignment
  defp apply_event(
         %{event_type: "agent_spawned", event_data: data, version: version, inserted_at: timestamp},
         state
       ) do
    agent_id = data["agent_id"] || data[:agent_id]
    workstream_id = data["workstream_id"] || data[:workstream_id]

    agent = %{
      agent_id: agent_id,
      workstream_id: workstream_id,
      status: :running,
      spawned_at: data["spawned_at"] || data[:spawned_at] || timestamp
    }

    updated_agents = [agent | state.agents]
    %{state | agents: updated_agents, version: version, updated_at: timestamp}
  end

  # PR created - track PR in external sync
  defp apply_event(
         %{event_type: "pr_created", event_data: data, version: version, inserted_at: timestamp},
         state
       ) do
    pr_url = data["pr_url"] || data[:pr_url]
    pr_number = data["pr_number"] || data[:pr_number]

    new_github = %{
      pr_number: pr_number,
      pr_url: pr_url,
      pr_merged?: false,
      synced_at: timestamp
    }

    updated_external_sync = Map.put(state.external_sync, :github, new_github)
    %{state | external_sync: updated_external_sync, version: version, updated_at: timestamp}
  end

  # PR approved - update approval status
  defp apply_event(
         %{event_type: "pr_approved", event_data: _data, version: version, inserted_at: timestamp},
         state
       ) do
    # Just update timestamp - approval tracked via events
    %{state | version: version, updated_at: timestamp}
  end

  # PR merged - mark PR as merged
  defp apply_event(
         %{event_type: "pr_merged", event_data: _data, version: version, inserted_at: timestamp},
         state
       ) do
    new_github = Map.put(state.external_sync.github, :pr_merged?, true)
    updated_external_sync = Map.put(state.external_sync, :github, new_github)
    %{state | external_sync: updated_external_sync, version: version, updated_at: timestamp}
  end

  # Unknown event types - log and skip
  defp apply_event(%{event_type: event_type, version: version, inserted_at: timestamp}, state) do
    Logger.warning("Unknown event type: #{event_type}, skipping")
    %{state | version: version, updated_at: timestamp}
  end

  # ============================================================================
  # Private Functions - Event Validation
  # ============================================================================

  # Task Lifecycle Events
  defp validate_event("task_created", _data, _state), do: :ok

  defp validate_event("task_completed", _data, state) do
    cond do
      state.phase == :completed ->
        {:error, {:validation_failed, "Task is already completed"}}

      state.phase == :cancelled ->
        {:error, {:validation_failed, "Cannot complete a cancelled task"}}

      true ->
        :ok
    end
  end

  defp validate_event("task_cancelled", _data, state) do
    if state.phase in [:completed, :cancelled] do
      {:error, {:validation_failed, "Cannot cancel task in phase #{state.phase}"}}
    else
      :ok
    end
  end

  # Phase Transition Events
  defp validate_event("transition_requested", data, state) do
    # Normalize phases to atoms for comparison
    from_phase = normalize_phase(data.from_phase)
    to_phase = normalize_phase(data.to_phase)
    current_phase = normalize_phase(state.phase)

    cond do
      current_phase != from_phase ->
        {:error,
         {:validation_failed,
          "Current phase #{state.phase} does not match from_phase #{data.from_phase}"}}

      not valid_transition?(from_phase, to_phase) ->
        {:error,
         {:validation_failed,
          "Invalid phase transition from #{data.from_phase} to #{data.to_phase}"}}

      true ->
        :ok
    end
  end

  defp validate_event("transition_approved", data, state) do
    if valid_transition?(state.phase, data.to_phase) do
      :ok
    else
      {:error,
       {:validation_failed, "Invalid phase transition from #{state.phase} to #{data.to_phase}"}}
    end
  end

  defp validate_event("transition_rejected", _data, state) do
    if Enum.empty?(state.pending_transitions) do
      {:error, {:validation_failed, "No pending transitions to reject"}}
    else
      :ok
    end
  end

  # Spec Phase Events
  defp validate_event("spec_updated", data, state) do
    spec_data = data[:spec] || data

    cond do
      state.phase not in [:spec_clarification, :planning] ->
        {:error, {:validation_failed, "Cannot update spec in phase #{state.phase}"}}

      not is_map(spec_data) ->
        {:error, {:validation_failed, "Spec data must be a map"}}

      true ->
        :ok
    end
  end

  defp validate_event("spec_approved", _data, state) do
    cond do
      state.phase != :spec_clarification ->
        {:error,
         {:validation_failed, "Cannot approve spec outside of spec_clarification phase"}}

      state.spec.description == nil ->
        {:error, {:validation_failed, "Cannot approve spec without description"}}

      state.spec.approved? ->
        {:error, {:validation_failed, "Spec is already approved"}}

      true ->
        :ok
    end
  end

  # Plan Phase Events
  defp validate_event("plan_updated", data, state) do
    plan_data = data[:plan] || data

    cond do
      state.phase != :planning ->
        {:error, {:validation_failed, "Cannot update plan outside of planning phase"}}

      not is_map(plan_data) ->
        {:error, {:validation_failed, "Plan data must be a map"}}

      not is_list(plan_data[:steps]) ->
        {:error, {:validation_failed, "Plan must have a steps list"}}

      true ->
        :ok
    end
  end

  defp validate_event("plan_approved", _data, state) do
    cond do
      state.phase != :planning ->
        {:error, {:validation_failed, "Cannot approve plan outside of planning phase"}}

      state.plan == nil ->
        {:error, {:validation_failed, "Cannot approve plan without plan data"}}

      state.plan.approved? ->
        {:error, {:validation_failed, "Plan is already approved"}}

      true ->
        :ok
    end
  end

  # Agent Events
  defp validate_event("agent_started", data, state) do
    cond do
      Enum.any?(state.agents, &(&1.agent_id == data.agent_id)) ->
        {:error, {:validation_failed, "Agent #{data.agent_id} already exists"}}

      not is_binary(data.agent_id) or data.agent_id == "" ->
        {:error, {:validation_failed, "Agent ID must be a non-empty string"}}

      not is_binary(data.agent_type) or data.agent_type == "" ->
        {:error, {:validation_failed, "Agent type must be a non-empty string"}}

      not is_binary(data.workspace) or data.workspace == "" ->
        {:error, {:validation_failed, "Workspace path must be a non-empty string"}}

      true ->
        :ok
    end
  end

  defp validate_event("agent_completed", data, state) do
    agent = Enum.find(state.agents, &(&1.agent_id == data.agent_id))

    cond do
      agent == nil ->
        {:error, {:validation_failed, "Agent #{data.agent_id} not found"}}

      agent.status != :running ->
        {:error,
         {:validation_failed,
          "Agent #{data.agent_id} is not running (status: #{agent.status})"}}

      true ->
        :ok
    end
  end

  defp validate_event("agent_failed", data, state) do
    agent = Enum.find(state.agents, &(&1.agent_id == data.agent_id))

    cond do
      agent == nil ->
        {:error, {:validation_failed, "Agent #{data.agent_id} not found"}}

      agent.status != :running ->
        {:error,
         {:validation_failed,
          "Agent #{data.agent_id} is not running (status: #{agent.status})"}}

      not is_binary(data.error) or data.error == "" ->
        {:error, {:validation_failed, "Error message must be a non-empty string"}}

      true ->
        :ok
    end
  end

  defp validate_event("agent_interrupted", data, state) do
    agent = Enum.find(state.agents, &(&1.agent_id == data.agent_id))

    cond do
      agent == nil ->
        {:error, {:validation_failed, "Agent #{data.agent_id} not found"}}

      agent.status != :running ->
        {:error,
         {:validation_failed,
          "Agent #{data.agent_id} is not running (status: #{agent.status})"}}

      true ->
        :ok
    end
  end

  # External Sync Events
  defp validate_event("github_pr_created", data, state) do
    cond do
      not is_integer(data.pr_number) or data.pr_number <= 0 ->
        {:error, {:validation_failed, "PR number must be a positive integer"}}

      not is_binary(data.pr_url) or data.pr_url == "" ->
        {:error, {:validation_failed, "PR URL must be a non-empty string"}}

      state.external_sync.github.pr_number != nil ->
        {:error, {:validation_failed, "GitHub PR already exists for this task"}}

      true ->
        :ok
    end
  end

  defp validate_event("github_pr_merged", _data, state) do
    if state.external_sync.github.pr_number == nil do
      {:error, {:validation_failed, "No GitHub PR exists to merge"}}
    else
      :ok
    end
  end

  defp validate_event("jira_ticket_updated", data, _state) do
    cond do
      data[:ticket_id] && (not is_binary(data.ticket_id) or data.ticket_id == "") ->
        {:error, {:validation_failed, "JIRA ticket ID must be a non-empty string"}}

      true ->
        :ok
    end
  end

  # Workstream Events
  defp validate_event("workstream_spec_generated", data, state) do
    workstream = Map.get(state.workstreams, data.workstream_id)

    cond do
      workstream == nil ->
        {:error, {:validation_failed, "Workstream #{data.workstream_id} not found"}}

      not is_binary(data.spec) or data.spec == "" ->
        {:error, {:validation_failed, "Workstream spec must be a non-empty string"}}

      true ->
        :ok
    end
  end

  defp validate_event("workstream_created", data, state) do
    cond do
      Map.has_key?(state.workstreams, data.workstream_id) ->
        {:error, {:validation_failed, "Workstream #{data.workstream_id} already exists"}}

      not is_binary(data.workstream_id) or data.workstream_id == "" ->
        {:error, {:validation_failed, "Workstream ID must be a non-empty string"}}

      not is_binary(data.spec) or data.spec == "" ->
        {:error, {:validation_failed, "Workstream spec must be a non-empty string"}}

      data[:dependencies] && not is_list(data.dependencies) ->
        {:error, {:validation_failed, "Dependencies must be a list"}}

      true ->
        :ok
    end
  end

  defp validate_event("workstream_agent_started", data, state) do
    workstream = Map.get(state.workstreams, data.workstream_id)

    cond do
      workstream == nil ->
        {:error, {:validation_failed, "Workstream #{data.workstream_id} not found"}}

      workstream.status not in [:pending, :blocked] ->
        {:error,
         {:validation_failed,
          "Workstream #{data.workstream_id} is not pending or blocked (status: #{workstream.status})"}}

      not Enum.empty?(workstream.blocking_on) ->
        {:error,
         {:validation_failed,
          "Workstream #{data.workstream_id} has unresolved dependencies: #{inspect(workstream.blocking_on)}"}}

      state.active_workstream_count >= state.max_workstream_concurrency ->
        {:error,
         {:validation_failed,
          "Max workstream concurrency (#{state.max_workstream_concurrency}) reached"}}

      Enum.any?(state.agents, &(&1.agent_id == data.agent_id)) ->
        {:error, {:validation_failed, "Agent #{data.agent_id} already exists"}}

      true ->
        :ok
    end
  end

  defp validate_event("workstream_completed", data, state) do
    workstream = Map.get(state.workstreams, data.workstream_id)

    cond do
      workstream == nil ->
        {:error, {:validation_failed, "Workstream #{data.workstream_id} not found"}}

      workstream.status != :in_progress ->
        {:error,
         {:validation_failed,
          "Workstream #{data.workstream_id} is not in progress (status: #{workstream.status})"}}

      true ->
        :ok
    end
  end

  defp validate_event("workstream_failed", data, state) do
    workstream = Map.get(state.workstreams, data.workstream_id)

    cond do
      workstream == nil ->
        {:error, {:validation_failed, "Workstream #{data.workstream_id} not found"}}

      workstream.status != :in_progress ->
        {:error,
         {:validation_failed,
          "Workstream #{data.workstream_id} is not in progress (status: #{workstream.status})"}}

      not is_binary(data.error) or data.error == "" ->
        {:error, {:validation_failed, "Error message must be a non-empty string"}}

      true ->
        :ok
    end
  end

  # Communication Events
  defp validate_event("message_posted", data, state) do
    cond do
      Enum.any?(state.messages, &(&1.message_id == data.message_id)) ->
        {:error, {:validation_failed, "Message #{data.message_id} already exists"}}

      data.type not in [:question, :approval, :update, :blocker] ->
        {:error, {:validation_failed, "Invalid message type: #{data.type}"}}

      not is_binary(data.content) or data.content == "" ->
        {:error, {:validation_failed, "Message content must be a non-empty string"}}

      not is_binary(data.author) or data.author == "" ->
        {:error, {:validation_failed, "Message author must be a non-empty string"}}

      true ->
        :ok
    end
  end

  defp validate_event("approval_requested", data, state) do
    cond do
      Enum.any?(state.messages, &(&1.message_id == data.message_id)) ->
        {:error, {:validation_failed, "Message #{data.message_id} already exists"}}

      not is_binary(data.question) or data.question == "" ->
        {:error, {:validation_failed, "Approval question must be a non-empty string"}}

      not is_list(data.options) or length(data.options) < 2 ->
        {:error, {:validation_failed, "Approval must have at least 2 options"}}

      true ->
        :ok
    end
  end

  defp validate_event("approval_given", data, state) do
    message = Enum.find(state.messages, &(&1.message_id == data.message_id))

    cond do
      message == nil ->
        {:error, {:validation_failed, "Message #{data.message_id} not found"}}

      message.type != :approval ->
        {:error, {:validation_failed, "Message #{data.message_id} is not an approval request"}}

      message.approval_choice != nil ->
        {:error, {:validation_failed, "Approval #{data.message_id} has already been given"}}

      data.choice not in message.approval_options ->
        {:error, {:validation_failed, "Invalid approval choice: #{data.choice}"}}

      true ->
        :ok
    end
  end

  # Default: no validation required
  defp validate_event(_event_type, _data, _state), do: :ok

  # ============================================================================
  # Private Functions - Helpers
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:pod_state, task_id}}}
  end

  defp initial_state do
    %{
      task_id: nil,
      version: 0,
      created_at: nil,
      updated_at: nil,
      phase: :spec_clarification,
      title: "",
      spec: initial_spec(),
      plan: nil,
      agents: [],
      external_sync: initial_external_sync(),
      pending_transitions: [],
      workstreams: %{},
      max_workstream_concurrency: 3,
      active_workstream_count: 0,
      messages: [],
      inbox: []
    }
  end

  defp initial_spec do
    %{
      description: nil,
      requirements: [],
      acceptance_criteria: [],
      approved?: false,
      approved_by: nil,
      approved_at: nil
    }
  end

  defp initial_external_sync do
    %{
      github: %{pr_number: nil, pr_url: nil, pr_merged?: false, synced_at: nil},
      jira: %{ticket_id: nil, status: nil, synced_at: nil}
    }
  end

  # Normalize phase to atom
  defp normalize_phase(phase) when is_atom(phase), do: phase
  defp normalize_phase(phase) when is_binary(phase), do: String.to_existing_atom(phase)
  defp normalize_phase(_), do: nil

  defp valid_transition?(:spec_clarification, :planning), do: true
  defp valid_transition?(:planning, :workstream_execution), do: true
  defp valid_transition?(:workstream_execution, :review), do: true
  defp valid_transition?(:review, :completed), do: true
  defp valid_transition?(:review, :workstream_execution), do: true
  defp valid_transition?(_from, :cancelled), do: true
  defp valid_transition?(_from, _to), do: false

  # Message filtering helpers
  defp maybe_filter_by_thread_id(messages, nil), do: messages

  defp maybe_filter_by_thread_id(messages, thread_id) do
    Enum.filter(messages, fn msg ->
      msg.thread_id == thread_id || msg.message_id == thread_id
    end)
  end

  defp maybe_filter_by_workstream_id(messages, nil), do: messages

  defp maybe_filter_by_workstream_id(messages, workstream_id) do
    Enum.filter(messages, fn msg -> msg.workstream_id == workstream_id end)
  end

  defp maybe_filter_by_type(messages, nil), do: messages

  defp maybe_filter_by_type(messages, type) do
    Enum.filter(messages, fn msg -> msg.type == type end)
  end

  defp maybe_limit(messages, nil), do: messages
  defp maybe_limit(messages, limit) when is_integer(limit) and limit > 0, do: Enum.take(messages, limit)
  defp maybe_limit(messages, _), do: messages

  # Inbox filtering helpers
  defp maybe_filter_unread_only(inbox, true), do: Enum.filter(inbox, &(!&1.read?))
  defp maybe_filter_unread_only(inbox, _), do: inbox

  defp maybe_filter_by_recipient(inbox, nil), do: inbox

  defp maybe_filter_by_recipient(inbox, recipient) do
    Enum.filter(inbox, fn notif -> notif.recipient == recipient end)
  end

  # Transitive blocking helper - find all workstreams that depend (directly or indirectly) on a failed workstream
  defp find_transitively_blocked_workstreams(failed_id, workstreams) do
    find_transitively_blocked_workstreams([failed_id], workstreams, MapSet.new())
  end

  defp find_transitively_blocked_workstreams([], _workstreams, affected) do
    MapSet.to_list(affected)
  end

  defp find_transitively_blocked_workstreams([current_id | rest], workstreams, affected) do
    # Find workstreams that directly depend on current_id
    direct_dependents =
      workstreams
      |> Map.values()
      |> Enum.filter(fn ws ->
        current_id in (ws.blocking_on || []) && ws.status not in [:completed, :failed, :blocked]
      end)
      |> Enum.map(& &1.workstream_id)
      |> Enum.reject(&MapSet.member?(affected, &1))

    # Add direct dependents to affected set
    new_affected = Enum.reduce(direct_dependents, affected, &MapSet.put(&2, &1))

    # Recursively process direct dependents and remaining items
    find_transitively_blocked_workstreams(
      direct_dependents ++ rest,
      workstreams,
      new_affected
    )
  end
end
