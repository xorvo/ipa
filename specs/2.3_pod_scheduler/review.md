# Pod Scheduler - Architectural Review

## Review Metadata

**Component**: 2.3 Pod Scheduler
**Reviewer**: Claude (System Architecture Expert)
**Review Date**: 2025-11-06
**Review Type**: Pre-Implementation Architectural Review
**Spec Version**: Initial Draft

---

## Executive Summary

**Overall Score**: 8.5/10 - **APPROVED with Recommended Improvements**

The Pod Scheduler specification demonstrates a well-thought-out state machine design with clear separation of concerns. The component correctly positions itself as the orchestration "brain" of the pod, making autonomous decisions while respecting architectural boundaries. The reactive design pattern, cooldown mechanism, and phase progression logic are sound.

However, there are several architectural considerations that should be addressed before implementation, primarily around agent lifecycle management, error recovery, and concurrency control. These are not blocking issues but represent opportunities to strengthen the design.

**Recommendation**: Proceed to implementation with the improvements outlined in the P0 and P1 sections below.

---

## 1. Architectural Soundness

### 1.1 System Architecture Alignment ✅ STRONG

**Strengths**:
- **Correct Layer Positioning**: Properly sits in Layer 2 (Pod Infrastructure) and correctly depends on Layer 1 (Event Store) while being supervised by Pod Supervisor
- **Clear Separation of Concerns**: The spec explicitly states "The Scheduler is stateless regarding task data - all task state is in Pod.State", which is excellent architectural discipline
- **Reactive Design**: The subscription-based model (`pod:{task_id}:state` pub-sub) is the right pattern for this component
- **Event-Sourced Integration**: All state changes flow through events, maintaining consistency with the overall architecture

**Observations**:
- The Scheduler correctly delegates workspace management to WorkspaceManager and state persistence to Pod.State
- No architectural layer violations detected
- Component boundaries are well-respected

### 1.2 Dependency Analysis ✅ GOOD

**Declared Dependencies**:
- Event Store (1.1) - via Pod.State ✅
- Pod Supervisor (2.1) - parent supervisor ✅
- Pod State Manager (2.2) - state queries and events ✅
- Pod Workspace Manager (2.4) - workspace lifecycle ✅
- Claude Code SDK - agent execution ✅

**Concerns**:
1. **Implicit Dependency on Pod.State Registration**: The spec mentions using `{:pod_scheduler, task_id}` for Registry but doesn't specify who looks up this registration. This is fine for internal pod use but should be documented.

2. **Agent Process Management**: The spec uses `spawn_link/1` for agent stream handlers (line 688) which creates a dependency on the Scheduler process lifecycle. This is acceptable but has implications for fault tolerance (see section 3).

### 1.3 Integration Points ✅ GOOD

**Well-Defined Integrations**:
- **Pod.State**: Subscribe/broadcast pattern is clean
- **WorkspaceManager**: Clear create/cleanup lifecycle
- **Claude Code SDK**: Appropriate abstraction via `ClaudeCode.run_task/1`
- **ExternalSync**: Indirect via events (good decoupling)

---

## 2. State Machine Design

### 2.1 Phase Transitions ✅ EXCELLENT

**Strengths**:
- Clear phase progression: `spec_clarification → planning → development → review → completed`
- Terminal phases (`completed`, `cancelled`) properly identified
- Rework loop (`review → development`) correctly handled
- Each phase has explicit entry/exit conditions

**Observation**:
The state machine is deterministic ("same state → same action") which is critical for testability and debuggability.

### 2.2 Evaluation Logic ⚠️ NEEDS IMPROVEMENT

**Issue P1-1: Missing Evaluation Logic for State Machine Conditions**

The spec provides high-level conditions like:
- `implementation_complete?(state)` (line 522)
- `tests_passing?(state)` (line 522)
- `has_failed_agents?(state)` (line 526)
- `pr_merged?(state)` (line 554)

But these helper functions are not defined or specified. This is critical because:
1. Different interpretations of "implementation complete" could lead to incorrect phase transitions
2. "tests passing" requires defining what tests to check and how to determine success
3. PR state requires external API integration

**Recommendation**: Add a section "State Evaluation Helpers" that specifies:
- How to determine if implementation is complete (check for specific files? Run a check script?)
- How to verify tests are passing (parse test output? Check exit codes?)
- How to detect PR status (GitHub API? Parse git status?)

**Issue P1-2: No Backoff Strategy for Failed Evaluations**

If `evaluate_state_machine/1` throws an exception (line 1073-1080), it enters a cooldown but doesn't implement exponential backoff. Repeated failures could lead to constant error logging without resolution.

**Recommendation**: Implement exponential backoff:
```elixir
defstruct [
  # ... existing fields
  :evaluation_failure_count,
  :last_failure_type
]

defp calculate_error_cooldown(failure_count) do
  min(300_000, 60_000 * :math.pow(2, failure_count)) # Max 5 minutes
end
```

### 2.3 Agent Spawning Rules ⚠️ NEEDS CLARIFICATION

**Issue P1-3: Concurrent Agent Limits Not Enforced in Spec**

The spec mentions "Limit: Max 3 concurrent agents" (line 189) and has a `max_agents_reached?/1` check (line 542), but:
1. This limit is only mentioned for the `development` phase
2. Other phases don't specify agent limits
3. The configuration shows `max_concurrent_agents: 3` (line 928) but it's unclear if this applies globally or per-phase

**Recommendation**: Clarify:
- Is the 3-agent limit global across all phases or only for development?
- What happens if multiple agents are spawned in different phases simultaneously?
- Should there be per-phase limits?

**Issue P0-1: Race Condition in Agent Spawn Check**

The evaluation logic checks `no_active_agents?(state)` before spawning (lines 478, 502, 534, 562), but this is based on `task_state` from Pod.State, not `scheduler_state.active_agent_pids`. This could lead to:

```
Time 0: Scheduler reads state (no active agents)
Time 1: Scheduler spawns agent A, records event
Time 2: State update arrives (agent A now active)
Time 3: Another evaluation before scheduler_state updates
Time 4: Scheduler spawns agent B (double spawn!)
```

**Recommendation**: Check `scheduler_state.active_agent_pids` instead of reconstructing from task state:
```elixir
defp no_active_agents?(scheduler_state) do
  Map.size(scheduler_state.active_agent_pids) == 0
end
```

---

## 3. Concurrency & OTP Patterns

### 3.1 GenServer Design ✅ GOOD

**Strengths**:
- Proper use of `init/1`, `handle_info/2` callbacks
- Registry registration is correct
- Supervision tree integration is appropriate

**Observation**:
The GenServer state is minimal and contains only scheduling metadata, not task data. This is excellent design.

### 3.2 Process Monitoring ⚠️ NEEDS IMPROVEMENT

**Issue P0-2: Agent Process Lifecycle is Fragile**

The spec uses `spawn_link/1` (line 688) to create agent stream handlers:
```elixir
agent_pid = spawn_link(fn -> handle_agent_stream(agent_id, stream) end)
```

**Problems**:
1. If an agent stream handler crashes, it takes down the Scheduler (because of `spawn_link`)
2. The Scheduler monitors the agent pid with `Process.monitor(agent_pid)` (line 645), but this monitors the stream handler process, not the actual Claude Code SDK process
3. If the Scheduler crashes and restarts, all active agent pids are lost

**Recommendation P0-2a**: Use `spawn/1` instead of `spawn_link/1`:
```elixir
agent_pid = spawn(fn -> handle_agent_stream(agent_id, stream, self()) end)
Process.monitor(agent_pid)
```

**Recommendation P0-2b**: Store agent pids in Pod.State events:
```elixir
# In agent_started event
event_data: %{
  agent_id: agent_id,
  agent_pid: inspect(agent_pid), # For debugging only
  # ... rest
}
```

**Recommendation P0-2c**: Add restart recovery logic:
```elixir
def init(opts) do
  # ... existing init

  # Check for orphaned agents on restart
  {:ok, task_state} = Ipa.Pod.State.get_state(task_id)
  orphaned_agents = find_orphaned_agents(task_state)

  if length(orphaned_agents) > 0 do
    Logger.warning("Found orphaned agents on restart",
      task_id: task_id,
      count: length(orphaned_agents))

    # Mark them as failed
    for agent <- orphaned_agents do
      Ipa.Pod.State.append_event(
        task_id,
        "agent_failed",
        %{agent_id: agent.agent_id, error: "Scheduler restarted"},
        task_state.version,
        actor_id: "scheduler"
      )
    end
  end

  # ... continue init
end

defp find_orphaned_agents(task_state) do
  # Find agents that have "started" but no "completed/failed/interrupted"
  # This is task-specific logic that needs to be implemented
end
```

### 3.3 Concurrency Control ⚠️ NEEDS IMPROVEMENT

**Issue P1-4: Version Conflicts Not Handled**

When appending events, the spec checks `expected_version` (line 640-642):
```elixir
{:ok, _version} = Ipa.Pod.State.append_event(
  task_state.task_id,
  "agent_started",
  %{...},
  task_state.version,  # This could be stale!
  actor_id: "scheduler"
)
```

But if there's a version conflict, the pattern match `{:ok, _version} =` will crash. This could happen if:
1. Multiple evaluations run in quick succession
2. External components (UI, ExternalSync) append events between evaluation and action execution

**Recommendation**: Handle version conflicts gracefully:
```elixir
case Ipa.Pod.State.append_event(...) do
  {:ok, new_version} ->
    # Success, continue

  {:error, :version_conflict} ->
    Logger.warning("Version conflict when spawning agent, retrying")
    # Reload state and re-evaluate
    {:ok, fresh_state} = Ipa.Pod.State.get_state(task_state.task_id)
    # Decision: retry or enter cooldown?
    enter_cooldown(scheduler_state, :version_conflict)
end
```

**Issue P1-5: Multiple Evaluations Can Queue Up**

The cooldown mechanism uses `Process.send_after(self(), :evaluate, duration_ms)` (line 758), but multiple `:evaluate` messages can queue up if:
1. State updates arrive during cooldown
2. Each update calls `schedule_evaluation/1` (line 418)
3. Multiple `:evaluate` messages are sent

**Recommendation**: Track evaluation scheduling:
```elixir
defstruct [
  # ... existing fields
  :evaluation_scheduled? # Add this flag
]

defp schedule_evaluation(scheduler_state) do
  if is_nil(scheduler_state.cooldown_until) && !scheduler_state.evaluation_scheduled? do
    Process.send_after(self(), :evaluate, 1_000)
    %{scheduler_state | evaluation_scheduled?: true}
  else
    scheduler_state
  end
end

def handle_info(:evaluate, state) do
  # ... evaluation logic
  {:noreply, %{state | evaluation_scheduled?: false}}
end
```

---

## 4. Agent Orchestration

### 4.1 Agent Lifecycle Management ⚠️ NEEDS IMPROVEMENT

**Issue P0-3: Agent Interruption Doesn't Kill the Actual Agent**

The `interrupt_agent/2` function (lines 301-327) says:
```
2. Kill agent process
```

But the implementation section doesn't show how to actually kill the agent. The spec shows:
- Recording `agent_interrupted` event (line 792-800)
- Cleaning up workspace (line 803)
- Removing from `active_agent_pids` (line 806)

But there's no call to `Process.exit(agent_pid, :kill)` or similar.

**Recommendation**: Add explicit agent termination:
```elixir
def handle_call({:interrupt_agent, agent_id}, _from, state) do
  case Map.get(state.active_agent_pids, agent_id) do
    nil ->
      {:reply, {:error, :agent_not_found}, state}

    agent_pid ->
      # Kill the agent process
      Process.exit(agent_pid, :kill)

      # Record event
      {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)
      Ipa.Pod.State.append_event(...)

      # Cleanup workspace
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, agent_id)

      # Remove from tracking
      new_active_agents = Map.delete(state.active_agent_pids, agent_id)

      {:reply, :ok, %{state | active_agent_pids: new_active_agents}}
  end
end
```

**Issue P1-6: No Timeout for Agent Execution**

The configuration specifies `max_agent_runtime_minutes: 60` (line 929), but there's no implementation showing how this timeout is enforced.

**Recommendation**: Add timeout tracking:
```elixir
defstruct [
  # ... existing fields
  :agent_start_times # Map of agent_id → start_time
]

defp spawn_agent(...) do
  # ... existing spawn logic

  # Schedule timeout check
  timeout_ms = Application.get_env(:ipa, :scheduler)[:max_agent_runtime_minutes] * 60_000
  Process.send_after(self(), {:check_agent_timeout, agent_id}, timeout_ms)

  # Track start time
  start_times = Map.put(scheduler_state.agent_start_times, agent_id, DateTime.utc_now())
  new_state = %{scheduler_state | agent_start_times: start_times}
  # ...
end

def handle_info({:check_agent_timeout, agent_id}, state) do
  case Map.get(state.active_agent_pids, agent_id) do
    nil ->
      # Agent already completed
      {:noreply, state}

    agent_pid ->
      Logger.warning("Agent timeout", agent_id: agent_id)
      # Interrupt the agent
      handle_call({:interrupt_agent, agent_id}, self(), state)
  end
end
```

### 4.2 Prompt Generation ✅ GOOD

**Strengths**:
- Prompts are detailed and include task context
- Each agent type has a specific prompt template
- Prompts specify expected output format

**Observation**:
The prompt generation functions (lines 823-913) are well-structured. Consider extracting them to a separate module `Ipa.Pod.Scheduler.Prompts` for better organization and testability.

### 4.3 Agent Output Handling ⚠️ INCOMPLETE

**Issue P1-7: Agent Stream Handling is Underspecified**

The `handle_agent_stream/2` function (lines 696-712) says:
```elixir
# (implementation details depend on Claude Code SDK API)
```

This is a critical integration point that needs specification. Questions:
- How does the SDK stream events? (async messages? Elixir Stream?)
- What event types are emitted? (`:output`, `:complete`, `:error` are shown but are these real?)
- How are partial outputs handled?
- What about agent asks for user input?

**Recommendation**: Add a section "Claude Code SDK Integration" with:
1. Expected stream event types
2. How to accumulate agent output
3. Error handling for SDK failures
4. How to handle interactive agent scenarios

---

## 5. Cooldown Strategy

### 5.1 Cooldown Duration Design ✅ EXCELLENT

**Strengths**:
- Well-calibrated durations for different scenarios
- Prevents rapid cycling effectively
- Configurable via application config

**Cooldown Schedule Analysis**:
- Agent spawn: 5s - reasonable for startup
- Agent complete: 10s - allows review time
- Transition request: 30s - appropriate for approval wait
- Approval: 60s - good balance
- Spawn failure: 60s - prevents retry storms
- Default wait: 30s - conservative but safe

### 5.2 Cooldown Implementation ⚠️ NEEDS MINOR IMPROVEMENT

**Issue P2-1: Cooldown Schedule Drift**

When multiple state updates arrive during cooldown (line 418-421), the spec calls `schedule_evaluation/1` which only schedules if `cooldown_until` is nil. However, this means:
- State update arrives at T+0 → evaluation scheduled for T+1000
- Another update at T+500 → no new evaluation scheduled
- Evaluation at T+1000 may use stale state from T+0

**Recommendation**: Consider tracking "state_version" to ensure evaluations use the latest state:
```elixir
def handle_info({:state_updated, _task_id, new_state}, state) do
  # Track that state has changed
  {:noreply, %{state |
    current_phase: new_state.phase,
    pending_state_version: new_state.version  # Track latest version
  }}
end

def handle_info(:evaluate, state) do
  # Always fetch fresh state at evaluation time
  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)
  # ...
end
```

---

## 6. Error Handling

### 6.1 Agent Spawn Failures ✅ GOOD

**Strengths**:
- Proper error handling for SDK unavailable (line 1062)
- Failed spawn records event and cleans up workspace (lines 654-674)
- Enters cooldown to prevent retry storms

### 6.2 State Evaluation Errors ⚠️ NEEDS IMPROVEMENT

**Issue P1-8: Generic Error Handling Loses Context**

The error handler (lines 1073-1080) catches all errors generically:
```elixir
rescue
  error ->
    Logger.error("State machine evaluation failed", error: error)
    enter_cooldown(scheduler_state, :error)
end
```

**Problems**:
1. Doesn't capture stacktrace (use `rescue error in [RuntimeError]` and `__STACKTRACE__`)
2. Doesn't differentiate between transient errors (network timeout) and permanent errors (bug in code)
3. No telemetry/monitoring hook

**Recommendation**:
```elixir
try do
  action = evaluate_state_machine(task_state)
  execute_action(action, task_state, scheduler_state)
rescue
  error ->
    stacktrace = __STACKTRACE__
    Logger.error("State machine evaluation failed",
      error: error,
      stacktrace: stacktrace,
      task_id: task_state.task_id,
      phase: task_state.phase
    )

    # Emit telemetry event
    :telemetry.execute(
      [:ipa, :scheduler, :evaluation, :error],
      %{count: 1},
      %{error: error, task_id: task_state.task_id}
    )

    # Record error event for debugging
    Ipa.Pod.State.append_event(
      task_state.task_id,
      "scheduler_error",
      %{error: inspect(error), phase: task_state.phase},
      task_state.version,
      actor_id: "scheduler"
    )

    # Enter cooldown with backoff
    failure_count = scheduler_state.evaluation_failure_count + 1
    cooldown_ms = calculate_error_cooldown(failure_count)
    enter_cooldown(%{scheduler_state | evaluation_failure_count: failure_count}, :custom, cooldown_ms)
end
```

### 6.3 Workspace Creation Failures ✅ GOOD

**Strengths**:
- Handles disk full scenario (line 1087)
- Appropriate cooldown (5 minutes for disk full)
- Error logging is clear

---

## 7. Integration Points

### 7.1 Pod.State Integration ✅ EXCELLENT

**Strengths**:
- Clean subscription model
- Event-first design (all actions append events)
- No direct state manipulation

**Best Practice Observed**:
The Scheduler never modifies Pod.State directly - it only appends events and subscribes to updates. This is textbook event sourcing.

### 7.2 WorkspaceManager Integration ✅ GOOD

**Strengths**:
- Clear lifecycle: create before spawn, cleanup after complete
- Error handling for creation failures

**Minor Observation**:
The spec doesn't show what happens if `cleanup_workspace/2` fails. This is likely OK (cleanup is best-effort), but should be documented.

### 7.3 Claude Code SDK Integration ⚠️ NEEDS SPECIFICATION

**Issue P1-9: SDK API Contract Not Documented**

The spec uses `ClaudeCode.run_task/1` (lines 680-684) but doesn't document:
1. What does the return value look like? (shown as `{:ok, stream}` but what is `stream`?)
2. Is `stream` an Elixir `Stream.t()`? A pid? A port?
3. How do you stop a running agent?
4. What errors can be returned?
5. What happens if the SDK process crashes?

**Recommendation**: Add an "Appendix: Claude Code SDK API Contract" section that specifies:
```elixir
# Expected SDK API
@spec ClaudeCode.run_task(opts :: keyword()) ::
  {:ok, stream :: Stream.t()} | {:error, reason :: term()}

# Stream elements
{:output, text :: String.t()}          # Agent produced output
{:tool_use, tool :: atom(), args}      # Agent used a tool
{:complete, result :: map()}           # Agent completed successfully
{:error, error :: term()}              # Agent encountered error
{:interrupted, reason :: term()}       # Agent was interrupted
```

### 7.4 ExternalSync Integration ✅ EXCELLENT

**Strengths**:
- Completely decoupled (no direct calls)
- Communication via events only
- Scheduler doesn't know ExternalSync exists

This is beautiful loose coupling.

---

## 8. Scalability & Performance

### 8.1 Scalability Analysis ✅ GOOD

**Strengths**:
- One Scheduler per pod (good isolation)
- Minimal memory footprint (only scheduler state, not task data)
- Evaluations are fast (no heavy computation)

**Observation**:
The spec claims "< 100ms evaluation" (line 1166). This should be verified during implementation, as the evaluation involves:
1. Multiple condition checks
2. Potential external API calls (for PR status, etc.)
3. State queries

**Recommendation**: Add telemetry for evaluation duration:
```elixir
def handle_info(:evaluate, state) do
  start_time = System.monotonic_time()

  # ... evaluation logic

  duration_ms = System.monotonic_time() - start_time |> System.convert_time_unit(:native, :millisecond)

  :telemetry.execute(
    [:ipa, :scheduler, :evaluation, :duration],
    %{duration: duration_ms},
    %{task_id: state.task_id, phase: state.current_phase}
  )

  if duration_ms > 100 do
    Logger.warning("Slow evaluation", duration_ms: duration_ms, task_id: state.task_id)
  end

  # ...
end
```

### 8.2 Performance Considerations ✅ GOOD

**Documented Metrics**:
- Evaluation Frequency: Controlled by cooldowns ✅
- Agent Spawn Time: 5-10s (workspace + SDK init) ✅
- Memory Usage: Minimal ✅
- CPU Usage: Low when idle, moderate during evaluation ✅

These are reasonable estimates.

### 8.3 Resource Management ⚠️ NEEDS IMPROVEMENT

**Issue P1-10: No Disk Space Checks Before Spawning**

The spec handles disk full during workspace creation (line 1087), but this is reactive. For better UX:

**Recommendation**: Add proactive checks:
```elixir
defp spawn_agent(agent_type, prompt, task_state, scheduler_state) do
  # Check available disk space
  case check_disk_space() do
    {:ok, _available_mb} ->
      # Proceed with spawn

    {:error, :low_disk_space} ->
      Logger.error("Low disk space, cannot spawn agent")
      Ipa.Pod.State.append_event(
        task_state.task_id,
        "scheduler_blocked",
        %{reason: "low_disk_space"},
        task_state.version,
        actor_id: "scheduler"
      )
      enter_cooldown(scheduler_state, :custom, 300_000) # Wait 5 minutes
  end
end

defp check_disk_space() do
  # Implementation depends on workspace base path
  # Could use :disksup from :os_mon
end
```

---

## 9. Testing Strategy

### 9.1 Test Coverage ✅ EXCELLENT

**Strengths**:
- Comprehensive unit test plan
- Integration tests cover full flows
- Specific mention of concurrent agent testing
- Mocking strategy is appropriate

**Test Plan Quality**:
The spec identifies key test areas:
1. State machine logic (all phases)
2. Action execution
3. Cooldown management
4. Prompt generation
5. Full task flows
6. Agent lifecycle
7. Concurrent agents
8. Interruption

This is thorough.

### 9.2 Testing Recommendations ✅ GOOD

**Mocking Strategy**:
- Claude Code SDK: Mock with test adapter ✅
- Pod.State: Use real with in-memory store ✅
- WorkspaceManager: Use real with test filesystem ✅

This is the right balance of integration vs. unit testing.

**Additional Recommendation**:
Consider adding property-based tests for:
- State machine determinism (same input → same output)
- Cooldown timing (verify no race conditions)
- Event ordering (verify events are appended in correct sequence)

---

## 10. Missing Pieces & Clarifications Needed

### 10.1 Critical Missing Pieces (P0)

**P0-1**: Race condition in agent spawn check (see section 2.3)
**P0-2**: Agent process lifecycle is fragile (see section 3.2)
**P0-3**: Agent interruption doesn't actually kill the agent (see section 4.1)

### 10.2 Major Missing Pieces (P1)

**P1-1**: Missing evaluation logic for state machine conditions (see section 2.2)
**P1-2**: No backoff strategy for failed evaluations (see section 2.2)
**P1-3**: Concurrent agent limits not clarified (see section 2.3)
**P1-4**: Version conflicts not handled (see section 3.3)
**P1-5**: Multiple evaluations can queue up (see section 3.3)
**P1-6**: No timeout enforcement for agents (see section 4.1)
**P1-7**: Agent stream handling is underspecified (see section 4.3)
**P1-8**: Generic error handling loses context (see section 6.2)
**P1-9**: SDK API contract not documented (see section 7.3)
**P1-10**: No disk space checks before spawning (see section 8.3)

### 10.3 Minor Missing Pieces (P2)

**P2-1**: Cooldown schedule drift (see section 5.2)
**P2-2**: No telemetry/observability hooks
**P2-3**: No circuit breaker for repeated failures
**P2-4**: Prompt generation could be in separate module

### 10.4 Clarifications Needed

1. **Agent Concurrency**: Is the 3-agent limit global or per-phase?
2. **SDK Stream API**: What is the actual API contract?
3. **Workspace Cleanup Failures**: What happens if cleanup fails?
4. **Evaluation Helpers**: How are conditions like "tests passing" determined?
5. **PR Status Checking**: How does the Scheduler know PR status? (GitHub API? ExternalSync?)

---

## 11. Security Considerations

### 11.1 Security Analysis ✅ GOOD

**Documented Concerns**:
- Agent Isolation: Agents run in isolated workspaces ✅
- Prompt Injection: Validate and sanitize inputs ✅
- Resource Limits: Enforce max runtime, max concurrent agents ✅
- Privilege Separation: Agents run with limited permissions ✅

**Additional Recommendation**:
Add section on "Agent Sandboxing" to specify:
- What permissions do agents have?
- Can agents access network?
- Can agents execute arbitrary binaries?
- Are environment variables sanitized?

### 11.2 Audit Trail ✅ EXCELLENT

**Strengths**:
- All scheduler actions are recorded as events
- `actor_id: "scheduler"` on all events provides clear attribution
- Event history provides complete audit trail

---

## 12. Future Compatibility

### 12.1 Extensibility ✅ EXCELLENT

**Future Enhancements Section**:
The spec outlines a clear evolution path:
- Phase 1: Basic state machine (current)
- Phase 2: Parallel agents, auto-approvals
- Phase 3: AI-powered action selection

This shows forward thinking.

**Observation**:
The event-sourced design makes it easy to add new event types and phase transitions without breaking existing functionality.

### 12.2 Multi-Workspace Support ✅ GOOD

**Observation**:
The spec mentions "Multi-workspace support" as a future enhancement (line 1185) and the WorkspaceManager is designed with this in mind. The Scheduler spec correctly delegates this to WorkspaceManager.

---

## Critical Issues (P0) - MUST FIX BEFORE IMPLEMENTATION

### P0-1: Race Condition in Agent Spawn Check
**Location**: Lines 478, 502, 534, 562
**Impact**: Could spawn multiple agents when only one is intended
**Fix**: Check `scheduler_state.active_agent_pids` instead of `task_state.agents`

### P0-2: Agent Process Lifecycle is Fragile
**Location**: Lines 645, 688, 778-817
**Impact**: Scheduler crash loses all agent tracking; agent crashes take down scheduler
**Fix**: Use `spawn/1` instead of `spawn_link/1`; add restart recovery logic

### P0-3: Agent Interruption Doesn't Kill the Agent
**Location**: Lines 301-327
**Impact**: `interrupt_agent/2` doesn't actually terminate the agent process
**Fix**: Add `Process.exit(agent_pid, :kill)` in interrupt logic

---

## Major Recommendations (P1) - STRONGLY RECOMMENDED

### P1-1: Add State Evaluation Helpers Specification
**Location**: Section 2.2
**Impact**: Ambiguous evaluation logic could lead to incorrect phase transitions
**Fix**: Add section "State Evaluation Helpers" with detailed logic for each condition

### P1-2: Implement Exponential Backoff for Failed Evaluations
**Location**: Lines 1073-1080
**Impact**: Repeated failures lead to constant error logging
**Fix**: Add failure counter and exponential backoff calculation

### P1-3: Clarify Concurrent Agent Limits
**Location**: Line 189, line 928
**Impact**: Unclear if limits are per-phase or global
**Fix**: Document agent limit policy explicitly

### P1-4: Handle Version Conflicts Gracefully
**Location**: Lines 640-642, 724-734
**Impact**: Version conflicts crash the scheduler
**Fix**: Add `case` statement to handle `{:error, :version_conflict}`

### P1-5: Prevent Multiple Evaluation Scheduling
**Location**: Lines 418-421, 758
**Impact**: Multiple `:evaluate` messages can queue up
**Fix**: Add `evaluation_scheduled?` flag to track scheduling state

### P1-6: Enforce Agent Timeout
**Location**: Line 929
**Impact**: Agents can run indefinitely despite configured timeout
**Fix**: Add timeout tracking and enforcement logic

### P1-7: Specify Agent Stream Handling
**Location**: Lines 696-712
**Impact**: Critical integration point is underspecified
**Fix**: Add detailed specification of stream event handling

### P1-8: Improve Error Handling Context
**Location**: Lines 1073-1080
**Impact**: Generic error handling loses important debugging information
**Fix**: Capture stacktrace, emit telemetry, record error events

### P1-9: Document Claude Code SDK API Contract
**Location**: Lines 680-684
**Impact**: Integration assumptions are implicit
**Fix**: Add appendix with SDK API contract

### P1-10: Add Proactive Disk Space Checks
**Location**: Lines 1084-1095
**Impact**: Only reacts to disk full errors, poor UX
**Fix**: Check disk space before spawning agents

---

## Minor Suggestions (P2) - NICE TO HAVE

### P2-1: Handle Cooldown Schedule Drift
**Location**: Lines 418-421
**Impact**: Evaluations may use stale state
**Suggestion**: Track state version to ensure fresh state at evaluation

### P2-2: Add Telemetry Hooks
**Location**: Throughout
**Impact**: Limited observability in production
**Suggestion**: Add `:telemetry` events for key operations

### P2-3: Implement Circuit Breaker for Repeated Failures
**Location**: Error handling sections
**Impact**: Repeated failures could exhaust resources
**Suggestion**: Add circuit breaker pattern for spawn failures

### P2-4: Extract Prompt Generation to Separate Module
**Location**: Lines 823-913
**Impact**: Large module, prompts hard to test in isolation
**Suggestion**: Create `Ipa.Pod.Scheduler.Prompts` module

---

## Detailed Review by Section

### API Design ✅ EXCELLENT
- Public functions are well-defined
- Function signatures are clear and typespecs are provided
- Return values follow Elixir conventions
- Error cases are documented

### OTP Patterns ✅ GOOD
- GenServer usage is appropriate
- Registry integration is correct
- Supervision tree positioning is right
- **Minor issues**: Process linking strategy needs refinement (P0-2)

### Event Sourcing ✅ EXCELLENT
- All actions append events
- No direct state mutation
- Events are well-structured
- Actor attribution is consistent

### State Machine ✅ GOOD
- Phase progression is clear
- Transitions are well-defined
- Terminal phases are identified
- **Minor issues**: Evaluation helpers need specification (P1-1)

### Concurrency ⚠️ NEEDS WORK
- Cooldown mechanism is solid
- Registry usage is correct
- **Issues**: Race conditions (P0-1), version conflicts (P1-4), evaluation queuing (P1-5)

### Error Handling ⚠️ NEEDS IMPROVEMENT
- Basic error handling is present
- **Issues**: Error context is lost (P1-8), no backoff strategy (P1-2)

### Testing ✅ EXCELLENT
- Comprehensive test plan
- Appropriate mocking strategy
- Integration and unit tests both covered

### Documentation ✅ EXCELLENT
- Clear overview and purpose
- Detailed implementation examples
- Good use of code examples
- Integration points are documented

---

## Comparison with Related Specs

### vs. Pod State Manager (2.2)
**Similarity**: Both are GenServer-based pod components
**Difference**: State Manager is passive (serves state), Scheduler is active (makes decisions)
**Integration**: Scheduler depends on State Manager correctly
**Quality**: Both specs are high quality; Scheduler needs similar attention to concurrency edge cases that State Manager addressed

### vs. Pod Workspace Manager (2.4)
**Similarity**: Both manage pod resources
**Difference**: Workspace Manager is utility-focused, Scheduler is orchestration-focused
**Integration**: Clean separation - Scheduler calls WorkspaceManager for lifecycle only
**Quality**: Both specs are well-designed

### vs. Event Store (1.1)
**Integration**: Scheduler correctly uses Event Store via Pod.State abstraction
**Quality**: Scheduler maintains the same event-sourcing discipline as Event Store

---

## Approval & Next Steps

### Overall Assessment

This is a **well-designed specification** that demonstrates strong architectural thinking. The reactive design, event-sourced approach, and clear phase progression are all excellent. However, there are several concurrency and error handling edge cases that must be addressed before implementation.

### Approval Status

✅ **APPROVED for implementation** with the following conditions:

1. **MUST address all P0 issues** (race conditions, process lifecycle, agent interruption)
2. **SHOULD address all P1 issues** (evaluation helpers, backoff, version conflicts, etc.)
3. **MAY address P2 issues** (telemetry, circuit breaker, etc.)

### Recommended Implementation Sequence

1. **Phase 1**: Core state machine (implement P0 fixes)
   - State machine evaluation logic with evaluation helpers (P1-1)
   - Agent spawning with proper process management (P0-2, P0-3)
   - Basic cooldown mechanism

2. **Phase 2**: Robustness (implement P1 fixes)
   - Error handling with context and backoff (P1-2, P1-8)
   - Version conflict handling (P1-4)
   - Agent timeout enforcement (P1-6)
   - Evaluation scheduling improvements (P1-5)

3. **Phase 3**: Polish (implement P2 suggestions)
   - Telemetry and observability (P2-2)
   - Circuit breaker pattern (P2-3)
   - Code organization improvements (P2-4)

### Pre-Implementation Checklist

- [ ] Update spec to address all P0 issues
- [ ] Add "State Evaluation Helpers" section (P1-1)
- [ ] Add "Claude Code SDK API Contract" appendix (P1-9)
- [ ] Clarify agent concurrency limits (P1-3)
- [ ] Add error handling improvements section
- [ ] Review with team
- [ ] Get sign-off from architect/lead

---

## Sign-Off

**Architectural Review Score**: 8.5/10

**Reviewer**: Claude (System Architecture Expert)
**Review Date**: 2025-11-06
**Status**: **APPROVED with Recommended Improvements**

**Strengths**:
- Excellent architectural alignment
- Clean separation of concerns
- Strong event-sourcing discipline
- Comprehensive testing strategy
- Clear state machine design

**Weaknesses**:
- Agent process lifecycle needs refinement
- Some concurrency edge cases need attention
- Error handling could be more sophisticated
- Integration contracts need documentation

**Recommendation**: This spec is production-ready pending the P0 fixes. The design is sound and will integrate well with the existing IPA architecture.

---

## Appendix: Suggested Additions to Spec

### A. State Evaluation Helpers Section

Add after line 581 (end of state machine evaluation):

```markdown
### State Machine Evaluation Helpers

These helper functions determine state machine conditions:

#### `implementation_complete?(state)`
Returns true if:
- At least one agent has completed in development phase
- Agent completion included artifacts (code, tests)
- No pending work items remain

Implementation:
- Check `state.agents` for completed development agents
- Verify workspace contains expected artifacts

#### `tests_passing?(state)`
Returns true if:
- Last agent run included test execution
- Test exit code was 0
- Test output doesn't contain failures

Implementation:
- Parse agent output for test results
- Check for test execution artifacts in workspace
- Verify no test failures in recent agent runs

#### `pr_merged?(state)`
Returns true if:
- `state.external_sync.github.pr_status == "merged"`
- Or verify via GitHub API if ExternalSync hasn't updated yet

#### `has_failed_agents?(state)`
Returns true if:
- `state.agents` contains agents with `status: :failed`
- Failed within last 10 minutes (recent failures only)

#### `max_agents_reached?(state)`
Returns true if:
- Count of active agents >= configured limit
- Limit is per-phase or global (to be determined)
```

### B. Claude Code SDK API Contract Appendix

Add as final appendix:

```markdown
## Appendix B: Claude Code SDK API Contract

### Expected SDK Function

```elixir
@spec ClaudeCode.run_task(opts :: keyword()) ::
  {:ok, stream :: Enumerable.t()} | {:error, reason :: term()}
```

**Options**:
- `:prompt` - String, required
- `:cwd` - String, working directory path, required
- `:allowed_tools` - List of atoms, default `[:read, :write, :bash]`
- `:stream` - Boolean, default `false`

**Return Value**:
- `{:ok, stream}` - Stream of agent events (if `:stream` is true)
- `{:ok, result}` - Final result map (if `:stream` is false)
- `{:error, :sdk_unavailable}` - SDK not initialized
- `{:error, :invalid_workspace}` - Workspace path invalid
- `{:error, reason}` - Other errors

### Stream Event Format

When `:stream` is true, the returned stream emits events:

```elixir
{:output, text :: String.t()}          # Agent output text
{:tool_use, tool :: atom(), args}      # Agent used a tool
{:thinking, text :: String.t()}        # Agent thinking process
{:complete, result :: map()}           # Agent completed
{:error, error :: term()}              # Agent error
{:interrupted, reason :: term()}       # Interrupted
```

### Integration Pattern

```elixir
{:ok, stream} = ClaudeCode.run_task(prompt: prompt, cwd: path, stream: true)

# Stream processing
stream
|> Stream.each(fn event ->
  case event do
    {:output, text} -> handle_output(text)
    {:complete, result} -> handle_complete(result)
    {:error, error} -> handle_error(error)
  end
end)
|> Stream.run()
```

### Error Handling

If the SDK process crashes or becomes unavailable, the stream will emit:
```elixir
{:error, :sdk_crashed}
```

The Scheduler should treat this as an agent failure.
```
```

---

## Review Complete

This review provides a comprehensive architectural analysis of the Pod Scheduler specification. The component is well-designed and ready for implementation pending the critical fixes outlined above.

**Key Takeaway**: The Pod Scheduler represents the "brain" of the pod and its design reflects thoughtful consideration of the orchestration challenges. With the recommended improvements, it will be a robust and maintainable component.
