# Component Spec: 2.3 Pod Scheduler

## Spec Version

**Version**: 2.0 (Updated 2025-11-06)
**Status**: Architecture Review Complete - Approved with Improvements Implemented
**Previous Version**: v1.0 (original draft)

## Revision Notes

This version implements all critical fixes (P0) and major recommendations (P1) from the architectural review:

**Critical Fixes (P0)**:
- ✅ Fixed race condition in agent spawn check (now uses scheduler_state)
- ✅ Fixed agent process lifecycle (using spawn/1, added restart recovery)
- ✅ Fixed agent interruption to actually kill agent process

**Major Improvements (P1)**:
- ✅ Added state evaluation helpers specification
- ✅ Implemented exponential backoff for failed evaluations
- ✅ Clarified concurrent agent limits (global across all phases)
- ✅ Added graceful version conflict handling
- ✅ Prevented multiple evaluation scheduling
- ✅ Added agent timeout enforcement
- ✅ Specified agent stream handling in detail
- ✅ Improved error handling with context and telemetry
- ✅ Documented Claude Code SDK API contract
- ✅ Added proactive disk space checks

## Component ID
`2.3 Pod Scheduler`

## Phase
Phase 3: Pod Scheduler + Agents (Weeks 3-5)

## Overview

The Pod Scheduler is the **orchestration engine** for a task pod. It implements a state machine that drives task progression through phases, spawns autonomous agents via the Claude Code SDK, monitors their execution, and requests phase transitions when appropriate.

This is the **brain** of the pod - while other components provide infrastructure (state management, workspaces, external sync), the Scheduler makes all the **decisions** about what should happen next.

## Purpose

- Implement task progression state machine
- Orchestrate agent spawning and monitoring
- Determine when to spawn agents, which agents to spawn, and with what prompts
- Request phase transitions when conditions are met
- Enforce cooldowns to prevent rapid cycling
- Handle agent interruption requests
- Coordinate with WorkspaceManager for agent execution environments
- Ensure tasks progress autonomously with human oversight at key gates

## Architecture Context

**Position in System**: Layer 2 - Pod Infrastructure

**Parent**: `Ipa.Pod.Supervisor`

**Siblings**:
- `Ipa.Pod.State` - Provides state and pub-sub notifications
- `Ipa.Pod.WorkspaceManager` - Creates agent workspaces
- `Ipa.Pod.ExternalSync` - Synchronizes with external systems
- `IpaWeb.Pod.TaskLive` - Real-time UI for task

**Dependencies**:
- Event Store (1.1) - via Pod.State for appending events
- Pod Supervisor (2.1) - parent supervisor
- Pod State Manager (2.2) - for state queries and event appending
- Pod Workspace Manager (2.4) - for workspace lifecycle
- Claude Code SDK - for agent execution

**Used By**:
- Pod LiveView (2.6) - for displaying scheduler decisions
- External Sync (2.5) - reacts to phase transitions

## Key Responsibilities

### 1. State Machine Evaluation
The Scheduler continuously evaluates the task state and determines the next action:

```elixir
# On every state update:
state_updated → evaluate_state_machine(state) → determine_action → execute_action
```

**Actions**:
- `{:spawn_agent, agent_type, prompt}` - Spawn new agent
- `{:wait, reason}` - No action, wait for external event
- `{:transition, to_phase, reason}` - Request phase transition
- `{:cooldown, duration}` - Wait before next evaluation
- `{:approve_required, item}` - Waiting for human approval

### 2. Agent Lifecycle Management

**Spawning**:
1. Check available resources (disk space, agent limits)
2. Create workspace via WorkspaceManager
3. Generate agent prompt based on phase and task context
4. Spawn agent via Claude Code SDK with workspace as `cwd`
5. Record `agent_started` event
6. Monitor agent process

**Monitoring**:
1. Process agent execution stream
2. Handle agent output in real-time
3. Detect agent completion/failure
4. Record `agent_completed` or `agent_failed` event
5. Enforce timeout limits

**Interruption**:
1. Receive interrupt request (from UI or external)
2. Kill agent process with `Process.exit/2`
3. Record `agent_interrupted` event
4. Clean up agent workspace

### 3. Phase Progression

The Scheduler follows a strict phase progression model:

```
spec_clarification → planning → development → review → completed
                                                  ↓
                                              (rework)
```

Each phase has:
- **Entry conditions**: What must be true to enter this phase
- **Agent rules**: When to spawn agents, what prompts to use
- **Exit conditions**: When to request transition to next phase
- **Approval gates**: Where human approval is required

### 4. Cooldown Management

To prevent rapid cycling and excessive agent spawning:

```elixir
# After each evaluation, enter cooldown
evaluate_state_machine(state)
→ execute_action(action)
→ enter_cooldown(duration)
→ wait...
→ evaluate_state_machine(new_state)
```

**Cooldown Durations**:
- After spawning agent: 5 seconds (wait for agent to start)
- After agent completion: 10 seconds (allow time to review output)
- After transition request: 30 seconds (wait for approval)
- After evaluation failure: exponential backoff (60s, 120s, 240s, max 5min)
- Default: 30 seconds between evaluations

### 5. Agent Concurrency Limits

**Global Agent Limit**: Maximum 3 concurrent agents across all phases

This limit applies globally to prevent resource exhaustion. If 3 agents are running:
- No new agents will be spawned regardless of phase
- Scheduler waits for at least one agent to complete
- Limit is enforced before spawning (checked against `scheduler_state.active_agent_pids`)

**Configuration**:
```elixir
config :ipa, Ipa.Pod.Scheduler,
  max_concurrent_agents: 3  # Global limit
```

**Implementation Note**: The check uses the Scheduler's internal `active_agent_pids` map, not the task state, to avoid race conditions where state hasn't updated yet but agents have been spawned.

## State Machine Rules

### Phase: spec_clarification

**Entry**: Task created

**Agent Rules**:
- If no spec description AND no active agents → spawn spec_clarification_agent
- If spec updated but not approved AND no active agents → wait for approval

**Exit Conditions**:
- Spec approved → request transition to `planning`

**Approval Gate**: Spec must be approved by human

**Agent Prompt (spec_clarification_agent)**:
```
Task: {task.title}

Current spec:
{task.spec.description || "No spec yet"}

Your role: Clarify the task specification by:
1. Understanding the high-level goal
2. Identifying key requirements
3. Defining acceptance criteria
4. Asking clarifying questions if needed

Output: Update the spec with a clear description, requirements list, and acceptance criteria.
```

### Phase: planning

**Entry**: Spec approved

**Agent Rules**:
- If no plan AND no active agents → spawn planning_agent
- If plan generated but not approved AND no active agents → wait for approval

**Exit Conditions**:
- Plan approved → request transition to `development`

**Approval Gate**: Plan must be approved by human

**Agent Prompt (planning_agent)**:
```
Task: {task.title}
Spec: {task.spec.description}
Requirements: {task.spec.requirements}

Your role: Create a detailed implementation plan by:
1. Breaking down work into logical steps
2. Estimating time for each step
3. Identifying dependencies
4. Suggesting approach and technologies

Output: Generate a plan with steps, estimates, and approach.
```

### Phase: development

**Entry**: Plan approved

**Agent Rules**:
- If no implementation started AND within agent limits → spawn development_agent
- If agent completed with failures AND within agent limits → spawn fix_agent
- If tests failing AND within agent limits → spawn test_fix_agent
- **Global Limit**: Max 3 concurrent agents total (enforced before spawning)

**Exit Conditions**:
- Implementation complete AND tests passing → request transition to `review`

**Approval Gate**: None (autonomous development)

**Agent Prompt (development_agent)**:
```
Task: {task.title}
Plan: {task.plan.steps}
Workspace: {workspace_path}

Your role: Implement the task according to the plan by:
1. Following the plan steps in order
2. Writing clean, tested code
3. Running tests after each step
4. Documenting your work

Workspace setup:
- Code repository is cloned at: {workspace_path}/work
- Output artifacts should go to: {workspace_path}/output

Execute: Implement the task, run tests, and ensure everything passes.
```

**Agent Prompt (fix_agent)**:
```
Task: {task.title}
Previous attempt: {previous_agent.result}
Failures: {previous_agent.error}

Your role: Fix the issues from the previous attempt by:
1. Analyzing the error messages
2. Identifying root causes
3. Implementing fixes
4. Verifying tests pass

Execute: Fix the issues and ensure tests pass.
```

### Phase: review

**Entry**: Implementation complete

**Agent Rules**:
- If PR not created AND no active agents → spawn pr_agent
- If PR has comments AND no active agents → spawn pr_comment_resolver_agent

**Exit Conditions**:
- PR merged → request transition to `completed`
- PR requires changes → request transition back to `development`

**Approval Gate**: PR must be reviewed and approved

**Agent Prompt (pr_agent)**:
```
Task: {task.title}
Implementation: {workspace_path}/work

Your role: Create a pull request by:
1. Reviewing all changes
2. Writing a clear PR description
3. Ensuring tests pass
4. Creating the PR via gh CLI

Execute: Create and submit the PR.
```

### Phase: completed

**Entry**: PR merged OR task manually completed

**Agent Rules**: None (terminal phase)

**Exit Conditions**: None (terminal phase)

### Phase: cancelled

**Entry**: Task cancelled by user

**Agent Rules**: Interrupt all active agents

**Exit Conditions**: None (terminal phase)

## State Machine Evaluation Helpers

These helper functions determine state machine conditions. They operate on both the task state (from Pod.State) and the scheduler's internal state.

### `no_active_agents?(scheduler_state)`

**CRITICAL**: This function checks the scheduler's internal state, NOT the task state, to avoid race conditions.

```elixir
defp no_active_agents?(scheduler_state) do
  Map.size(scheduler_state.active_agent_pids) == 0
end
```

**Why**: Checking task state can lead to double-spawning if an agent is spawned but the state hasn't updated yet.

### `max_agents_reached?(scheduler_state)`

Checks if the global agent limit has been reached.

```elixir
defp max_agents_reached?(scheduler_state) do
  max_agents = Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_concurrent_agents] || 3
  Map.size(scheduler_state.active_agent_pids) >= max_agents
end
```

### `implementation_complete?(task_state)`

Returns true if:
- At least one agent has completed in development phase
- Agent completion included artifacts (code, tests)
- No pending work items remain

```elixir
defp implementation_complete?(task_state) do
  completed_dev_agents = Enum.filter(task_state.agents, fn agent ->
    agent.agent_type == "development_agent" &&
    agent.status == :completed &&
    agent.result != nil
  end)

  length(completed_dev_agents) > 0
end
```

### `tests_passing?(task_state)`

Returns true if:
- Last agent run included test execution
- Test exit code was 0
- Test output doesn't contain failures

```elixir
defp tests_passing?(task_state) do
  recent_agents = task_state.agents
    |> Enum.filter(fn a -> a.status == :completed end)
    |> Enum.sort_by(fn a -> a.completed_at end, :desc)
    |> Enum.take(1)

  case recent_agents do
    [agent] ->
      result = agent.result || %{}
      result["tests_passed"] == true

    [] ->
      false
  end
end
```

### `tests_failing?(task_state)`

Opposite of `tests_passing?/1`.

```elixir
defp tests_failing?(task_state) do
  !tests_passing?(task_state)
end
```

### `has_failed_agents?(task_state)`

Returns true if:
- `task_state.agents` contains agents with `status: :failed`
- Failed within last 10 minutes (recent failures only)

```elixir
defp has_failed_agents?(task_state) do
  ten_minutes_ago = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_unix()

  Enum.any?(task_state.agents, fn agent ->
    agent.status == :failed &&
    agent.failed_at != nil &&
    agent.failed_at > ten_minutes_ago
  end)
end
```

### `no_work_started?(task_state)`

Returns true if no development agents have been spawned yet.

```elixir
defp no_work_started?(task_state) do
  !Enum.any?(task_state.agents, fn agent ->
    agent.agent_type in ["development_agent", "fix_agent", "test_fix_agent"]
  end)
end
```

### `pr_created?(task_state)`

Checks if a PR has been created.

```elixir
defp pr_created?(task_state) do
  task_state.external_sync.github.pr_number != nil
end
```

### `pr_merged?(task_state)`

Checks if the PR has been merged.

```elixir
defp pr_merged?(task_state) do
  task_state.external_sync.github.pr_merged? == true
end
```

### `pr_requires_changes?(task_state)`

Checks if PR review requested changes (this would come from ExternalSync events).

```elixir
defp pr_requires_changes?(task_state) do
  # Check for recent events indicating PR needs changes
  # This would typically be set by ExternalSync when it detects
  # PR review requesting changes
  task_state.external_sync.github.pr_status == "changes_requested"
end
```

### `pr_has_comments?(task_state)`

Checks if there are unresolved PR comments.

```elixir
defp pr_has_comments?(task_state) do
  # This would be tracked by ExternalSync
  task_state.external_sync.github.unresolved_comments_count > 0
end
```

## Public API

### Module: `Ipa.Pod.Scheduler`

#### `start_link/1`
```elixir
@spec start_link(opts :: keyword()) :: GenServer.on_start()
```

Starts the scheduler for a task. Called by Pod Supervisor.

**Parameters**:
- `opts` - Keyword list with `:task_id` required

**Behavior**:
1. Registers itself via Registry with key `{:pod_scheduler, task_id}`
2. Subscribes to pod-local pub-sub `"pod:#{task_id}:state"`
3. Loads initial state via `Ipa.Pod.State.get_state/1`
4. Checks for orphaned agents (from previous Scheduler crash)
5. Marks orphaned agents as failed
6. Performs initial evaluation
7. Returns `{:ok, pid}`

**Example**:
```elixir
{:ok, pid} = Ipa.Pod.Scheduler.start_link(task_id: task_id)
```

#### `interrupt_agent/2`
```elixir
@spec interrupt_agent(task_id :: String.t(), agent_id :: String.t()) ::
  :ok | {:error, reason :: term()}
```

Interrupts a running agent by killing its process.

**Parameters**:
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent to interrupt

**Returns**:
- `:ok` - Agent interrupted successfully
- `{:error, :agent_not_found}` - Agent doesn't exist
- `{:error, :agent_not_running}` - Agent is not currently running

**Implementation**:
1. Verify agent exists and is running in scheduler state
2. Kill agent process with `Process.exit(agent_pid, :kill)`
3. Clean up workspace via WorkspaceManager
4. Append `agent_interrupted` event
5. Remove from active_agent_pids tracking
6. Trigger immediate re-evaluation

**Example**:
```elixir
:ok = Ipa.Pod.Scheduler.interrupt_agent("task-123", "agent-456")
```

#### `evaluate_now/1` (for testing)
```elixir
@spec evaluate_now(task_id :: String.t()) :: :ok
```

Forces immediate state machine evaluation, bypassing cooldown.

**Use Case**: Testing, debugging, manual intervention

**Example**:
```elixir
:ok = Ipa.Pod.Scheduler.evaluate_now("task-123")
```

#### `get_scheduler_state/1` (for debugging)
```elixir
@spec get_scheduler_state(task_id :: String.t()) ::
  {:ok, scheduler_state :: map()} | {:error, :not_found}
```

Returns the internal scheduler state (for debugging/monitoring).

**Returns**:
```elixir
%{
  task_id: "task-123",
  current_phase: :development,
  last_evaluation: ~U[2025-01-05 12:00:00Z],
  cooldown_until: ~U[2025-01-05 12:00:30Z],
  active_agents: %{"agent-456" => pid},
  pending_action: {:spawn_agent, :fix_agent},
  evaluation_failure_count: 0,
  evaluation_scheduled?: false
}
```

## Internal Implementation

### GenServer State

```elixir
defmodule Ipa.Pod.Scheduler do
  use GenServer

  defstruct [
    :task_id,                      # Task UUID
    :current_phase,                # Current task phase
    :last_evaluation,              # Timestamp of last evaluation
    :cooldown_until,               # Timestamp when cooldown ends
    :active_agent_pids,            # Map of agent_id → pid (CRITICAL for race condition fix)
    :agent_start_times,            # Map of agent_id → start_time (for timeout enforcement)
    :pending_action,               # Last determined action
    :evaluation_count,             # Counter for metrics
    :evaluation_failure_count,     # Counter for exponential backoff
    :evaluation_scheduled?         # Flag to prevent multiple evaluation scheduling
  ]
end
```

**State Fields Explained**:
- `active_agent_pids`: Tracks running agents to avoid race conditions (P0-1 fix)
- `agent_start_times`: Used for timeout enforcement (P1-6)
- `evaluation_failure_count`: Used for exponential backoff (P1-2)
- `evaluation_scheduled?`: Prevents multiple `:evaluate` messages from queuing (P1-5)

### GenServer Callbacks

#### `init/1`
```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)

  # Subscribe to state changes
  Ipa.Pod.State.subscribe(task_id)

  # Load initial state
  {:ok, task_state} = Ipa.Pod.State.get_state(task_id)

  # Check for orphaned agents (from previous Scheduler crash)
  # This handles the case where Scheduler crashed and restarted,
  # losing track of running agents
  orphaned_agents = find_orphaned_agents(task_state)

  if length(orphaned_agents) > 0 do
    require Logger
    Logger.warning("Found orphaned agents on restart",
      task_id: task_id,
      count: length(orphaned_agents))

    # Mark them as failed
    for agent <- orphaned_agents do
      case Ipa.Pod.State.append_event(
        task_id,
        "agent_failed",
        %{
          agent_id: agent.agent_id,
          error: "Scheduler restarted while agent was running",
          failed_at: DateTime.utc_now() |> DateTime.to_unix()
        },
        nil,  # Don't check version on restart
        actor_id: "scheduler"
      ) do
        {:ok, _version} ->
          Logger.info("Marked orphaned agent as failed", agent_id: agent.agent_id)

        {:error, reason} ->
          Logger.error("Failed to mark orphaned agent as failed",
            agent_id: agent.agent_id,
            error: reason)
      end
    end
  end

  # Schedule initial evaluation
  send(self(), :evaluate)

  {:ok, %__MODULE__{
    task_id: task_id,
    current_phase: task_state.phase,
    last_evaluation: nil,
    cooldown_until: nil,
    active_agent_pids: %{},
    agent_start_times: %{},
    pending_action: nil,
    evaluation_count: 0,
    evaluation_failure_count: 0,
    evaluation_scheduled?: true  # Initial evaluation is scheduled
  }}
end

defp find_orphaned_agents(task_state) do
  # Find agents that have "started" but no "completed/failed/interrupted"
  Enum.filter(task_state.agents, fn agent ->
    agent.status == :running
  end)
end
```

#### `handle_info/2` - State Updated
```elixir
def handle_info({:state_updated, _task_id, new_state}, state) do
  require Logger
  Logger.debug("Scheduler received state update",
    task_id: state.task_id,
    phase: new_state.phase)

  # Schedule evaluation if not already scheduled and not in cooldown
  new_state = schedule_evaluation_if_needed(state)

  {:noreply, %{new_state | current_phase: new_state.phase}}
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
```

#### `handle_info/2` - Evaluate
```elixir
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

      # Evaluate state machine
      action = evaluate_state_machine(task_state, state)

      # Execute action
      new_state = execute_action(action, task_state, state)

      # Reset failure count on successful evaluation
      new_state = %{new_state | evaluation_failure_count: 0}

      # Emit telemetry
      duration_ms = System.monotonic_time() - start_time
        |> System.convert_time_unit(:native, :millisecond)

      :telemetry.execute(
        [:ipa, :scheduler, :evaluation, :duration],
        %{duration: duration_ms},
        %{task_id: state.task_id, phase: new_state.current_phase}
      )

      if duration_ms > 100 do
        require Logger
        Logger.warning("Slow evaluation",
          duration_ms: duration_ms,
          task_id: state.task_id)
      end

      {:noreply, new_state}

    rescue
      error ->
        # Capture error with full context
        stacktrace = __STACKTRACE__
        require Logger
        Logger.error("State machine evaluation failed",
          error: inspect(error),
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
        try do
          {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)
          Ipa.Pod.State.append_event(
            state.task_id,
            "scheduler_error",
            %{
              error: inspect(error),
              phase: task_state.phase,
              stacktrace: Exception.format_stacktrace(stacktrace)
            },
            nil,  # Don't check version on error
            actor_id: "scheduler"
          )
        rescue
          _e -> :ok  # If this fails, just continue
        end

        # Enter cooldown with exponential backoff
        failure_count = state.evaluation_failure_count + 1
        cooldown_ms = calculate_error_cooldown(failure_count)

        Logger.info("Entering error cooldown",
          failure_count: failure_count,
          cooldown_ms: cooldown_ms)

        new_state = enter_cooldown(
          %{state | evaluation_failure_count: failure_count},
          :custom,
          cooldown_ms
        )

        {:noreply, new_state}
    end
  end
end

defp calculate_error_cooldown(failure_count) do
  # Exponential backoff: 60s, 120s, 240s, max 5 minutes
  min(300_000, 60_000 * :math.pow(2, failure_count - 1))
  |> round()
end
```

#### `handle_info/2` - Agent Timeout Check
```elixir
def handle_info({:check_agent_timeout, agent_id}, state) do
  case Map.get(state.active_agent_pids, agent_id) do
    nil ->
      # Agent already completed/failed
      {:noreply, state}

    _agent_pid ->
      require Logger
      Logger.warning("Agent timeout exceeded",
        agent_id: agent_id,
        task_id: state.task_id)

      # Interrupt the agent
      case handle_call({:interrupt_agent, agent_id}, self(), state) do
        {:reply, :ok, new_state} ->
          {:noreply, new_state}

        {:reply, {:error, reason}, new_state} ->
          Logger.error("Failed to interrupt timed-out agent",
            agent_id: agent_id,
            error: reason)
          {:noreply, new_state}
      end
  end
end
```

### State Machine Evaluation

```elixir
defp evaluate_state_machine(task_state, scheduler_state) do
  case task_state.phase do
    :spec_clarification ->
      evaluate_spec_clarification(task_state, scheduler_state)

    :planning ->
      evaluate_planning(task_state, scheduler_state)

    :development ->
      evaluate_development(task_state, scheduler_state)

    :review ->
      evaluate_review(task_state, scheduler_state)

    :completed ->
      {:wait, :task_completed}

    :cancelled ->
      {:wait, :task_cancelled}
  end
end

defp evaluate_spec_clarification(task_state, scheduler_state) do
  cond do
    # Spec approved → transition to planning
    task_state.spec.approved? ->
      {:transition, :planning, "Spec approved"}

    # No spec and no active agents → spawn spec clarification agent
    is_nil(task_state.spec.description) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :spec_clarification_agent, generate_spec_prompt(task_state)}

    # Spec updated but not approved → wait for approval
    !is_nil(task_state.spec.description) && !task_state.spec.approved? ->
      {:approve_required, :spec}

    # Agent working on spec → wait
    !no_active_agents?(scheduler_state) ->
      {:wait, :agent_working}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end

defp evaluate_planning(task_state, scheduler_state) do
  cond do
    # Plan approved → transition to development
    task_state.plan && task_state.plan.approved? ->
      {:transition, :development, "Plan approved"}

    # No plan and no active agents → spawn planning agent
    is_nil(task_state.plan) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :planning_agent, generate_plan_prompt(task_state)}

    # Plan exists but not approved → wait for approval
    task_state.plan && !task_state.plan.approved? ->
      {:approve_required, :plan}

    # Agent working on plan → wait
    !no_active_agents?(scheduler_state) ->
      {:wait, :agent_working}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end

defp evaluate_development(task_state, scheduler_state) do
  cond do
    # Implementation complete and tests pass → transition to review
    implementation_complete?(task_state) && tests_passing?(task_state) ->
      {:transition, :review, "Implementation complete"}

    # Max agents reached → wait
    max_agents_reached?(scheduler_state) ->
      {:wait, :max_agents_reached}

    # Previous agent failed → spawn fix agent
    has_failed_agents?(task_state) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :fix_agent, generate_fix_prompt(task_state)}

    # Tests failing → spawn test fix agent
    tests_failing?(task_state) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :test_fix_agent, generate_test_fix_prompt(task_state)}

    # No work started → spawn development agent
    no_work_started?(task_state) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :development_agent, generate_dev_prompt(task_state)}

    # Agent working → wait
    !no_active_agents?(scheduler_state) ->
      {:wait, :agent_working}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end

defp evaluate_review(task_state, scheduler_state) do
  cond do
    # PR merged → transition to completed
    pr_merged?(task_state) ->
      {:transition, :completed, "PR merged"}

    # PR requires changes → transition back to development
    pr_requires_changes?(task_state) ->
      {:transition, :development, "PR requires changes"}

    # Max agents reached → wait
    max_agents_reached?(scheduler_state) ->
      {:wait, :max_agents_reached}

    # No PR created → spawn PR agent
    !pr_created?(task_state) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :pr_agent, generate_pr_prompt(task_state)}

    # PR has comments → spawn comment resolver agent
    pr_has_comments?(task_state) && no_active_agents?(scheduler_state) ->
      {:spawn_agent, :pr_comment_resolver_agent, generate_pr_comment_prompt(task_state)}

    # Agent working → wait
    !no_active_agents?(scheduler_state) ->
      {:wait, :agent_working}

    # Waiting for PR review → wait
    pr_created?(task_state) ->
      {:approve_required, :pr_review}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end
```

### Action Execution

```elixir
defp execute_action(action, task_state, scheduler_state) do
  case action do
    {:spawn_agent, agent_type, prompt} ->
      spawn_agent(agent_type, prompt, task_state, scheduler_state)

    {:transition, to_phase, reason} ->
      request_transition(to_phase, reason, task_state, scheduler_state)

    {:wait, reason} ->
      require Logger
      Logger.info("Scheduler waiting", task_id: task_state.task_id, reason: reason)
      enter_cooldown(scheduler_state, :wait)

    {:approve_required, item} ->
      require Logger
      Logger.info("Approval required", task_id: task_state.task_id, item: item)
      enter_cooldown(scheduler_state, :approval)

    {:cooldown, duration_ms} ->
      enter_cooldown(scheduler_state, :custom, duration_ms)
  end
end

defp spawn_agent(agent_type, prompt, task_state, scheduler_state) do
  require Logger
  agent_id = generate_agent_id()

  Logger.info("Spawning agent",
    task_id: task_state.task_id,
    agent_type: agent_type,
    agent_id: agent_id
  )

  # Check disk space proactively (P1-10)
  case check_disk_space() do
    {:error, :low_disk_space} ->
      Logger.error("Low disk space, cannot spawn agent",
        task_id: task_state.task_id)

      Ipa.Pod.State.append_event(
        task_state.task_id,
        "scheduler_blocked",
        %{reason: "low_disk_space", attempted_agent_type: to_string(agent_type)},
        nil,
        actor_id: "scheduler"
      )

      # Wait 5 minutes before retrying
      enter_cooldown(scheduler_state, :custom, 300_000)

    {:ok, _available_mb} ->
      # Proceed with agent spawn
      do_spawn_agent(agent_id, agent_type, prompt, task_state, scheduler_state)
  end
end

defp do_spawn_agent(agent_id, agent_type, prompt, task_state, scheduler_state) do
  require Logger

  # Create workspace
  case Ipa.Pod.WorkspaceManager.create_workspace(
    task_state.task_id,
    agent_id,
    %{max_size_mb: 1000, git_config: %{enabled: true}}
  ) do
    {:ok, workspace_path} ->
      # Spawn agent via Claude Code SDK
      case spawn_claude_agent(agent_id, prompt, workspace_path) do
        {:ok, agent_pid} ->
          # Record agent started event with version conflict handling (P1-4)
          case Ipa.Pod.State.append_event(
            task_state.task_id,
            "agent_started",
            %{
              agent_id: agent_id,
              agent_type: to_string(agent_type),
              workspace: workspace_path,
              started_at: DateTime.utc_now() |> DateTime.to_unix()
            },
            task_state.version,
            actor_id: "scheduler"
          ) do
            {:ok, _version} ->
              Logger.info("Agent started successfully", agent_id: agent_id)

              # Monitor agent (using spawn/1, not spawn_link/1 - P0-2 fix)
              Process.monitor(agent_pid)

              # Track start time for timeout enforcement (P1-6)
              start_time = DateTime.utc_now()

              # Schedule timeout check
              timeout_minutes = Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_agent_runtime_minutes] || 60
              timeout_ms = timeout_minutes * 60_000
              Process.send_after(self(), {:check_agent_timeout, agent_id}, timeout_ms)

              # Update scheduler state
              new_active_agents = Map.put(scheduler_state.active_agent_pids, agent_id, agent_pid)
              new_start_times = Map.put(scheduler_state.agent_start_times, agent_id, start_time)

              new_state = %{scheduler_state |
                active_agent_pids: new_active_agents,
                agent_start_times: new_start_times
              }

              # Enter cooldown
              enter_cooldown(new_state, :agent_spawn)

            {:error, :version_conflict} ->
              # Version conflict - another component updated state
              Logger.warning("Version conflict when spawning agent, will retry on next evaluation",
                agent_id: agent_id,
                task_id: task_state.task_id)

              # Kill the agent we just spawned since we couldn't record the event
              Process.exit(agent_pid, :kill)

              # Cleanup workspace
              Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, agent_id)

              # Enter short cooldown and try again
              enter_cooldown(scheduler_state, :version_conflict, 5_000)

            {:error, reason} ->
              Logger.error("Failed to record agent_started event",
                agent_id: agent_id,
                error: reason)

              # Kill the agent
              Process.exit(agent_pid, :kill)

              # Cleanup workspace
              Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, agent_id)

              enter_cooldown(scheduler_state, :spawn_failure)
          end

        {:error, reason} ->
          Logger.error("Failed to spawn agent", error: reason, agent_id: agent_id)

          # Record agent failed event
          Ipa.Pod.State.append_event(
            task_state.task_id,
            "agent_failed",
            %{
              agent_id: agent_id,
              error: "Failed to spawn: #{inspect(reason)}",
              failed_at: DateTime.utc_now() |> DateTime.to_unix()
            },
            nil,
            actor_id: "scheduler"
          )

          # Cleanup workspace
          Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, agent_id)

          # Enter cooldown
          enter_cooldown(scheduler_state, :spawn_failure)
      end

    {:error, :disk_full} ->
      Logger.error("Disk full, cannot create workspace",
        task_id: task_state.task_id,
        agent_id: agent_id)

      # Wait 5 minutes before retrying
      enter_cooldown(scheduler_state, :custom, 300_000)

    {:error, reason} ->
      Logger.error("Workspace creation failed",
        error: reason,
        agent_id: agent_id)

      enter_cooldown(scheduler_state, :spawn_failure)
  end
end

defp spawn_claude_agent(agent_id, prompt, workspace_path) do
  # Use Claude Code SDK to spawn agent (using spawn/1, not spawn_link/1)
  case ClaudeCode.run_task(
    prompt: prompt,
    cwd: workspace_path,
    allowed_tools: [:read, :write, :bash, :edit, :grep, :glob],
    stream: true
  ) do
    {:ok, stream} ->
      # Start a process to handle the stream (P0-2 fix: use spawn/1)
      scheduler_pid = self()
      agent_pid = spawn(fn ->
        handle_agent_stream(agent_id, stream, scheduler_pid)
      end)
      {:ok, agent_pid}

    {:error, reason} ->
      {:error, reason}
  end
end

defp handle_agent_stream(agent_id, stream, scheduler_pid) do
  # Process agent output stream (P1-7: detailed specification)
  require Logger

  try do
    Enum.each(stream, fn event ->
      case event do
        {:output, text} ->
          Logger.debug("Agent output", agent_id: agent_id, text: String.slice(text, 0..100))
          # Could store output for later inspection

        {:thinking, text} ->
          Logger.debug("Agent thinking", agent_id: agent_id)
          # Log agent reasoning process

        {:tool_use, tool, args} ->
          Logger.info("Agent used tool", agent_id: agent_id, tool: tool)
          # Track tool usage for metrics

        {:complete, result} ->
          Logger.info("Agent completed", agent_id: agent_id)
          send(scheduler_pid, {:agent_completed, agent_id, result})

        {:error, error} ->
          Logger.error("Agent error", agent_id: agent_id, error: error)
          send(scheduler_pid, {:agent_failed, agent_id, error})

        {:interrupted, reason} ->
          Logger.info("Agent interrupted", agent_id: agent_id, reason: reason)
          # Agent was interrupted externally (e.g., by SDK)
          send(scheduler_pid, {:agent_failed, agent_id, "Interrupted: #{inspect(reason)}"})

        unknown_event ->
          Logger.warning("Unknown agent event", agent_id: agent_id, event: unknown_event)
      end
    end)
  rescue
    error ->
      Logger.error("Agent stream processing failed",
        agent_id: agent_id,
        error: inspect(error),
        stacktrace: __STACKTRACE__)
      send(scheduler_pid, {:agent_failed, agent_id, "Stream processing error: #{inspect(error)}"})
  end
end

def handle_info({:agent_completed, agent_id, result}, state) do
  require Logger
  Logger.info("Agent completed callback", agent_id: agent_id)

  # Load current task state
  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

  # Calculate duration
  start_time = Map.get(state.agent_start_times, agent_id)
  duration_ms = if start_time do
    DateTime.diff(DateTime.utc_now(), start_time, :millisecond)
  else
    0
  end

  # Record agent completed event
  case Ipa.Pod.State.append_event(
    state.task_id,
    "agent_completed",
    %{
      agent_id: agent_id,
      result: result,
      duration_ms: duration_ms,
      completed_at: DateTime.utc_now() |> DateTime.to_unix()
    },
    task_state.version,
    actor_id: "scheduler"
  ) do
    {:ok, _version} ->
      # Cleanup workspace
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

      # Remove from tracking
      new_active_agents = Map.delete(state.active_agent_pids, agent_id)
      new_start_times = Map.delete(state.agent_start_times, agent_id)

      new_state = %{state |
        active_agent_pids: new_active_agents,
        agent_start_times: new_start_times
      }

      # Enter cooldown before next evaluation
      new_state = enter_cooldown(new_state, :agent_complete)

      {:noreply, new_state}

    {:error, :version_conflict} ->
      Logger.warning("Version conflict when recording agent completion, will retry")
      # Still cleanup and remove from tracking
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

      new_active_agents = Map.delete(state.active_agent_pids, agent_id)
      new_start_times = Map.delete(state.agent_start_times, agent_id)

      new_state = %{state |
        active_agent_pids: new_active_agents,
        agent_start_times: new_start_times
      }

      # Trigger immediate evaluation to retry
      send(self(), :evaluate)
      {:noreply, %{new_state | evaluation_scheduled?: true}}

    {:error, reason} ->
      Logger.error("Failed to record agent completion", error: reason)
      # Continue anyway
      {:noreply, state}
  end
end

def handle_info({:agent_failed, agent_id, error}, state) do
  require Logger
  Logger.error("Agent failed callback", agent_id: agent_id, error: error)

  # Load current task state
  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

  # Record agent failed event
  Ipa.Pod.State.append_event(
    state.task_id,
    "agent_failed",
    %{
      agent_id: agent_id,
      error: inspect(error),
      failed_at: DateTime.utc_now() |> DateTime.to_unix()
    },
    task_state.version,
    actor_id: "scheduler"
  )

  # Cleanup workspace
  Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

  # Remove from tracking
  new_active_agents = Map.delete(state.active_agent_pids, agent_id)
  new_start_times = Map.delete(state.agent_start_times, agent_id)

  new_state = %{state |
    active_agent_pids: new_active_agents,
    agent_start_times: new_start_times
  }

  # Trigger re-evaluation
  send(self(), :evaluate)
  {:noreply, %{new_state | evaluation_scheduled?: true}}
end

defp request_transition(to_phase, reason, task_state, scheduler_state) do
  require Logger
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
```

### Agent Interruption

```elixir
def handle_call({:interrupt_agent, agent_id}, _from, state) do
  case Map.get(state.active_agent_pids, agent_id) do
    nil ->
      {:reply, {:error, :agent_not_found}, state}

    agent_pid ->
      require Logger
      Logger.info("Interrupting agent", agent_id: agent_id)

      # Kill the agent process (P0-3 fix)
      Process.exit(agent_pid, :kill)

      # Load current task state
      {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

      # Record event
      Ipa.Pod.State.append_event(
        state.task_id,
        "agent_interrupted",
        %{
          agent_id: agent_id,
          interrupted_by: "manual",
          interrupted_at: DateTime.utc_now() |> DateTime.to_unix()
        },
        task_state.version,
        actor_id: "user"
      )

      # Cleanup workspace
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

      # Remove from tracking
      new_active_agents = Map.delete(state.active_agent_pids, agent_id)
      new_start_times = Map.delete(state.agent_start_times, agent_id)

      new_state = %{state |
        active_agent_pids: new_active_agents,
        agent_start_times: new_start_times
      }

      # Trigger immediate re-evaluation
      send(self(), :evaluate)
      new_state = %{new_state | evaluation_scheduled?: true}

      {:reply, :ok, new_state}
  end
end
```

### Agent Monitoring

```elixir
def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
  # Agent process died
  require Logger

  # Find which agent died
  case Enum.find(state.active_agent_pids, fn {_id, agent_pid} -> agent_pid == pid end) do
    {agent_id, _pid} ->
      Logger.warning("Agent process died", agent_id: agent_id, reason: inspect(reason))

      # Load current task state
      {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

      # Record agent failed event
      Ipa.Pod.State.append_event(
        state.task_id,
        "agent_failed",
        %{
          agent_id: agent_id,
          error: "Process died: #{inspect(reason)}",
          failed_at: DateTime.utc_now() |> DateTime.to_unix()
        },
        task_state.version,
        actor_id: "scheduler"
      )

      # Cleanup workspace
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

      # Remove from active agents
      new_active_agents = Map.delete(state.active_agent_pids, agent_id)
      new_start_times = Map.delete(state.agent_start_times, agent_id)

      new_state = %{state |
        active_agent_pids: new_active_agents,
        agent_start_times: new_start_times
      }

      # Trigger re-evaluation
      send(self(), :evaluate)
      {:noreply, %{new_state | evaluation_scheduled?: true}}

    nil ->
      Logger.warning("Unknown process died", pid: inspect(pid), reason: inspect(reason))
      {:noreply, state}
  end
end
```

### Cooldown Management

```elixir
defp enter_cooldown(scheduler_state, cooldown_type, custom_duration_ms \\ nil) do
  duration_ms = case cooldown_type do
    :agent_spawn -> 5_000           # 5 seconds after spawning
    :agent_complete -> 10_000       # 10 seconds after completion
    :transition_request -> 30_000   # 30 seconds after transition
    :approval -> 60_000             # 60 seconds waiting for approval
    :wait -> 30_000                 # 30 seconds default wait
    :spawn_failure -> 60_000        # 60 seconds after spawn failure
    :version_conflict -> 5_000      # 5 seconds after version conflict (quick retry)
    :custom -> custom_duration_ms
  end

  cooldown_until = DateTime.utc_now() |> DateTime.add(duration_ms, :millisecond)

  # Schedule next evaluation
  Process.send_after(self(), :evaluate, duration_ms)

  %{scheduler_state |
    cooldown_until: cooldown_until,
    last_evaluation: DateTime.utc_now(),
    evaluation_count: scheduler_state.evaluation_count + 1,
    evaluation_scheduled?: true
  }
end
```

### Resource Checks

```elixir
defp check_disk_space() do
  # Get workspace base path from config
  base_path = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager)[:base_path] || "/ipa/workspaces"

  # Check available disk space
  # This is platform-dependent; on Unix systems we can use :disksup from :os_mon
  case :disksup.get_disk_data() do
    disks when is_list(disks) ->
      # Find the disk that contains our workspace path
      case Enum.find(disks, fn {mount_point, _kbytes, capacity} ->
        String.starts_with?(base_path, to_string(mount_point))
      end) do
        {_mount, _total_kb, capacity} ->
          # capacity is percentage used (0-100)
          if capacity > 90 do
            {:error, :low_disk_space}
          else
            available_mb = :erlang.trunc((100 - capacity) * _total_kb / 1024 / 100)
            {:ok, available_mb}
          end

        nil ->
          # Couldn't find matching disk, assume OK
          {:ok, :unknown}
      end

    _ ->
      # :disksup not available or error, assume OK
      {:ok, :unknown}
  end
rescue
  _error ->
    # If anything fails, don't block agent spawning
    {:ok, :unknown}
end

defp generate_agent_id() do
  "agent-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"
end
```

### Prompt Generation

```elixir
defp generate_spec_prompt(task_state) do
  """
  Task: #{task_state.title}

  Current spec:
  #{task_state.spec.description || "No spec yet"}

  Your role: Clarify the task specification by:
  1. Understanding the high-level goal
  2. Identifying key requirements
  3. Defining acceptance criteria
  4. Asking clarifying questions if needed

  Output: Update the spec with a clear description, requirements list, and acceptance criteria.

  Use the following format:

  ## Description
  [Clear description of what needs to be done]

  ## Requirements
  - [Requirement 1]
  - [Requirement 2]
  ...

  ## Acceptance Criteria
  - [Criterion 1]
  - [Criterion 2]
  ...
  """
end

defp generate_plan_prompt(task_state) do
  """
  Task: #{task_state.title}

  Spec:
  #{task_state.spec.description}

  Requirements:
  #{Enum.map_join(task_state.spec.requirements, "\n", fn req -> "- #{req}" end)}

  Your role: Create a detailed implementation plan by:
  1. Breaking down work into logical steps
  2. Estimating time for each step
  3. Identifying dependencies
  4. Suggesting approach and technologies

  Output: Generate a plan with steps, estimates, and approach.

  Use the following format:

  ## Approach
  [High-level approach description]

  ## Steps
  1. [Step 1 description] (estimated: X hours)
  2. [Step 2 description] (estimated: X hours)
  ...

  ## Dependencies
  - [Dependency 1]
  - [Dependency 2]
  ...
  """
end

defp generate_dev_prompt(task_state) do
  """
  Task: #{task_state.title}

  Plan:
  #{format_plan(task_state.plan)}

  Workspace: Use your current working directory

  Your role: Implement the task according to the plan by:
  1. Following the plan steps in order
  2. Writing clean, tested code
  3. Running tests after each step
  4. Documenting your work

  Workspace setup:
  - Code repository is in: ./work
  - Output artifacts should go to: ./output

  Execute: Implement the task, run tests, and ensure everything passes.
  """
end

defp generate_fix_prompt(task_state) do
  # Find most recent failed agent
  failed_agent = task_state.agents
    |> Enum.filter(fn a -> a.status == :failed end)
    |> Enum.sort_by(fn a -> a.failed_at end, :desc)
    |> List.first()

  error_info = if failed_agent do
    "Error: #{failed_agent.error}"
  else
    "No specific error information available"
  end

  """
  Task: #{task_state.title}

  Previous attempt failed:
  #{error_info}

  Your role: Fix the issues from the previous attempt by:
  1. Analyzing the error messages
  2. Identifying root causes
  3. Implementing fixes
  4. Verifying tests pass

  Execute: Fix the issues and ensure tests pass.
  """
end

defp generate_test_fix_prompt(task_state) do
  """
  Task: #{task_state.title}

  Tests are currently failing.

  Your role: Fix the failing tests by:
  1. Running the test suite to see failures
  2. Analyzing the failure messages
  3. Fixing the code or tests as needed
  4. Verifying all tests pass

  Execute: Make the tests pass.
  """
end

defp generate_pr_prompt(task_state) do
  """
  Task: #{task_state.title}

  Implementation is complete in the workspace.

  Your role: Create a pull request by:
  1. Reviewing all changes (git diff, git status)
  2. Writing a clear PR description
  3. Ensuring tests pass
  4. Creating the PR via gh CLI

  Execute: Create and submit the PR.
  """
end

defp generate_pr_comment_prompt(task_state) do
  """
  Task: #{task_state.title}

  PR ##{task_state.external_sync.github.pr_number} has comments that need to be addressed.

  Your role: Address the PR comments by:
  1. Reading the PR comments (gh pr view #{task_state.external_sync.github.pr_number} --comments)
  2. Making the requested changes
  3. Running tests to verify changes
  4. Pushing the updates

  Execute: Address all PR comments.
  """
end

defp format_plan(plan) when is_nil(plan), do: "No plan yet"
defp format_plan(plan) do
  """
  ## Approach
  #{plan.approach || "No approach specified"}

  ## Steps
  #{Enum.map_join(plan.steps, "\n", fn step ->
    "- #{step.description} (#{step.estimated_hours}h)"
  end)}
  """
end
```

## Configuration

```elixir
# config/config.exs
config :ipa, Ipa.Pod.Scheduler,
  # Cooldown durations (milliseconds)
  cooldown_after_spawn: 5_000,
  cooldown_after_complete: 10_000,
  cooldown_after_transition: 30_000,
  cooldown_default: 30_000,

  # Agent limits
  max_concurrent_agents: 3,              # Global limit across all phases
  max_agent_runtime_minutes: 60,

  # Evaluation settings
  enable_auto_transitions: true,         # Allow automatic phase transitions
  require_approval_for_transitions: true # Require human approval for transitions
```

## Events

The Scheduler appends these events via Pod.State:

### Event: `agent_started`
```elixir
%{
  event_type: "agent_started",
  event_data: %{
    agent_id: "agent-456",
    agent_type: "development_agent",
    workspace: "/ipa/workspaces/task-123/agent-456",
    started_at: 1704456000
  },
  actor_id: "scheduler"
}
```

### Event: `agent_completed`
```elixir
%{
  event_type: "agent_completed",
  event_data: %{
    agent_id: "agent-456",
    result: %{...},
    duration_ms: 120000,
    completed_at: 1704456120
  },
  actor_id: "scheduler"
}
```

### Event: `agent_failed`
```elixir
%{
  event_type: "agent_failed",
  event_data: %{
    agent_id: "agent-456",
    error: "Tests failed",
    failed_at: 1704456060
  },
  actor_id: "scheduler"
}
```

### Event: `agent_interrupted`
```elixir
%{
  event_type: "agent_interrupted",
  event_data: %{
    agent_id: "agent-456",
    interrupted_by: "user-123",
    interrupted_at: 1704456030
  },
  actor_id: "user-123"
}
```

### Event: `transition_requested`
```elixir
%{
  event_type: "transition_requested",
  event_data: %{
    from_phase: :planning,
    to_phase: :development,
    reason: "Plan approved"
  },
  actor_id: "scheduler"
}
```

### Event: `scheduler_error`
```elixir
%{
  event_type: "scheduler_error",
  event_data: %{
    error: "RuntimeError: ...",
    phase: :development,
    stacktrace: "..."
  },
  actor_id: "scheduler"
}
```

### Event: `scheduler_blocked`
```elixir
%{
  event_type: "scheduler_blocked",
  event_data: %{
    reason: "low_disk_space",
    attempted_agent_type: "development_agent"
  },
  actor_id: "scheduler"
}
```

## Integration Points

### With Pod.State
The Scheduler is a **reactive** component - it subscribes to state changes:

```elixir
# On init
Ipa.Pod.State.subscribe(task_id)

# Receives messages
{:state_updated, task_id, new_state}
→ schedule_evaluation()
→ evaluate_state_machine(new_state)
→ execute_action(action)
```

### With Pod.WorkspaceManager
The Scheduler creates and cleans up workspaces:

```elixir
# Before spawning agent
{:ok, workspace_path} = Ipa.Pod.WorkspaceManager.create_workspace(task_id, agent_id, config)

# After agent completes
:ok = Ipa.Pod.WorkspaceManager.cleanup_workspace(task_id, agent_id)
```

### With Claude Code SDK
The Scheduler spawns agents:

```elixir
{:ok, stream} = ClaudeCode.run_task(
  prompt: agent_prompt,
  cwd: workspace_path,
  allowed_tools: [:read, :write, :bash, :edit],
  stream: true
)
```

### With Pod.ExternalSync
The Scheduler's phase transitions trigger external sync:

```elixir
# Scheduler appends transition_approved event
→ Pod.State broadcasts state update
→ ExternalSync receives update
→ ExternalSync syncs to GitHub/JIRA
```

## Error Handling

### Agent Spawn Failures
```elixir
case spawn_claude_agent(...) do
  {:ok, pid} -> # Success
  {:error, :sdk_unavailable} ->
    Logger.error("Claude Code SDK unavailable")
    enter_cooldown(state, :spawn_failure)
  {:error, reason} ->
    Logger.error("Agent spawn failed: #{inspect(reason)}")
    enter_cooldown(state, :spawn_failure)
end
```

### State Evaluation Errors
Handled with try/rescue and exponential backoff:
```elixir
try do
  action = evaluate_state_machine(task_state, scheduler_state)
  execute_action(action, task_state, scheduler_state)
rescue
  error ->
    stacktrace = __STACKTRACE__
    Logger.error("Evaluation failed", error: inspect(error), stacktrace: stacktrace)
    failure_count = state.evaluation_failure_count + 1
    cooldown_ms = calculate_error_cooldown(failure_count)
    enter_cooldown(%{state | evaluation_failure_count: failure_count}, :custom, cooldown_ms)
end
```

### Workspace Creation Failures
```elixir
case Ipa.Pod.WorkspaceManager.create_workspace(...) do
  {:ok, path} -> # Success
  {:error, :disk_full} ->
    Logger.error("Disk full, cannot create workspace")
    enter_cooldown(scheduler_state, :custom, 300_000)
  {:error, reason} ->
    Logger.error("Workspace creation failed: #{inspect(reason)}")
    enter_cooldown(scheduler_state, :spawn_failure)
end
```

### Version Conflicts
Handled gracefully with retries:
```elixir
case Ipa.Pod.State.append_event(..., expected_version) do
  {:ok, new_version} -> # Success
  {:error, :version_conflict} ->
    Logger.warning("Version conflict, will retry on next evaluation")
    enter_cooldown(scheduler_state, :version_conflict, 5_000)
  {:error, reason} ->
    Logger.error("Failed to append event: #{inspect(reason)}")
end
```

## Testing Strategy

### Unit Tests
1. **State Machine Logic**
   - Each phase evaluation returns correct action
   - Edge cases (no spec, no plan, no agents, etc.)
   - Multiple agents scenario
   - Failed agent scenario
   - Max agents limit enforcement

2. **Action Execution**
   - Spawn agent creates workspace and records event
   - Transition request appends event
   - Wait/cooldown behavior
   - Version conflict handling

3. **Cooldown Management**
   - Cooldown prevents rapid re-evaluation
   - Different cooldown durations for different actions
   - Evaluation scheduling flag prevents queueing

4. **Prompt Generation**
   - Each agent type gets correct prompt
   - Prompts include task context

5. **State Evaluation Helpers**
   - Each helper function returns correct boolean
   - Helpers use correct state source (task_state vs scheduler_state)

### Integration Tests
1. **Full Task Flow**
   - Task created → spec_clarification → planning → development → review → completed
   - Agent spawning at each phase
   - Transition requests at phase boundaries

2. **Agent Lifecycle**
   - Agent spawned → workspace created → agent runs → agent completes → workspace cleaned up
   - Agent failure handling
   - Agent timeout enforcement

3. **Concurrent Agents**
   - Multiple agents in development phase
   - Agent limit enforcement (global limit)

4. **Interruption**
   - User interrupts agent → agent killed → workspace cleaned up → state updated

5. **Error Recovery**
   - Scheduler crash → restart → orphaned agents marked as failed
   - Evaluation error → exponential backoff
   - Version conflict → retry

### Mocking Strategy
- **Claude Code SDK**: Mock with test adapter that simulates agent behavior
- **Pod.State**: Use real Pod.State with in-memory event store
- **WorkspaceManager**: Use real WorkspaceManager with test filesystem
- **System.cmd**: Mock for disk space checks

## Performance Considerations

1. **Evaluation Frequency**: Cooldowns prevent excessive evaluation cycles
2. **Agent Spawn Time**: ~5-10 seconds (workspace creation + SDK initialization)
3. **Memory Usage**: Minimal (stores only scheduler state, not agent state)
4. **CPU Usage**: Low when idle, moderate during evaluation
5. **Telemetry**: Emit events for evaluation duration, errors, agent lifecycle

## Security Considerations

1. **Agent Isolation**: Agents run in isolated workspaces
2. **Prompt Injection**: Validate and sanitize task inputs before generating prompts
3. **Resource Limits**: Enforce max agent runtime, max concurrent agents, disk space checks
4. **Privilege Separation**: Agents run with limited permissions

## Acceptance Criteria

- [ ] Scheduler subscribes to pod-local pub-sub
- [ ] State machine evaluates correctly for all phases
- [ ] Agents are spawned with correct prompts and workspaces
- [ ] Agent completion/failure is detected and recorded
- [ ] Phase transitions are requested when conditions are met
- [ ] Cooldowns prevent rapid cycling
- [ ] Agent interruption works correctly (kills process)
- [ ] All P0 fixes implemented (race condition, process lifecycle, interruption)
- [ ] All P1 improvements implemented (helpers, backoff, limits, etc.)
- [ ] All unit tests pass
- [ ] Integration tests cover full task flow
- [ ] Performance meets targets (< 100ms evaluation, < 10s agent spawn)

## Appendix A: Claude Code SDK API Contract

This appendix documents the expected API contract for the Claude Code SDK integration.

### SDK Function Signature

```elixir
@spec ClaudeCode.run_task(opts :: keyword()) ::
  {:ok, stream :: Enumerable.t()} | {:error, reason :: term()}
```

**Options**:
- `:prompt` - String, required - The task prompt for the agent
- `:cwd` - String, required - Working directory path (workspace)
- `:allowed_tools` - List of atoms, default `[:read, :write, :bash]` - Tools the agent can use
- `:stream` - Boolean, default `false` - Whether to stream events

**Return Values**:
- `{:ok, stream}` - Stream of agent events (if `:stream` is true)
- `{:ok, result}` - Final result map (if `:stream` is false)
- `{:error, :sdk_unavailable}` - SDK not initialized or unavailable
- `{:error, :invalid_workspace}` - Workspace path is invalid
- `{:error, {:sdk_error, message}}` - SDK-specific error
- `{:error, reason}` - Other errors

### Stream Event Format

When `:stream` is true, the returned stream emits events in this format:

```elixir
{:output, text :: String.t()}          # Agent output text
{:thinking, text :: String.t()}        # Agent thinking process (internal reasoning)
{:tool_use, tool :: atom(), args}      # Agent used a tool (e.g., {:tool_use, :read, %{file: "foo.txt"}})
{:complete, result :: map()}           # Agent completed successfully
{:error, error :: term()}              # Agent encountered an error
{:interrupted, reason :: term()}       # Agent was interrupted externally
```

### Result Format

The `result` map in the `:complete` event contains:

```elixir
%{
  "status" => "success",                # "success" | "error"
  "output" => "...",                    # Agent's final output
  "tests_passed" => true,               # Boolean if tests were run
  "artifacts" => [                      # List of created artifacts
    %{"path" => "output/report.txt", "type" => "file"}
  ]
}
```

### Integration Pattern

```elixir
# Spawn agent with streaming
{:ok, stream} = ClaudeCode.run_task(
  prompt: prompt,
  cwd: workspace_path,
  allowed_tools: [:read, :write, :bash, :edit, :grep, :glob],
  stream: true
)

# Process stream in separate process
spawn(fn ->
  stream
  |> Enum.each(fn event ->
    case event do
      {:output, text} -> handle_output(text)
      {:thinking, text} -> handle_thinking(text)
      {:tool_use, tool, args} -> handle_tool_use(tool, args)
      {:complete, result} -> handle_complete(result)
      {:error, error} -> handle_error(error)
      {:interrupted, reason} -> handle_interrupted(reason)
    end
  end)
end)
```

### Error Handling

If the SDK process crashes or becomes unavailable during streaming, the stream will emit:
```elixir
{:error, :sdk_crashed}
```

The Scheduler should treat this as an agent failure.

### Cancellation

To cancel a running agent, kill the stream processing process:
```elixir
Process.exit(stream_handler_pid, :kill)
```

The SDK will detect this and clean up the agent.

### Timeout Behavior

The SDK does NOT enforce timeouts internally. The Scheduler is responsible for:
1. Tracking agent start time
2. Scheduling timeout check
3. Killing the agent process if timeout is exceeded

## Future Enhancements

### Phase 1 (Current Scope)
- Basic state machine
- Single agent per phase (except development)
- Manual transition approvals

### Phase 2 (Advanced)
- Parallel agents in development phase (already supported by global limit)
- Automatic transition approvals (configurable)
- Agent chaining (output of agent A → input of agent B)
- Dynamic prompt generation based on context

### Phase 3 (AI-Powered)
- LLM-based action selection
- Learning from past task executions
- Adaptive cooldown durations
- Predictive agent spawning

## Notes

- The Scheduler is **reactive**, not proactive - it responds to state changes
- All decisions are **deterministic** - same state → same action
- The Scheduler is **stateless** regarding task data - all task state is in Pod.State
- Prompts should be **detailed** and **unambiguous** to guide agents effectively
- Cooldowns are **critical** to prevent rapid agent spawning and resource exhaustion
- The global agent limit applies across ALL phases to prevent resource exhaustion
- State evaluation helpers use the appropriate state source to avoid race conditions
- Agent process lifecycle uses `spawn/1` (not `spawn_link/1`) for fault tolerance
- All errors are handled with proper context, telemetry, and exponential backoff
