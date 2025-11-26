defmodule Ipa.Pod.Scheduler do
  @moduledoc """
  Pod Scheduler - Workstream orchestration engine for task pods.

  The Pod Scheduler is the **brain** of the pod - it orchestrates multi-agent execution
  with dependency resolution, manages workstream lifecycle, and coordinates progress
  through threaded communications.

  ## Architecture

  The Scheduler is a **reactive** component that subscribes to pod-local pub-sub and
  responds to state changes. It implements a state machine with these phases:

  - `planning` - Break task into parallel workstreams via planning agent
  - `workstream_execution` - Orchestrate concurrent workstream agents with dependency management
  - `review` - Consolidate all workstream changes into single PR
  - `completed` - Task finished
  - `cancelled` - Task cancelled

  ## Key Responsibilities

  1. **Task Planning**: Generate workstream breakdown via planning agent
  2. **Workstream Orchestration**: Manage multiple concurrent workstreams
  3. **Dependency Management**: Ensure workstreams wait for dependencies
  4. **Agent Lifecycle**: Spawn, monitor, and cleanup agents
  5. **Failure Recovery**: Handle workstream failures with cascade detection
  6. **PR Consolidation**: Merge all workstream changes into single cohesive PR

  ## Registration

  Schedulers register via Registry with key `{:pod_scheduler, task_id}`.

  ## Pub-Sub

  Subscribes to topic `"pod:<task_id>:state"` for state updates.

  ## Dependencies

  - Event Store (1.1) - via Pod.State for appending events
  - Pod Supervisor (2.1) - parent supervisor
  - Pod State Manager (2.2) - for workstream/message state projections and pub-sub
  - Pod Workspace Manager (2.4) - for workspace lifecycle
  - Pod Communications Manager (2.7) - for threaded messaging and approvals
  - CLAUDE.md Templates (2.8) - for generating workstream-specific context
  - Claude Code SDK - for agent execution

  ## Examples

      # Start scheduler (called by Pod Supervisor)
      {:ok, pid} = Ipa.Pod.Scheduler.start_link(task_id: "task-123")

      # Interrupt a running agent
      :ok = Ipa.Pod.Scheduler.interrupt_agent("task-123", "agent-456")

      # Force immediate evaluation (testing)
      :ok = Ipa.Pod.Scheduler.evaluate_now("task-123")

      # Get scheduler state (debugging)
      {:ok, state} = Ipa.Pod.Scheduler.get_scheduler_state("task-123")
  """

  use GenServer
  require Logger

  @type task_id :: String.t()
  @type workstream_id :: String.t()
  @type agent_id :: String.t()
  @type phase :: :planning | :workstream_execution | :review | :completed | :cancelled

  # ============================================================================
  # State Definition
  # ============================================================================

  defstruct [
    # Core identifiers
    :task_id,

    # State machine
    :current_phase,
    :pending_action,

    # Evaluation tracking
    :last_evaluation,
    :evaluation_count,
    :evaluation_failure_count,
    :evaluation_scheduled?,

    # Cooldown management
    :cooldown_until,

    # Workstream agent tracking (CRITICAL for P0#5, P0#7)
    # Maps workstream_id to %{agent_id: string, agent_pid: pid, started_at: DateTime}
    :active_workstream_agents
  ]

  @type t :: %__MODULE__{
          task_id: task_id(),
          current_phase: phase(),
          pending_action: term(),
          last_evaluation: DateTime.t() | nil,
          evaluation_count: non_neg_integer(),
          evaluation_failure_count: non_neg_integer(),
          evaluation_scheduled?: boolean(),
          cooldown_until: DateTime.t() | nil,
          active_workstream_agents: %{workstream_id() => map()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the scheduler for a task.

  Called by Pod Supervisor. Registers via Registry, subscribes to pod-local pub-sub,
  loads initial state, handles orphaned agents, and performs initial evaluation.

  ## Options

  - `:task_id` - Required. Task UUID.

  ## Returns

  - `{:ok, pid}` - Scheduler started successfully
  - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, pid} = Ipa.Pod.Scheduler.start_link(task_id: "task-123")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc """
  Interrupts a running agent by killing its process.

  ## Parameters

  - `task_id` - Task UUID
  - `agent_id` - Agent ID to interrupt

  ## Returns

  - `:ok` - Agent interrupted successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  - `{:error, :agent_not_running}` - Agent is not currently running

  ## Examples

      :ok = Ipa.Pod.Scheduler.interrupt_agent("task-123", "agent-456")
  """
  @spec interrupt_agent(task_id(), agent_id()) :: :ok | {:error, atom()}
  def interrupt_agent(task_id, agent_id) do
    GenServer.call(via_tuple(task_id), {:interrupt_agent, agent_id})
  end

  @doc """
  Forces immediate state machine evaluation, bypassing cooldown.

  Use case: Testing, debugging, manual intervention.

  ## Parameters

  - `task_id` - Task UUID

  ## Returns

  - `:ok`

  ## Examples

      :ok = Ipa.Pod.Scheduler.evaluate_now("task-123")
  """
  @spec evaluate_now(task_id()) :: :ok
  def evaluate_now(task_id) do
    GenServer.call(via_tuple(task_id), :evaluate_now)
  end

  @doc """
  Returns the internal scheduler state for debugging/monitoring.

  ## Parameters

  - `task_id` - Task UUID

  ## Returns

  - `{:ok, state}` - Scheduler state
  - `{:error, :not_found}` - Scheduler not running

  ## Examples

      {:ok, state} = Ipa.Pod.Scheduler.get_scheduler_state("task-123")
  """
  @spec get_scheduler_state(task_id()) :: {:ok, map()} | {:error, :not_found}
  def get_scheduler_state(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :get_state)}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @doc false
  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    Logger.info("Starting Pod Scheduler", task_id: task_id)

    # Subscribe to state changes
    Ipa.Pod.State.subscribe(task_id)

    # Load initial state
    {:ok, task_state} = Ipa.Pod.State.get_state(task_id)

    # Check for orphaned workstream agents (from previous Scheduler crash)
    orphaned_workstreams = find_orphaned_workstreams(task_state)

    if length(orphaned_workstreams) > 0 do
      Logger.warning("Found orphaned workstream agents on restart",
        task_id: task_id,
        count: length(orphaned_workstreams)
      )

      # Mark them as failed
      mark_orphaned_workstreams_as_failed(task_id, orphaned_workstreams)
    end

    # Schedule initial evaluation
    send(self(), :evaluate)

    {:ok,
     %__MODULE__{
       task_id: task_id,
       current_phase: task_state.phase,
       pending_action: nil,
       last_evaluation: nil,
       evaluation_count: 0,
       evaluation_failure_count: 0,
       evaluation_scheduled?: true,
       cooldown_until: nil,
       active_workstream_agents: %{}
     }}
  end

  @doc false
  @impl true
  def handle_info({:state_updated, _task_id, new_state}, state) do
    Logger.debug("Scheduler received state update",
      task_id: state.task_id,
      phase: new_state.phase
    )

    # Schedule evaluation if not already scheduled and not in cooldown
    new_state_record = schedule_evaluation_if_needed(state)

    {:noreply, %{new_state_record | current_phase: new_state.phase}}
  end

  @doc false
  @impl true
  def handle_info(:evaluate, state) do
    # Clear scheduled flag
    state = %{state | evaluation_scheduled?: false}

    # Check if in cooldown
    now = DateTime.utc_now()

    if state.cooldown_until && DateTime.compare(now, state.cooldown_until) == :lt do
      # Still in cooldown, reschedule
      remaining_ms = DateTime.diff(state.cooldown_until, now, :millisecond)
      Process.send_after(self(), :evaluate, remaining_ms)
      {:noreply, %{state | evaluation_scheduled?: true}}
    else
      # Perform evaluation with error handling
      start_time = System.monotonic_time()

      try do
        # Load fresh task state
        {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

        Logger.debug("Scheduler evaluating",
          task_id: state.task_id,
          phase: task_state.phase,
          workstreams: map_size(task_state.workstreams || %{}),
          plan_approved: task_state.plan != nil && task_state.plan.approved?
        )

        # Evaluate state machine
        action = evaluate_state_machine(task_state, state)

        Logger.info("State machine returned action",
          task_id: state.task_id,
          action: inspect(action)
        )

        # Execute action
        new_state = execute_action(action, task_state, state)

        # Reset failure count on successful evaluation
        new_state = %{new_state | evaluation_failure_count: 0}

        # Emit telemetry
        duration_ms =
          (System.monotonic_time() - start_time)
          |> System.convert_time_unit(:native, :millisecond)

        :telemetry.execute(
          [:ipa, :scheduler, :evaluation, :duration],
          %{duration: duration_ms},
          %{task_id: state.task_id, phase: new_state.current_phase}
        )

        if duration_ms > 100 do
          Logger.warning("Slow evaluation",
            duration_ms: duration_ms,
            task_id: state.task_id
          )
        end

        {:noreply, new_state}
      rescue
        error ->
          # Capture error with full context
          stacktrace = __STACKTRACE__
          Logger.error("State machine evaluation failed",
            error: inspect(error),
            error_message: Exception.message(error),
            stacktrace: Exception.format_stacktrace(stacktrace),
            task_id: state.task_id,
            phase: state.current_phase
          )

          # Emit telemetry event
          :telemetry.execute(
            [:ipa, :scheduler, :evaluation, :error],
            %{count: 1},
            %{error: inspect(error), task_id: state.task_id}
          )

          # Best effort: record error event
          record_scheduler_error(state.task_id, error, stacktrace)

          # Enter cooldown with exponential backoff
          failure_count = state.evaluation_failure_count + 1
          cooldown_ms = calculate_error_cooldown(failure_count)

          Logger.info("Entering error cooldown",
            failure_count: failure_count,
            cooldown_ms: cooldown_ms
          )

          new_state =
            enter_cooldown(
              %{state | evaluation_failure_count: failure_count},
              :custom,
              cooldown_ms
            )

          {:noreply, new_state}
      end
    end
  end

  # Catch-all handler for unexpected messages (e.g., :workspace_created from WorkspaceManager)
  @doc false
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Scheduler ignoring message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc false
  @impl true
  def handle_call({:interrupt_agent, agent_id}, _from, state) do
    # Find the workstream for this agent
    case find_workstream_for_agent(state.active_workstream_agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      {workstream_id, agent_info} ->
        Logger.info("Interrupting agent", agent_id: agent_id, workstream_id: workstream_id)

        # Kill the agent process
        Process.exit(agent_info.agent_pid, :kill)

        # Load current task state
        {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

        # Record event
        Ipa.Pod.State.append_event(
          state.task_id,
          "workstream_interrupted",
          %{
            workstream_id: workstream_id,
            agent_id: agent_id,
            interrupted_by: "manual",
            interrupted_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          task_state.version,
          actor_id: "user"
        )

        # Cleanup workspace
        Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, workstream_id, agent_id)

        # Remove from tracking
        new_active = Map.delete(state.active_workstream_agents, workstream_id)

        new_state = %{state | active_workstream_agents: new_active}

        # Trigger immediate re-evaluation
        send(self(), :evaluate)
        new_state = %{new_state | evaluation_scheduled?: true}

        {:reply, :ok, new_state}
    end
  end

  @doc false
  @impl true
  def handle_call(:evaluate_now, _from, state) do
    # Force immediate evaluation
    send(self(), :evaluate)
    {:reply, :ok, %{state | evaluation_scheduled?: true, cooldown_until: nil}}
  end

  @doc false
  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @doc false
  @impl true
  def terminate(reason, state) do
    Logger.info("Pod Scheduler terminating", task_id: state.task_id, reason: inspect(reason))

    # Interrupt all active workstream agents
    for {workstream_id, agent_info} <- state.active_workstream_agents do
      Logger.info("Killing orphaned agent on shutdown",
        workstream_id: workstream_id,
        agent_id: agent_info.agent_id
      )

      Process.exit(agent_info.agent_pid, :kill)
    end

    :ok
  end

  # ============================================================================
  # State Machine Evaluation
  # ============================================================================

  defp evaluate_state_machine(task_state, scheduler_state) do
    # Normalize phase to atom (may come as string from event data)
    phase =
      case task_state.phase do
        phase when is_atom(phase) -> phase
        phase when is_binary(phase) -> String.to_existing_atom(phase)
      end

    case phase do
      :planning ->
        evaluate_planning(task_state, scheduler_state)

      :workstream_execution ->
        evaluate_workstream_execution(task_state, scheduler_state)

      :review ->
        evaluate_review(task_state, scheduler_state)

      :completed ->
        {:wait, :task_completed}

      :cancelled ->
        {:wait, :task_cancelled}

      :spec_clarification ->
        # Check if spec is approved and request transition to planning
        spec_approved = task_state.spec != nil &&
          (task_state.spec[:approved?] || task_state.spec["approved?"] || false)

        # Check if there's already a pending transition to planning
        has_pending_planning_transition = Enum.any?(
          task_state.pending_transitions || [],
          fn t -> t.to_phase == :planning || t.to_phase == "planning" end
        )

        cond do
          # Already have a pending transition - wait for approval
          has_pending_planning_transition ->
            {:approve_required, :phase_transition}

          # Spec approved and no pending transition - request transition
          spec_approved ->
            {:transition, :planning, "Spec approved, proceeding to planning phase"}

          # Spec not approved - wait
          true ->
            {:wait, :waiting_for_spec}
        end
    end
  rescue
    ArgumentError ->
      # Unknown phase string
      Logger.error("Unknown phase", phase: task_state.phase, task_id: task_state.task_id)
      {:wait, :unknown_phase}
  end

  # ----------------------------------------------------------------------------
  # Phase: planning
  # ----------------------------------------------------------------------------

  defp evaluate_planning(task_state, scheduler_state) do
    workstreams = task_state.workstreams || %{}
    plan_approved = task_state.plan != nil && task_state.plan.approved?
    plan_has_workstreams = task_state.plan != nil &&
      (task_state.plan[:workstreams] || task_state.plan["workstreams"] || []) != []

    cond do
      # Workstreams created and plan approved → transition to workstream_execution
      map_size(workstreams) > 0 && plan_approved ->
        {:transition, :workstream_execution, "Workstream plan approved"}

      # Workstreams created but not approved → wait for approval
      map_size(workstreams) > 0 && !plan_approved ->
        {:approve_required, :workstream_plan}

      # Plan approved with workstream data but workstreams not created yet → create them
      plan_approved && plan_has_workstreams && map_size(workstreams) == 0 ->
        {:create_workstreams, task_state.plan}

      # Planning agent completed → parse and create workstreams
      planning_agent_completed?(task_state) ->
        {:create_workstreams, task_state.plan}

      # No planning agent and no workstreams → spawn planning agent
      map_size(workstreams) == 0 && no_planning_agent_running?(scheduler_state, task_state) ->
        {:spawn_planning_agent, generate_planning_agent_prompt(task_state)}

      # Agent working → wait
      true ->
        {:wait, :planning_agent_working}
    end
  end

  # ----------------------------------------------------------------------------
  # Phase: workstream_execution
  # ----------------------------------------------------------------------------

  defp evaluate_workstream_execution(task_state, scheduler_state) do
    workstreams = task_state.workstreams || %{}

    # P0#2: Check for deadlock first
    case detect_deadlock(workstreams) do
      {:deadlock, stuck_workstreams} ->
        Logger.error("Deadlock detected",
          stuck_workstreams: Enum.map(stuck_workstreams, & &1.workstream_id),
          task_id: task_state.task_id
        )

        # Post blocker via Communications Manager
        post_deadlock_blocker(task_state.task_id, stuck_workstreams)

        {:wait, :deadlock_detected}

      :no_deadlock ->
        cond do
          # All workstreams completed → transition to review
          all_workstreams_completed?(workstreams) ->
            {:transition, :review, "All workstreams completed"}

          # Max concurrent workstreams reached → wait (P0#7: uses scheduler state)
          max_workstreams_reached?(workstreams, scheduler_state) ->
            {:wait, :max_workstreams_reached}

          # Find ready workstream → spawn it
          true ->
            case find_ready_workstream(workstreams, scheduler_state) do
              {:ok, workstream} ->
                {:spawn_workstream_agent, workstream}

              {:error, :none_ready} ->
                {:wait, :workstreams_blocked_or_running}
            end
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Phase: review
  # ----------------------------------------------------------------------------

  defp evaluate_review(task_state, scheduler_state) do
    cond do
      # PR merged → transition to completed
      pr_merged?(task_state) ->
        {:transition, :completed, "PR merged"}

      # No PR created → spawn PR consolidation agent (P0#6)
      !pr_created?(task_state) && no_pr_agent_running?(scheduler_state, task_state) ->
        {:spawn_pr_agent, generate_pr_consolidation_prompt(task_state)}

      # PR has comments → spawn comment resolver agent
      pr_has_comments?(task_state) && no_pr_agent_running?(scheduler_state, task_state) ->
        {:spawn_pr_comment_resolver, generate_pr_comment_prompt(task_state)}

      # Waiting for PR review → wait
      pr_created?(task_state) ->
        {:approve_required, :pr_review}

      # Default → wait
      true ->
        {:wait, :no_action_needed}
    end
  end

  # ----------------------------------------------------------------------------
  # State Machine Helper Functions
  # ----------------------------------------------------------------------------

  defp all_workstreams_completed?(workstreams) do
    workstreams
    |> Map.values()
    |> Enum.all?(fn ws -> ws.status == :completed end)
  end

  # P0#2: Find a ready workstream (dependencies satisfied)
  defp find_ready_workstream(workstreams, scheduler_state) do
    ready =
      workstreams
      |> Map.values()
      |> Enum.filter(fn ws ->
        is_pending = ws.status == :pending
        deps_satisfied = Enum.empty?(ws.blocking_on || [])
        not_running = !Map.has_key?(scheduler_state.active_workstream_agents, ws.workstream_id)

        # P0#2: Defensive check - all dependencies exist
        all_deps_exist =
          Enum.all?(ws.dependencies || [], fn dep_id ->
            Map.has_key?(workstreams, dep_id)
          end)

        is_pending && deps_satisfied && not_running && all_deps_exist
      end)
      # Prioritize by dependency count (fewer deps = higher priority)
      |> Enum.sort_by(fn ws -> length(ws.dependencies || []) end)
      |> List.first()

    case ready do
      nil -> {:error, :none_ready}
      ws -> {:ok, ws}
    end
  end

  # P0#7: Check if max concurrent workstreams limit is reached
  defp max_workstreams_reached?(_workstreams, scheduler_state) do
    max = Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_workstream_concurrency] || 3
    active_count = map_size(scheduler_state.active_workstream_agents)
    active_count >= max
  end

  # P0#2: Detect deadlock (pending workstreams blocked but nothing running AND nothing can start)
  defp detect_deadlock(workstreams) do
    pending_with_blocks =
      workstreams
      |> Map.values()
      |> Enum.filter(fn ws -> ws.status == :pending && !Enum.empty?(ws.blocking_on || []) end)

    any_in_progress =
      workstreams
      |> Map.values()
      |> Enum.any?(fn ws -> ws.status == :in_progress end)

    # Check if there are any pending workstreams that CAN be started (no blocking dependencies)
    any_ready_to_start =
      workstreams
      |> Map.values()
      |> Enum.any?(fn ws -> ws.status == :pending && Enum.empty?(ws.blocking_on || []) end)

    # Only deadlock if there are blocked workstreams AND nothing is running AND nothing can be started
    if length(pending_with_blocks) > 0 && !any_in_progress && !any_ready_to_start do
      {:deadlock, pending_with_blocks}
    else
      :no_deadlock
    end
  end

  # PR helper functions
  defp pr_created?(task_state) do
    get_in(task_state, [:external_sync, :github, :pr_number]) != nil
  end

  defp pr_merged?(task_state) do
    get_in(task_state, [:external_sync, :github, :pr_merged?]) == true
  end

  defp pr_has_comments?(task_state) do
    (get_in(task_state, [:external_sync, :github, :unresolved_comments_count]) || 0) > 0
  end

  # Agent state check functions
  defp no_planning_agent_running?(scheduler_state, task_state) do
    # Check if any agent is running in planning phase
    map_size(scheduler_state.active_workstream_agents) == 0 &&
      !Enum.any?(task_state.agents || [], fn agent ->
        agent.agent_type == "planning_agent" && agent.status == :running
      end)
  end

  defp planning_agent_completed?(task_state) do
    Enum.any?(task_state.agents || [], fn agent ->
      agent.agent_type == "planning_agent" && agent.status == :completed
    end)
  end

  defp no_pr_agent_running?(_scheduler_state, task_state) do
    # Check if PR agent is running
    !Enum.any?(task_state.agents || [], fn agent ->
      agent.agent_type in ["pr_agent", "pr_consolidation_agent", "pr_comment_resolver_agent"] &&
        agent.status == :running
    end)
  end

  defp post_deadlock_blocker(task_id, stuck_workstreams) do
    # TODO: Implement when Communications Manager (2.7) is available
    # For now, just log
    Logger.error("Deadlock: Manual intervention required",
      task_id: task_id,
      stuck_workstreams: Enum.map(stuck_workstreams, & &1.workstream_id)
    )

    :ok
  end

  # ============================================================================
  # Action Execution
  # ============================================================================

  defp execute_action(action, task_state, scheduler_state) do
    case action do
      {:spawn_planning_agent, prompt} ->
        spawn_planning_agent(prompt, task_state, scheduler_state)

      {:create_workstreams, plan} ->
        create_workstreams_from_plan(plan, task_state, scheduler_state)

      {:spawn_workstream_agent, workstream} ->
        spawn_workstream_agent(workstream, task_state, scheduler_state)

      {:spawn_pr_agent, prompt} ->
        spawn_pr_agent(prompt, task_state, scheduler_state)

      {:spawn_pr_comment_resolver, prompt} ->
        spawn_pr_comment_resolver(prompt, task_state, scheduler_state)

      {:transition, to_phase, reason} ->
        request_transition(to_phase, reason, task_state, scheduler_state)

      {:wait, reason} ->
        Logger.info("Scheduler waiting", task_id: task_state.task_id, reason: reason)
        scheduler_state = enter_cooldown(scheduler_state, :wait)
        %{scheduler_state | pending_action: {:wait, reason}}

      {:approve_required, item} ->
        Logger.info("Approval required", task_id: task_state.task_id, item: item)
        enter_cooldown(scheduler_state, :approval)

      {:cooldown, duration_ms} ->
        enter_cooldown(scheduler_state, :custom, duration_ms)
    end
  end

  # ----------------------------------------------------------------------------
  # Action: Spawn Planning Agent
  # ----------------------------------------------------------------------------

  defp spawn_planning_agent(_prompt, _task_state, scheduler_state) do
    # TODO: Implement when Claude Code SDK is integrated
    Logger.info("Would spawn planning agent", task_id: scheduler_state.task_id)
    scheduler_state = enter_cooldown(scheduler_state, :wait)
    %{scheduler_state | pending_action: {:wait, :planning_agent_working}}
  end

  # ----------------------------------------------------------------------------
  # Action: Create Workstreams from Plan (P0#2: Circular dependency detection)
  # ----------------------------------------------------------------------------

  defp create_workstreams_from_plan(plan, task_state, scheduler_state) do
    Logger.info("Creating workstreams from plan", task_id: task_state.task_id)

    # Parse workstream plan
    workstreams = parse_workstream_plan(plan)

    # P0#2: Validate no circular dependencies
    case validate_dependency_graph(workstreams) do
      :ok ->
        Logger.info("Workstream plan validated, creating workstreams",
          task_id: task_state.task_id,
          workstream_count: length(workstreams)
        )

        # Create workstream_created events
        # Use Enum.reduce to track the version as we create each workstream
        {_final_version, _results} =
          Enum.reduce(workstreams, {task_state.version, []}, fn ws, {current_version, results} ->
            workstream_id = ws.id || generate_workstream_id()

            case Ipa.Pod.State.append_event(
                   task_state.task_id,
                   "workstream_created",
                   %{
                     workstream_id: workstream_id,
                     title: ws.title,
                     spec: ws.description,
                     dependencies: ws.dependencies || [],
                     estimated_hours: ws.estimated_hours
                   },
                   current_version,
                   actor_id: "scheduler"
                 ) do
              {:ok, new_version} ->
                Logger.info("Created workstream", workstream_id: workstream_id)
                {new_version, [{:ok, workstream_id} | results]}

              {:error, reason} ->
                Logger.error("Failed to create workstream",
                  workstream_id: workstream_id,
                  error: inspect(reason)
                )

                {current_version, [{:error, reason} | results]}
            end
          end)

        # Enter cooldown
        enter_cooldown(scheduler_state, :workstream_spawn)

      {:error, :circular_dependency, cycle} ->
        Logger.error("Circular dependency detected in workstream plan",
          cycle: cycle,
          task_id: task_state.task_id
        )

        # Post blocker (TODO: use Communications Manager when available)
        Logger.error("Planning agent generated circular dependency",
          task_id: task_state.task_id,
          cycle: inspect(cycle)
        )

        # Transition back to planning for replanning
        request_transition(:planning, "Circular dependency detected", task_state, scheduler_state)
    end
  end

  # ----------------------------------------------------------------------------
  # Action: Spawn Workstream Agent (P0#4, P0#5)
  # ----------------------------------------------------------------------------

  defp spawn_workstream_agent(workstream, task_state, scheduler_state) do
    task_id = task_state.task_id
    workstream_id = workstream.workstream_id
    agent_id = "workstream-agent-#{workstream_id}-#{System.unique_integer([:positive])}"

    Logger.info("Spawning workstream agent",
      task_id: task_id,
      workstream_id: workstream_id,
      agent_id: agent_id
    )

    # Generate workstream-level CLAUDE.md with full context
    {:ok, claude_md} =
      Ipa.Pod.ClaudeMdTemplates.generate_workstream_level(task_id, workstream_id)

    # Create workspace for workstream agent
    case Ipa.Pod.WorkspaceManager.create_workspace(task_id, agent_id, %{claude_md: claude_md}) do
      {:ok, workspace_path} ->
        Logger.info("Created workstream agent workspace",
          workstream_id: workstream_id,
          workspace_path: workspace_path
        )

        # Build workstream-specific prompt
        prompt = """
        You are a specialized agent working on a specific workstream within a larger task.

        ## Your Workstream
        **ID**: #{workstream_id}
        **Spec**: #{workstream.spec}

        ## Dependencies
        #{if Enum.empty?(workstream.dependencies), do: "None - you can start immediately!", else: "Your dependencies are complete: #{Enum.join(workstream.dependencies, ", ")}"}

        ## Your Mission
        Implement the workstream spec above. Work in the `work/` directory. Create high-quality code with tests.
        When done, commit your changes with a descriptive message.

        **IMPORTANT**: Mark your work as complete by creating a file called `WORKSTREAM_COMPLETE.md` with a summary of what you accomplished.
        """

        # Spawn Claude Code agent in background (monitored, not linked - so scheduler doesn't crash if agent crashes)
        agent_pid =
          spawn(fn ->
            spawn_claude_agent(
              agent_id,
              task_id,
              workspace_path,
              prompt,
              :workstream,
              workstream_id
            )
          end)

        # Monitor the process so we can track when it completes
        Process.monitor(agent_pid)

        # Track agent in scheduler state
        active_agents =
          Map.put(scheduler_state.active_workstream_agents, workstream_id, %{
            agent_id: agent_id,
            agent_pid: agent_pid,
            started_at: DateTime.utc_now()
          })

        # Append agent_started event (don't check version - workspace creation already advanced it)
        Ipa.Pod.State.append_event(
          task_id,
          "agent_started",
          %{
            agent_id: agent_id,
            agent_type: :workstream,
            workstream_id: workstream_id,
            prompt: prompt
          },
          nil,  # Don't check version - defensive to avoid conflicts
          actor_id: "scheduler"
        )

        # Also mark workstream as in_progress
        Ipa.Pod.State.append_event(
          task_id,
          "workstream_agent_started",
          %{
            workstream_id: workstream_id,
            agent_id: agent_id
          },
          nil,  # Don't check version - defensive to avoid conflicts
          actor_id: "scheduler"
        )

        # Enter cooldown with updated agent tracking
        %{enter_cooldown(scheduler_state, :workstream_spawn) | active_workstream_agents: active_agents}

      {:error, reason} ->
        Logger.error("Failed to create workstream agent workspace",
          workstream_id: workstream_id,
          error: reason
        )

        enter_cooldown(scheduler_state, :workstream_spawn)
    end
  end

  # ----------------------------------------------------------------------------
  # Action: Spawn PR Agent (P0#6: Multi-workstream consolidation)
  # ----------------------------------------------------------------------------

  defp spawn_pr_agent(prompt, task_state, scheduler_state) do
    task_id = task_state.task_id
    agent_id = "pr-agent-#{System.unique_integer([:positive])}"

    Logger.info("Spawning PR consolidation agent",
      task_id: task_id,
      agent_id: agent_id
    )

    # Generate pod-level CLAUDE.md (PR agent works at task level)
    {:ok, claude_md} = Ipa.Pod.ClaudeMdTemplates.generate_pod_level(task_id)

    # Create workspace for PR agent
    case Ipa.Pod.WorkspaceManager.create_workspace(task_id, agent_id, %{claude_md: claude_md}) do
      {:ok, workspace_path} ->
        Logger.info("Created PR agent workspace", workspace_path: workspace_path)

        # Spawn Claude Code agent in background (monitored, not linked)
        agent_pid = spawn(fn ->
          spawn_claude_agent(
            agent_id,
            task_id,
            workspace_path,
            prompt,
            :pr_consolidation
          )
        end)

        # Monitor the process
        Process.monitor(agent_pid)

        # Append agent_started event (don't check version - defensive)
        Ipa.Pod.State.append_event(
          task_id,
          "agent_started",
          %{
            agent_id: agent_id,
            agent_type: :pr_consolidation,
            workstream_id: nil,
            prompt: prompt
          },
          nil,  # Don't check version - defensive to avoid conflicts
          actor_id: "scheduler"
        )

        # Enter cooldown and wait for completion
        enter_cooldown(scheduler_state, :wait)

      {:error, reason} ->
        Logger.error("Failed to create PR agent workspace", error: reason)
        enter_cooldown(scheduler_state, :wait)
    end
  end

  # ----------------------------------------------------------------------------
  # Action: Spawn PR Comment Resolver
  # ----------------------------------------------------------------------------

  defp spawn_pr_comment_resolver(_prompt, _task_state, scheduler_state) do
    # TODO: Implement PR comment resolver agent
    Logger.info("Would spawn PR comment resolver agent", task_id: scheduler_state.task_id)
    enter_cooldown(scheduler_state, :wait)
  end

  # ----------------------------------------------------------------------------
  # Action: Request Transition
  # ----------------------------------------------------------------------------

  defp request_transition(to_phase, reason, task_state, scheduler_state) do
    Logger.info("Requesting transition",
      task_id: task_state.task_id,
      from: task_state.phase,
      to: to_phase,
      reason: reason
    )

    # Append transition requested event with version conflict handling
    case Ipa.Pod.State.append_event(
           task_state.task_id,
           "transition_requested",
           %{
             from_phase: task_state.phase,
             to_phase: to_phase,
             reason: reason
           },
           task_state.version,
           actor_id: "scheduler"
         ) do
      {:ok, _version} ->
        # Enter cooldown
        enter_cooldown(scheduler_state, :transition_request)

      {:error, :version_conflict} ->
        Logger.warning("Version conflict when requesting transition, will retry")
        # Enter short cooldown and try again
        enter_cooldown(scheduler_state, :version_conflict, 5_000)

      {:error, reason} ->
        Logger.error("Failed to request transition", error: reason)
        enter_cooldown(scheduler_state, :transition_request)
    end
  end

  # ============================================================================
  # Dependency Management (P0#2)
  # ============================================================================

  defp parse_workstream_plan(plan) do
    # Parse workstreams from plan data
    case plan do
      # Handle atom keys (from event store)
      %{workstreams: workstreams} when is_list(workstreams) ->
        Enum.map(workstreams, &parse_workstream/1)

      # Handle string keys (from JSON)
      %{"workstreams" => workstreams} when is_list(workstreams) ->
        Enum.map(workstreams, &parse_workstream/1)

      file_path when is_binary(file_path) ->
        # Read JSON file and parse
        case File.read(file_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"workstreams" => workstreams}} ->
                Enum.map(workstreams, &parse_workstream/1)

              _ ->
                []
            end

          {:error, reason} ->
            Logger.error("Failed to read workstream plan file", error: reason)
            []
        end

      _ ->
        []
    end
  end

  defp parse_workstream(ws) do
    # Handle both string keys (from JSON) and atom keys (from event store)
    %{
      id: ws["id"] || ws[:id],
      title: ws["title"] || ws[:title],
      description: ws["description"] || ws[:description],
      dependencies: ws["dependencies"] || ws[:dependencies] || [],
      estimated_hours: ws["estimated_hours"] || ws[:estimated_hours]
    }
  end

  # P0#2: Circular dependency detection using DFS
  defp validate_dependency_graph(workstreams) do
    # Build adjacency list
    graph = Map.new(workstreams, fn ws -> {ws.id, ws.dependencies} end)

    # Detect cycles
    case find_cycle(graph) do
      nil -> :ok
      cycle -> {:error, :circular_dependency, cycle}
    end
  end

  defp find_cycle(graph) do
    visited = MapSet.new()

    Enum.find_value(Map.keys(graph), fn node ->
      if node not in visited do
        detect_cycle_dfs(node, graph, visited, MapSet.new(), [node])
      end
    end)
  end

  defp detect_cycle_dfs(node, graph, visited, rec_stack, path) do
    visited = MapSet.put(visited, node)
    rec_stack = MapSet.put(rec_stack, node)

    # Check each dependency
    result =
      Enum.find_value(graph[node] || [], fn dep ->
        cond do
          # Cycle detected!
          dep in rec_stack ->
            cycle_start_idx = Enum.find_index(path, fn n -> n == dep end)
            Enum.slice(path, cycle_start_idx..-1//1) ++ [dep]

          # Unvisited node, recurse
          dep not in visited ->
            detect_cycle_dfs(dep, graph, visited, rec_stack, path ++ [dep])

          # Already visited in different branch, safe
          true ->
            nil
        end
      end)

    # Return result if cycle found, otherwise nil
    result
  end

  # ============================================================================
  # Prompt Generation
  # ============================================================================

  defp generate_planning_agent_prompt(task_state) do
    spec_description =
      case task_state.spec do
        %{description: desc} when is_binary(desc) -> desc
        %{} -> "No spec description provided"
        _ -> "No spec provided"
      end

    """
    Task: #{task_state.title}

    Spec: #{spec_description}

    Your role: Break this task down into parallel workstreams.

    Each workstream should:
    - Be independently executable (minimal dependencies)
    - Have a clear, specific goal
    - Be assignable to one agent
    - Take approximately 1-3 days

    Consider:
    - What can be done in parallel?
    - What dependencies exist between workstreams?
    - What's the critical path?

    Output a JSON structure to file `workstreams_plan.json`:
    {
      "workstreams": [
        {
          "id": "ws-1",
          "title": "Set up database schema",
          "description": "...",
          "dependencies": [],
          "estimated_hours": 8
        },
        {
          "id": "ws-2",
          "title": "Implement API endpoints",
          "description": "...",
          "dependencies": ["ws-1"],
          "estimated_hours": 12
        }
      ]
    }
    """
  end

  defp generate_pr_consolidation_prompt(task_state) do
    # P0#6: Multi-workstream PR consolidation
    workstreams = task_state.workstreams || %{}

    workstream_summaries =
      workstreams
      |> Map.values()
      |> Enum.filter(fn ws -> ws.status == :completed end)
      |> Enum.map(fn ws ->
        """
        ## Workstream: #{ws.title || ws.workstream_id}
        - ID: #{ws.workstream_id}
        - Spec: #{ws.spec || "No spec"}
        - Status: Completed
        """
      end)
      |> Enum.join("\n\n")

    """
    Task: #{task_state.title}

    Your role: Consolidate all workstream changes into a single PR.

    ## Completed Workstreams
    #{workstream_summaries}

    Instructions:
    1. Set up consolidated workspace (checkout main, create task branch)
    2. For each workstream: cherry-pick or merge commits from workstream workspace
    3. Resolve conflicts
    4. Run full test suite
    5. Write comprehensive PR description
    6. Create PR via gh CLI

    Important:
    - PR should be single cohesive change
    - Ensure commit messages follow conventions
    - Tag PR with relevant labels
    """
  end

  defp generate_pr_comment_prompt(task_state) do
    pr_number = get_in(task_state, [:external_sync, :github, :pr_number])

    """
    Task: #{task_state.title}

    PR ##{pr_number} has comments that need to be addressed.

    Your role:
    1. Read PR comments (gh pr view #{pr_number} --comments)
    2. Make the requested changes
    3. Run tests to verify changes
    4. Push the updates

    Execute: Address all PR comments.
    """
  end

  defp generate_workstream_id() do
    "ws-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  # ============================================================================
  # Support Functions
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:pod_scheduler, task_id}}}
  end

  defp find_orphaned_workstreams(task_state) do
    # Find workstreams that have status :in_progress (agent running)
    (task_state.workstreams || %{})
    |> Map.values()
    |> Enum.filter(fn ws -> ws.status == :in_progress end)
  end

  defp mark_orphaned_workstreams_as_failed(task_id, orphaned_workstreams) do
    for workstream <- orphaned_workstreams do
      case Ipa.Pod.State.append_event(
             task_id,
             "workstream_failed",
             %{
               workstream_id: workstream.workstream_id,
               agent_id: workstream.agent_id,
               error: "Scheduler restarted while workstream agent was running",
               failed_at: DateTime.utc_now() |> DateTime.to_unix(),
               affected_workstreams: []
             },
             # Don't check version on restart
             nil,
             actor_id: "scheduler"
           ) do
        {:ok, _version} ->
          Logger.info("Marked orphaned workstream as failed",
            workstream_id: workstream.workstream_id
          )

        {:error, reason} ->
          Logger.error("Failed to mark orphaned workstream as failed",
            workstream_id: workstream.workstream_id,
            error: reason
          )
      end
    end
  end

  defp schedule_evaluation_if_needed(state) do
    cond do
      state.evaluation_scheduled? ->
        # Already scheduled
        state

      state.cooldown_until != nil ->
        # In cooldown, evaluation already scheduled for cooldown end
        state

      true ->
        # Schedule evaluation
        Process.send_after(self(), :evaluate, 1_000)
        %{state | evaluation_scheduled?: true}
    end
  end

  defp record_scheduler_error(task_id, error, stacktrace) do
    try do
      {:ok, task_state} = Ipa.Pod.State.get_state(task_id)

      Ipa.Pod.State.append_event(
        task_id,
        "scheduler_error",
        %{
          error: inspect(error),
          phase: task_state.phase,
          stacktrace: Exception.format_stacktrace(stacktrace)
        },
        # Don't check version on error
        nil,
        actor_id: "scheduler"
      )
    rescue
      # If this fails, just continue
      _e -> :ok
    end
  end

  defp calculate_error_cooldown(failure_count) do
    # Exponential backoff: 60s, 120s, 240s, max 5 minutes
    min(300_000, 60_000 * :math.pow(2, failure_count - 1))
    |> round()
  end

  defp enter_cooldown(scheduler_state, cooldown_type, custom_duration_ms \\ nil) do
    duration_ms =
      case cooldown_type do
        :workstream_spawn -> 10_000
        :workstream_complete -> 15_000
        :transition_request -> 30_000
        :approval -> 60_000
        :wait -> 30_000
        :spawn_failure -> 60_000
        :version_conflict -> 5_000
        :custom -> custom_duration_ms
      end

    cooldown_until = DateTime.utc_now() |> DateTime.add(duration_ms, :millisecond)

    # Schedule next evaluation
    Process.send_after(self(), :evaluate, duration_ms)

    %{
      scheduler_state
      | cooldown_until: cooldown_until,
        last_evaluation: DateTime.utc_now(),
        evaluation_count: scheduler_state.evaluation_count + 1,
        evaluation_scheduled?: true
    }
  end

  defp find_workstream_for_agent(active_workstream_agents, agent_id) do
    Enum.find(active_workstream_agents, fn {_ws_id, agent_info} ->
      agent_info.agent_id == agent_id
    end)
  end

  # ----------------------------------------------------------------------------
  # Claude Code SDK Integration
  # ----------------------------------------------------------------------------

  # Spawn a Claude Code agent with streaming output
  # This function runs in a background process (spawned via spawn + monitor)
  defp spawn_claude_agent(agent_id, task_id, workspace_path, prompt, agent_type, workstream_id \\ nil) do
    Logger.info("Starting Claude Code agent",
      agent_id: agent_id,
      task_id: task_id,
      agent_type: agent_type,
      workstream_id: workstream_id,
      workspace: workspace_path
    )

    # Start Claude Code session with workspace context
    # NOTE: We omit api_key, so it delegates to Claude CLI (AWS Bedrock)
    session_opts = [
      cwd: workspace_path,
      allowed_tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      model: "sonnet",
      timeout: 3_600_000  # 1 hour timeout
    ]

    case ClaudeCode.start_link(session_opts) do
      {:ok, session} ->
        Logger.info("Claude Code session started",
          agent_id: agent_id,
          session: inspect(session)
        )

        # Query Claude with the prompt (non-streaming for simplicity)
        case ClaudeCode.query(session, prompt, timeout: 3_600_000) do
          {:ok, response} ->
            Logger.info("Agent completed successfully",
              agent_id: agent_id,
              response_length: String.length(response)
            )

            # Append agent_completed event
            append_agent_completed(task_id, agent_id, agent_type, workstream_id, response)

          {:error, reason} ->
            Logger.error("Agent failed",
              agent_id: agent_id,
              error: inspect(reason)
            )

            # Append agent_failed event
            append_agent_failed(task_id, agent_id, agent_type, workstream_id, reason)
        end

        # Stop session
        ClaudeCode.stop(session)

      {:error, reason} ->
        Logger.error("Failed to start Claude Code session",
          agent_id: agent_id,
          error: inspect(reason)
        )

        # Append agent_failed event
        append_agent_failed(task_id, agent_id, agent_type, workstream_id, reason)
    end
  end

  # Append agent_completed event (defensive - ignore version conflicts)
  defp append_agent_completed(task_id, agent_id, agent_type, workstream_id, response) do
    Ipa.Pod.State.append_event(
      task_id,
      "agent_completed",
      %{
        agent_id: agent_id,
        agent_type: agent_type,
        workstream_id: workstream_id,
        response_summary: String.slice(response, 0, 500)
      },
      nil,  # Don't check version
      actor_id: "scheduler"
    )

    # If workstream agent, also mark workstream as completed
    if agent_type == :workstream && workstream_id do
      Ipa.Pod.State.append_event(
        task_id,
        "workstream_completed",
        %{
          workstream_id: workstream_id,
          agent_id: agent_id
        },
        nil,
        actor_id: "scheduler"
      )
    end
  end

  # Append agent_failed event (defensive - ignore version conflicts)
  defp append_agent_failed(task_id, agent_id, agent_type, workstream_id, reason) do
    Ipa.Pod.State.append_event(
      task_id,
      "agent_failed",
      %{
        agent_id: agent_id,
        agent_type: agent_type,
        workstream_id: workstream_id,
        error: inspect(reason)
      },
      nil,  # Don't check version
      actor_id: "scheduler"
    )

    # If workstream agent, also mark workstream as failed
    if agent_type == :workstream && workstream_id do
      Ipa.Pod.State.append_event(
        task_id,
        "workstream_failed",
        %{
          workstream_id: workstream_id,
          agent_id: agent_id,
          error: inspect(reason)
        },
        nil,
        actor_id: "scheduler"
      )
    end
  end
end
