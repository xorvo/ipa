# Component 2.3: Pod Scheduler - Architecture Refactor Plan

**Created**: 2025-11-06
**Status**: Refactor Required
**Effort**: +3 weeks (from 1 week to 4 weeks total)

## Overview

The Pod Scheduler spec is currently approved and comprehensive (2183 lines). However, the architecture refactor requires a **fundamental transformation** from a simple state machine into a full **orchestration engine** that manages multiple parallel workstreams.

This is the **most significant component update** in the entire architecture refactor.

## Current Architecture (Single-Agent State Machine)

**Current Model**:
- One agent per phase (spec_clarification, planning, development, review)
- Linear phase progression: spec → plan → dev → review → completed
- State machine evaluates phase and spawns appropriate agent
- Approval gates between phases
- Simple agent lifecycle management

**Current Phases**:
```
spec_clarification → planning → development → review → completed
```

## New Architecture (Workstream Orchestration Engine)

**New Model**:
- **Task Planning**: Scheduler breaks down task into parallel workstreams
- **Workstream Creation**: Dynamically creates workstreams with specs and dependencies
- **Agent Orchestration**: One agent per workstream, multiple workstreams run in parallel
- **Dependency Management**: Workstreams wait for dependencies before starting
- **Concurrency Control**: Max N concurrent workstreams (configurable, default 3)
- **Template Generation**: Generates CLAUDE.md for each workstream via Component 2.8
- **Communications Integration**: Uses Component 2.7 for questions, approvals, updates

**New Phases**:
```
planning → workstream_execution → review → completed
```

## Required Changes

### 1. Remove Old Phase-Based Logic

**Delete/Replace**:
- `evaluate_spec_clarification/2` - No longer needed
- `evaluate_planning/2` - Replace with workstream planning logic
- `evaluate_development/2` - Replace with workstream orchestration logic
- `evaluate_review/2` - Simplify to PR creation and merge detection
- Agent prompts for spec_clarification, planning, development phases
- Single-agent-per-phase model

### 2. Add Workstream Planning Phase

**New Function**: `evaluate_planning/2` (completely rewritten)

**FIX P0#1: Clarified planning phase flow to avoid circular dependency**

When in `:planning` phase:
1. **If no planning agent running and no plan** → Spawn planning agent to generate workstream breakdown (agent outputs JSON to file)
2. **If planning agent completed** → Parse workstream JSON, validate, create workstream events
3. **If workstreams created and plan approved** → Transition to `:workstream_execution`

**Key Design Decision**: The planning agent does NOT need CLAUDE.md at workstream level (since workstreams don't exist yet). It only needs pod-level CLAUDE.md which contains:
- Task spec and context
- System architecture overview
- General coding standards

The workstream-level CLAUDE.md is generated LATER when spawning workstream agents (lines 197-200).

**Planning Agent Prompt** (new):
```elixir
defp generate_planning_agent_prompt(task_state) do
  """
  Task: #{task_state.title}

  Spec: #{task_state.spec}

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

  Output a JSON structure:
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
```

### 3. Add Workstream Creation Logic

**New Function**: `create_workstreams_from_plan/2`

```elixir
defp create_workstreams_from_plan(plan, task_state, scheduler_state) do
  # Parse workstream breakdown from plan
  workstreams = parse_workstream_plan(plan)

  # For each workstream, append workstream_created event
  Enum.each(workstreams, fn ws ->
    workstream_id = generate_workstream_id()

    case Ipa.Pod.State.append_event(
      task_state.task_id,
      "workstream_created",
      %{
        workstream_id: workstream_id,
        title: ws.title,
        spec: ws.description,
        dependencies: ws.dependencies,
        estimated_hours: ws.estimated_hours
      },
      task_state.version,
      actor_id: "scheduler"
    ) do
      {:ok, _version} ->
        Logger.info("Created workstream", workstream_id: workstream_id)

      {:error, :version_conflict} ->
        # Retry on next evaluation
        Logger.warning("Version conflict creating workstream")

      {:error, reason} ->
        Logger.error("Failed to create workstream", error: reason)
    end
  end)
end
```

### 4. Add Workstream Orchestration Logic

**New Function**: `evaluate_workstream_execution/2` (replaces `evaluate_development/2`)

```elixir
defp evaluate_workstream_execution(task_state, scheduler_state) do
  # Get all workstreams from state
  workstreams = task_state.workstreams

  cond do
    # All workstreams completed → transition to review
    all_workstreams_completed?(workstreams) ->
      {:transition, :review, "All workstreams completed"}

    # Max concurrent workstreams reached → wait
    max_workstreams_reached?(workstreams, scheduler_state) ->
      {:wait, :max_workstreams_reached}

    # Find next workstream to start (dependencies satisfied, not started)
    true ->
      case find_ready_workstream(workstreams, scheduler_state) do
        {:ok, workstream} ->
          {:spawn_workstream_agent, workstream}

        {:error, :none_ready} ->
          # No workstreams ready (all blocked or running)
          {:wait, :workstreams_blocked_or_running}
      end
  end
end
```

### 5. Add Workstream Agent Spawning

**New Function**: `spawn_workstream_agent/3`

```elixir
defp spawn_workstream_agent(workstream, task_state, scheduler_state) do
  require Logger
  agent_id = generate_agent_id()
  workstream_id = workstream.workstream_id

  Logger.info("Spawning agent for workstream",
    task_id: task_state.task_id,
    workstream_id: workstream_id,
    agent_id: agent_id
  )

  # FIX P0#4: Generate CLAUDE.md for this workstream via Component 2.8
  # Note: Component 2.8 API requires 3 params (task_id, workstream_id, opts)
  # but opts defaults to [] if not provided
  case Ipa.Pod.ClaudeMdTemplates.generate_workstream_level(
    task_state.task_id,
    workstream_id,
    []  # FIX P0#4: Explicitly pass empty opts list
  ) do
    {:ok, claude_md_content} ->
      # Create workspace with CLAUDE.md
      case Ipa.Pod.WorkspaceManager.create_workspace(
        task_state.task_id,
        workstream_id,
        agent_id,
        %{
          max_size_mb: 1000,
          git_config: %{enabled: true},
          claude_md: claude_md_content
        }
      ) do
        {:ok, workspace_path} ->
          # Generate workstream-specific prompt
          prompt = generate_workstream_agent_prompt(workstream, task_state)

          # Spawn agent
          case spawn_claude_agent(agent_id, prompt, workspace_path) do
            {:ok, agent_pid} ->
              # Record workstream_agent_started event
              record_workstream_agent_started(
                task_state,
                workstream_id,
                agent_id,
                workspace_path,
                agent_pid,
                scheduler_state
              )

            {:error, reason} ->
              Logger.error("Failed to spawn workstream agent", error: reason)
              cleanup_and_fail(task_state, workstream_id, agent_id, reason)
          end

        {:error, reason} ->
          Logger.error("Failed to create workspace", error: reason)
          enter_cooldown(scheduler_state, :spawn_failure)
      end

    {:error, reason} ->
      Logger.error("Failed to generate CLAUDE.md", error: reason)
      enter_cooldown(scheduler_state, :spawn_failure)
  end
end
```

**FIX P0#5: Race Condition in Workstream Spawning**

**Issue**: Between checking if a workstream is ready (`find_ready_workstream`) and recording the `workstream_agent_started` event, the state could change (e.g., another evaluation cycle starts the same workstream, or workstream is cancelled). This could cause:
1. Double-spawning of the same workstream
2. Version conflicts when appending event
3. Spawning a workstream that's no longer valid

**Fix**: Reload state and use version checking right before recording workstream_agent_started event.

**Updated record_workstream_agent_started function**:

```elixir
defp record_workstream_agent_started(
  task_state,
  workstream_id,
  agent_id,
  workspace_path,
  agent_pid,
  scheduler_state
) do
  # FIX P0#5: Reload state to get latest version and verify workstream is still pending
  case Ipa.Pod.State.get_state(task_state.task_id) do
    {:ok, current_state} ->
      workstream = current_state.workstreams[workstream_id]

      # FIX P0#5: Verify workstream is still in :pending status
      # (could have been started by another evaluation or cancelled)
      if workstream.status != :pending do
        Logger.warning("Workstream status changed before recording start",
          workstream_id: workstream_id,
          expected_status: :pending,
          actual_status: workstream.status
        )

        # Cleanup since we can't start this workstream
        Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, workstream_id, agent_id)

        # Kill the agent we just spawned
        Process.exit(agent_pid, :workstream_status_changed)

        {:error, :workstream_status_changed}
      else
        # FIX P0#5: Use current_state.version for optimistic concurrency
        case Ipa.Pod.State.append_event(
          task_state.task_id,
          "workstream_agent_started",
          %{
            workstream_id: workstream_id,
            agent_id: agent_id,
            workspace: workspace_path,
            agent_pid: inspect(agent_pid),
            started_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          current_state.version,  # FIX P0#5: Use FRESH version, not stale task_state.version
          actor_id: "scheduler"
        ) do
          {:ok, _new_version} ->
            # Success! Update scheduler state to track this agent
            new_agents = Map.put(
              scheduler_state.active_workstream_agents,
              workstream_id,
              %{
                agent_id: agent_id,
                agent_pid: agent_pid,
                started_at: DateTime.utc_now()
              }
            )

            # Post update to Communications Manager
            Ipa.Pod.CommunicationsManager.post_message(
              task_state.task_id,
              type: :update,
              content: "Started workstream: #{workstream.title || workstream_id}",
              author: "scheduler",
              workstream_id: workstream_id
            )

            {:ok, %{scheduler_state | active_workstream_agents: new_agents}}

          {:error, :version_conflict} ->
            # FIX P0#5: State changed between spawn and record! Cleanup and retry.
            Logger.warning("Version conflict recording workstream start, cleaning up",
              workstream_id: workstream_id,
              agent_id: agent_id
            )

            # Cleanup workspace and kill agent
            Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, workstream_id, agent_id)
            Process.exit(agent_pid, :version_conflict)

            # Return error so scheduler can retry on next evaluation
            {:error, :version_conflict}

          {:error, reason} ->
            Logger.error("Failed to record workstream start", error: reason)
            Ipa.Pod.WorkspaceManager.cleanup_workspace(task_state.task_id, workstream_id, agent_id)
            Process.exit(agent_pid, :record_failed)
            {:error, reason}
        end
      end

    {:error, reason} ->
      Logger.error("Failed to reload state before recording start", error: reason)
      {:error, reason}
  end
end
```

**Updated spawn_workstream_agent to handle record errors**:

```elixir
defp spawn_workstream_agent(workstream, task_state, scheduler_state) do
  # ... (CLAUDE.md generation, workspace creation, agent spawn - same as before)

  case spawn_claude_agent(agent_id, prompt, workspace_path) do
    {:ok, agent_pid} ->
      # FIX P0#5: Record can now fail due to race conditions
      case record_workstream_agent_started(
        task_state,
        workstream_id,
        agent_id,
        workspace_path,
        agent_pid,
        scheduler_state
      ) do
        {:ok, updated_scheduler_state} ->
          {:ok, updated_scheduler_state}

        {:error, :version_conflict} ->
          # Cleaned up already, just return error
          Logger.info("Spawn aborted due to version conflict, will retry on next evaluation")
          {:error, :version_conflict}

        {:error, :workstream_status_changed} ->
          # Workstream was cancelled or started elsewhere
          Logger.info("Spawn aborted, workstream status changed")
          {:error, :workstream_status_changed}

        {:error, reason} ->
          Logger.error("Failed to record workstream start", error: reason)
          {:error, reason}
      end

    {:error, reason} ->
      Logger.error("Failed to spawn workstream agent", error: reason)
      cleanup_and_fail(task_state, workstream_id, agent_id, reason)
  end
end
```

**Summary of P0#5 Fix**:
1. ✅ Reload state in `record_workstream_agent_started` to get fresh version
2. ✅ Verify workstream is still in `:pending` status before recording
3. ✅ Use current version for optimistic concurrency control
4. ✅ Handle `:version_conflict` by cleaning up workspace and killing agent
5. ✅ Return error to scheduler so it can retry on next evaluation
6. ✅ Prevent double-spawning of same workstream

**FIX P0#4: Component 2.8 API Integration**

**Issue**: Component 2.8 spec shows `generate_workstream_level/3` requiring 3 parameters (task_id, workstream_id, opts), but the example in the spec only passes 2 parameters. This is inconsistent.

**Fix Applied**:
1. ✅ Scheduler now explicitly passes empty opts list `[]` as third parameter
2. ⚠️ **Action Required**: Component 2.8 spec should be updated to make `opts` optional with default value:

```elixir
# In Component 2.8 spec (specs/2.8_claude_md_templates/spec.md)
# Update the function signature to:

def generate_workstream_level(task_id, workstream_id, opts \\ []) do
  # ... implementation
end

# And update the @spec to show opts is optional:
@spec generate_workstream_level(
  task_id :: String.t(),
  workstream_id :: String.t(),
  opts :: keyword()
) :: {:ok, content :: String.t()} | {:error, term()}

# Alternative @spec notation showing optional parameter:
@spec generate_workstream_level(
  task_id :: String.t(),
  workstream_id :: String.t()
) :: {:ok, content :: String.t()} | {:error, term()}

@spec generate_workstream_level(
  task_id :: String.t(),
  workstream_id :: String.t(),
  opts :: keyword()
) :: {:ok, content :: String.t()} | {:error, term()}
```

**Summary of P0#4 Fix**:
1. ✅ Scheduler code updated to explicitly pass opts parameter
2. ⚠️ Component 2.8 spec needs minor update to document default parameter value

### 6. Add Workstream-Specific Prompt Generation

**New Function**: `generate_workstream_agent_prompt/2`

```elixir
defp generate_workstream_agent_prompt(workstream, task_state) do
  """
  # Workstream: #{workstream.title}

  ## Task Context
  Task: #{task_state.title}
  Overall Goal: #{task_state.spec.description}

  ## Your Workstream
  #{workstream.spec}

  ## Dependencies
  #{format_workstream_dependencies(workstream, task_state)}

  ## Instructions

  You are working on this specific workstream as part of a larger task.
  Other agents are working on other workstreams in parallel.

  Your responsibilities:
  1. Implement the workstream spec above
  2. Write tests for your implementation
  3. Update specs/#{workstream.workstream_id}/tracker.md with your progress
  4. Use the Communications Manager to:
     - Ask questions if you're unclear: IpaAgent.ask_question("...")
     - Request approval for critical decisions: IpaAgent.request_approval("...", options: [...])
     - Post updates on your progress: IpaAgent.post_update("...")
     - Report blockers: IpaAgent.report_blocker("...")

  Important notes:
  - Your workspace is at: ./
  - The project repository is cloned at: ./work
  - Your spec and tracker are at: ./work/specs/#{workstream.workstream_id}/
  - CLAUDE.md in your workspace contains full context
  - Review CLAUDE.md for system architecture and conventions

  When you're done:
  - Ensure all tests pass
  - Update tracker.md with "COMPLETED" status
  - Create a summary of what you implemented

  Begin working on your workstream now.
  """
end

defp format_workstream_dependencies(workstream, task_state) do
  if Enum.empty?(workstream.dependencies) do
    "This workstream has no dependencies. You can start immediately."
  else
    deps_info = Enum.map(workstream.dependencies, fn dep_id ->
      dep = task_state.workstreams[dep_id]
      "- #{dep_id}: #{dep.title} (Status: #{dep.status})"
    end)
    |> Enum.join("\n")

    """
    This workstream depends on the following:
    #{deps_info}

    All dependencies have completed, so you can proceed.
    """
  end
end
```

### 7. Add Dependency Management

**New Functions**:

```elixir
defp find_ready_workstream(workstreams, scheduler_state) do
  # Find workstreams that are:
  # 1. Status = :pending
  # 2. Dependencies satisfied (blocking_on is empty)
  # 3. Not currently running (not in active_workstream_agents)

  ready = workstreams
    |> Map.values()
    |> Enum.filter(fn ws ->
      ws.status == :pending &&
      Enum.empty?(ws.blocking_on) &&
      !Map.has_key?(scheduler_state.active_workstream_agents, ws.workstream_id)
    end)
    |> Enum.sort_by(fn ws -> length(ws.dependencies) end)  # Prioritize by dependency count
    |> List.first()

  case ready do
    nil -> {:error, :none_ready}
    ws -> {:ok, ws}
  end
end

defp all_workstreams_completed?(workstreams) do
  workstreams
  |> Map.values()
  |> Enum.all?(fn ws -> ws.status == :completed end)
end

defp max_workstreams_reached?(workstreams, scheduler_state) do
  max_concurrent = Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_workstream_concurrency] || 3

  # FIX P0#7: Use scheduler_state.active_workstream_agents instead of querying workstreams status
  # This is more accurate (scheduler's source of truth) and avoids stale reads
  active_count = map_size(scheduler_state.active_workstream_agents)

  active_count >= max_concurrent
end
```

**FIX P0#7: Max Concurrency Enforcement Using Scheduler State**

**Issue**: The function `max_workstreams_reached?/2` was checking `workstreams` from Pod State (via `task_state.workstreams`) to count how many workstreams have `status == :in_progress`. This has several problems:

1. **Stale Data**: `task_state` is passed down from the evaluation cycle start and could be stale
2. **Source of Truth**: Scheduler's `active_workstream_agents` is the actual source of truth for what agents are running
3. **Race Conditions**: Between loading state and checking status, agents could start or stop
4. **Efficiency**: Extra map traversal and filtering when we already have the count in `active_workstream_agents`

**Fix**: Check `scheduler_state.active_workstream_agents` directly using `map_size/1`.

**Why This Works**:
- `active_workstream_agents` is a map of `workstream_id => agent_info`
- The scheduler updates this map when agents start (in `record_workstream_agent_started`)
- The scheduler removes from this map when agents complete/fail (in `handle_info`)
- `map_size/1` gives us the exact count of currently running agents
- This is the scheduler's internal state, so it's always consistent

**Benefits**:
1. ✅ **Accurate**: Uses scheduler's own tracking, not stale state
2. ✅ **Efficient**: O(1) `map_size/1` vs O(n) filter + count
3. ✅ **Race-Free**: Scheduler state is updated atomically in GenServer
4. ✅ **Single Source of Truth**: Scheduler state is authoritative for agent tracking

**Alternative Implementation (with defensive check)**:

If we want to be extra defensive and verify consistency:

```elixir
defp max_workstreams_reached?(workstreams, scheduler_state) do
  max_concurrent = Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_workstream_concurrency] || 3

  # FIX P0#7: Primary check uses scheduler state (source of truth)
  active_count = map_size(scheduler_state.active_workstream_agents)

  # Defensive check: Verify consistency with Pod State (optional, for debugging)
  if Mix.env() == :dev do
    pod_state_count = workstreams
      |> Map.values()
      |> Enum.count(fn ws -> ws.status == :in_progress end)

    if active_count != pod_state_count do
      Logger.warning("Scheduler state mismatch",
        scheduler_active: active_count,
        pod_state_active: pod_state_count,
        scheduler_agents: Map.keys(scheduler_state.active_workstream_agents)
      )
    end
  end

  active_count >= max_concurrent
end
```

**Summary of P0#7 Fix**:
1. ✅ Changed concurrency check to use `scheduler_state.active_workstream_agents` (O(1) map_size)
2. ✅ Removed dependency on potentially stale `task_state.workstreams`
3. ✅ Made scheduler the single source of truth for active agent tracking
4. ✅ Improved efficiency (O(1) vs O(n))
5. ✅ Eliminated race condition from stale state reads

**FIX P0#2: Dependency Resolution Algorithm**

This section clarifies how `blocking_on` is managed throughout the workstream lifecycle.

#### How blocking_on is Initialized

When workstreams are created via `create_workstreams_from_plan/2`, the scheduler appends `workstream_created` events. **Component 2.2 (Pod State Manager)** handles the projection and initializes `blocking_on`:

```elixir
# In create_workstreams_from_plan/2 (scheduler appends event)
Ipa.Pod.State.append_event(
  task_state.task_id,
  "workstream_created",
  %{
    workstream_id: workstream_id,
    title: ws.title,
    spec: ws.description,
    dependencies: ws.dependencies,  # List of workstream IDs this depends on
    estimated_hours: ws.estimated_hours
  },
  task_state.version,
  actor_id: "scheduler"
)

# Component 2.2's projection initializes blocking_on:
# For each dependency in dependencies list:
#   - If dependency workstream doesn't exist yet → add to blocking_on
#   - If dependency workstream exists and status != :completed → add to blocking_on
#   - If dependency workstream is :completed → don't add to blocking_on
```

**Key Point**: `blocking_on` is a **subset** of `dependencies` - only the dependencies that are NOT yet completed.

#### How blocking_on is Updated

When a workstream completes, **Component 2.2's `workstream_completed` projection** automatically updates `blocking_on` for all dependent workstreams:

```elixir
# Component 2.2 projection logic (in specs/2.2_pod_state_manager/REFACTOR_PLAN.md lines 291-324)
defp apply_event(%{
  event_type: "workstream_completed",
  data: %{workstream_id: ws_id, result: result},
  ...
}, state) do
  # Update blocking_on for dependent workstreams
  updated_workstreams =
    state.workstreams
    |> Map.put(ws_id, updated_workstream)
    |> Enum.map(fn {id, ws} ->
      # CRITICAL: Check if ws_id is in blocking_on, not dependencies
      if ws_id in ws.blocking_on do
        {id, %{ws | blocking_on: List.delete(ws.blocking_on, ws_id)}}
      else
        {id, ws}
      end
    end)
    |> Map.new()

  %{state | workstreams: updated_workstreams, ...}
end
```

**Scheduler's Role**: The scheduler does NOT manage `blocking_on` directly. It only:
1. Appends `workstream_created` events (with dependencies list)
2. Appends `workstream_completed` events (triggers unblocking)
3. Queries `blocking_on` from state to determine readiness via `find_ready_workstream/2`

#### Circular Dependency Detection

**FIX P0#2: Add validation in create_workstreams_from_plan/2**

Before creating workstreams, validate the dependency graph is a DAG (Directed Acyclic Graph):

```elixir
defp create_workstreams_from_plan(plan, task_state, scheduler_state) do
  workstreams = parse_workstream_plan(plan)

  # FIX P0#2: Validate no circular dependencies
  case validate_dependency_graph(workstreams) do
    :ok ->
      # Proceed with workstream creation
      Enum.each(workstreams, fn ws ->
        workstream_id = generate_workstream_id()

        Ipa.Pod.State.append_event(
          task_state.task_id,
          "workstream_created",
          %{
            workstream_id: workstream_id,
            title: ws.title,
            spec: ws.description,
            dependencies: ws.dependencies,
            estimated_hours: ws.estimated_hours
          },
          task_state.version,
          actor_id: "scheduler"
        )
      end)

    {:error, :circular_dependency, cycle} ->
      Logger.error("Circular dependency detected in workstream plan",
        cycle: cycle,
        task_id: task_state.task_id
      )

      # Post blocker to Communications Manager
      Ipa.Pod.CommunicationsManager.post_message(
        task_state.task_id,
        type: :blocker,
        content: "Planning agent generated a circular dependency: #{inspect(cycle)}. Cannot proceed with workstream execution.",
        author: "scheduler"
      )

      # Transition back to planning phase for replanning
      request_transition(:planning, "Circular dependency detected", task_state, scheduler_state)
  end
end

defp validate_dependency_graph(workstreams) do
  # Build adjacency list
  graph = Map.new(workstreams, fn ws -> {ws.id, ws.dependencies} end)

  # Detect cycles using DFS with visited/recursion stack
  case find_cycle(graph) do
    nil -> :ok
    cycle -> {:error, :circular_dependency, cycle}
  end
end

defp find_cycle(graph) do
  visited = MapSet.new()
  rec_stack = MapSet.new()

  Enum.find_value(Map.keys(graph), fn node ->
    if node not in visited do
      detect_cycle_dfs(node, graph, visited, rec_stack, [node])
    end
  end)
end

defp detect_cycle_dfs(node, graph, visited, rec_stack, path) do
  visited = MapSet.put(visited, node)
  rec_stack = MapSet.put(rec_stack, node)

  # Check each dependency
  Enum.find_value(graph[node] || [], fn dep ->
    cond do
      # Cycle detected!
      dep in rec_stack ->
        # Return the cycle path
        cycle_start_idx = Enum.find_index(path, fn n -> n == dep end)
        Enum.slice(path, cycle_start_idx..-1) ++ [dep]

      # Unvisited node, recurse
      dep not in visited ->
        detect_cycle_dfs(dep, graph, visited, rec_stack, path ++ [dep])

      # Already visited in a different branch, safe
      true ->
        nil
    end
  end) || begin
    # Backtrack: remove from recursion stack
    rec_stack = MapSet.delete(rec_stack, node)
    nil
  end
end
```

#### Defensive Checks in find_ready_workstream

**FIX P0#2: Add safety checks**

```elixir
defp find_ready_workstream(workstreams, scheduler_state) do
  ready = workstreams
    |> Map.values()
    |> Enum.filter(fn ws ->
      # FIX P0#2: Defensive checks
      is_pending = ws.status == :pending
      deps_satisfied = Enum.empty?(ws.blocking_on)
      not_running = !Map.has_key?(scheduler_state.active_workstream_agents, ws.workstream_id)

      # FIX P0#2: Validate all dependencies actually exist in workstreams map
      all_deps_exist = Enum.all?(ws.dependencies, fn dep_id ->
        Map.has_key?(workstreams, dep_id)
      end)

      if not all_deps_exist do
        Logger.warning("Workstream has missing dependencies",
          workstream_id: ws.workstream_id,
          dependencies: ws.dependencies,
          task_id: scheduler_state.task_id
        )
      end

      is_pending && deps_satisfied && not_running && all_deps_exist
    end)
    |> Enum.sort_by(fn ws -> length(ws.dependencies) end)
    |> List.first()

  case ready do
    nil -> {:error, :none_ready}
    ws -> {:ok, ws}
  end
end
```

#### Recovery Strategies for Stuck Workstreams

**Deadlock Detection**:

Add a periodic check in the scheduler's evaluation loop to detect workstreams that are stuck:

```elixir
defp evaluate_workstream_execution(task_state, scheduler_state) do
  # FIX P0#2: Check for deadlocked workstreams
  case detect_deadlock(task_state.workstreams) do
    {:deadlock, stuck_workstreams} ->
      Logger.error("Deadlock detected",
        stuck_workstreams: stuck_workstreams,
        task_id: task_state.task_id
      )

      # Post blocker
      Ipa.Pod.CommunicationsManager.post_message(
        task_state.task_id,
        type: :blocker,
        content: """
        Deadlock detected: #{length(stuck_workstreams)} workstreams are stuck waiting for dependencies that will never complete.

        Stuck workstreams: #{Enum.map(stuck_workstreams, & &1.workstream_id) |> Enum.join(", ")}

        This may be caused by:
        1. A workstream failure that wasn't handled properly
        2. Missing workstream dependencies
        3. A bug in dependency resolution

        Manual intervention required.
        """,
        author: "scheduler"
      )

      # Transition to failed state or wait for human intervention
      {:wait, :deadlock_detected}

    :no_deadlock ->
      # Normal evaluation logic
      cond do
        all_workstreams_completed?(task_state.workstreams) ->
          {:transition, :review, "All workstreams completed"}

        max_workstreams_reached?(task_state.workstreams, scheduler_state) ->
          {:wait, :max_workstreams_reached}

        true ->
          case find_ready_workstream(task_state.workstreams, scheduler_state) do
            {:ok, workstream} ->
              {:spawn_workstream_agent, workstream}

            {:error, :none_ready} ->
              {:wait, :workstreams_blocked_or_running}
          end
      end
  end
end

defp detect_deadlock(workstreams) do
  # Check if there are pending workstreams that are waiting for dependencies
  # but NO workstreams are in_progress (nothing can unblock them)
  pending_with_blocks = workstreams
    |> Map.values()
    |> Enum.filter(fn ws ->
      ws.status == :pending && !Enum.empty?(ws.blocking_on)
    end)

  any_in_progress = workstreams
    |> Map.values()
    |> Enum.any?(fn ws -> ws.status == :in_progress end)

  # Deadlock if: workstreams are blocked BUT nothing is running to unblock them
  if length(pending_with_blocks) > 0 && !any_in_progress do
    {:deadlock, pending_with_blocks}
  else
    :no_deadlock
  end
end
```

**Summary of P0#2 Fix**:
1. ✅ Clarified `blocking_on` initialization (Component 2.2 responsibility)
2. ✅ Documented `blocking_on` updates (Component 2.2 projection)
3. ✅ Added circular dependency detection with DFS cycle detection
4. ✅ Added defensive checks in `find_ready_workstream/2`
5. ✅ Added deadlock detection and recovery via blocker messages

### 8. Update GenServer State

**New State Fields**:

```elixir
defmodule Ipa.Pod.Scheduler do
  use GenServer

  defstruct [
    :task_id,
    :current_phase,
    :last_evaluation,
    :cooldown_until,

    # CHANGED: Track workstream agents instead of phase agents
    :active_workstream_agents,     # Map of workstream_id → %{agent_id, agent_pid, started_at}

    # REMOVED: :active_agent_pids (replaced by active_workstream_agents)
    # REMOVED: :agent_start_times (now part of active_workstream_agents)

    :pending_action,
    :evaluation_count,
    :evaluation_failure_count,
    :evaluation_scheduled?
  ]
end
```

**State Structure Example**:
```elixir
%Ipa.Pod.Scheduler{
  task_id: "task-123",
  current_phase: :workstream_execution,
  active_workstream_agents: %{
    "ws-1" => %{
      agent_id: "agent-456",
      agent_pid: #PID<0.123.0>,
      started_at: ~U[2025-11-06 10:00:00Z]
    },
    "ws-2" => %{
      agent_id: "agent-789",
      agent_pid: #PID<0.124.0>,
      started_at: ~U[2025-11-06 10:05:00Z]
    }
  }
}
```

### 9. Update Event Handling

**New Events to Handle**:

```elixir
# Workstream agent started
def handle_info({:workstream_agent_completed, workstream_id, agent_id, result}, state) do
  require Logger
  Logger.info("Workstream agent completed",
    workstream_id: workstream_id,
    agent_id: agent_id)

  # Load current task state
  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

  # Calculate duration
  agent_info = Map.get(state.active_workstream_agents, workstream_id)
  duration_ms = if agent_info do
    DateTime.diff(DateTime.utc_now(), agent_info.started_at, :millisecond)
  else
    0
  end

  # Record workstream_completed event
  case Ipa.Pod.State.append_event(
    state.task_id,
    "workstream_completed",
    %{
      workstream_id: workstream_id,
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
      Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, workstream_id, agent_id)

      # Remove from tracking
      new_active = Map.delete(state.active_workstream_agents, workstream_id)

      # Post update to Communications Manager
      Ipa.Pod.CommunicationsManager.post_message(
        state.task_id,
        type: :update,
        content: "Workstream #{workstream_id} completed successfully",
        author: "scheduler"
      )

      new_state = %{state | active_workstream_agents: new_active}

      # Trigger immediate evaluation to start next workstream
      send(self(), :evaluate)
      {:noreply, %{new_state | evaluation_scheduled?: true}}

    {:error, :version_conflict} ->
      # Retry on next evaluation
      Logger.warning("Version conflict recording workstream completion")
      send(self(), :evaluate)
      {:noreply, %{state | evaluation_scheduled?: true}}

    {:error, reason} ->
      Logger.error("Failed to record workstream completion", error: reason)
      {:noreply, state}
  end
end

def handle_info({:workstream_agent_failed, workstream_id, agent_id, error}, state) do
  require Logger
  Logger.error("Workstream agent failed",
    workstream_id: workstream_id,
    agent_id: agent_id,
    error: error)

  # Load current task state
  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

  # Record workstream_failed event
  Ipa.Pod.State.append_event(
    state.task_id,
    "workstream_failed",
    %{
      workstream_id: workstream_id,
      agent_id: agent_id,
      error: inspect(error),
      failed_at: DateTime.utc_now() |> DateTime.to_unix()
    },
    task_state.version,
    actor_id: "scheduler"
  )

  # Cleanup workspace
  Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, workstream_id, agent_id)

  # Post blocker to Communications Manager
  Ipa.Pod.CommunicationsManager.post_message(
    state.task_id,
    type: :blocker,
    content: "Workstream #{workstream_id} failed: #{inspect(error)}",
    author: "scheduler",
    workstream_id: workstream_id
  )

  # Remove from tracking
  new_active = Map.delete(state.active_workstream_agents, workstream_id)

  new_state = %{state | active_workstream_agents: new_active}

  # Trigger re-evaluation
  send(self(), :evaluate)
  {:noreply, %{new_state | evaluation_scheduled?: true}}
end
```

**FIX P0#3: Workstream Failure Handling and Cascade Logic**

When a workstream fails, the scheduler must identify dependent workstreams and provide recovery options.

**Updated handle_info for workstream_agent_failed**:

```elixir
def handle_info({:workstream_agent_failed, workstream_id, agent_id, error}, state) do
  require Logger
  Logger.error("Workstream agent failed",
    workstream_id: workstream_id,
    agent_id: agent_id,
    error: error)

  {:ok, task_state} = Ipa.Pod.State.get_state(state.task_id)

  # FIX P0#3: Identify dependent workstreams
  affected_workstreams = find_affected_workstreams(workstream_id, task_state.workstreams)

  # Record workstream_failed event
  Ipa.Pod.State.append_event(
    state.task_id,
    "workstream_failed",
    %{
      workstream_id: workstream_id,
      agent_id: agent_id,
      error: inspect(error),
      failed_at: DateTime.utc_now() |> DateTime.to_unix(),
      affected_workstreams: Enum.map(affected_workstreams, & &1.workstream_id)
    },
    task_state.version,
    actor_id: "scheduler"
  )

  # Cleanup workspace
  Ipa.Pod.WorkspaceManager.cleanup_workspace(state.task_id, workstream_id, agent_id)

  # FIX P0#3: Post comprehensive blocker
  Ipa.Pod.CommunicationsManager.post_message(
    state.task_id,
    type: :blocker,
    content: "Workstream #{workstream_id} failed: #{inspect(error)}. #{length(affected_workstreams)} dependent workstream(s) affected.",
    author: "scheduler",
    workstream_id: workstream_id
  )

  # FIX P0#3: Request recovery approval
  Ipa.Pod.CommunicationsManager.request_approval(
    state.task_id,
    question: "Workstream #{workstream_id} failed. How should we proceed?",
    options: ["Retry", "Skip and continue", "Cancel task", "Manual fix"],
    author: "scheduler",
    workstream_id: workstream_id,
    blocking?: true
  )

  new_active = Map.delete(state.active_workstream_agents, workstream_id)
  send(self(), :evaluate)
  {:noreply, %{state | active_workstream_agents: new_active, evaluation_scheduled?: true}}
end

# FIX P0#3: Find dependent workstreams
defp find_affected_workstreams(failed_ws_id, workstreams) do
  workstreams
  |> Map.values()
  |> Enum.filter(fn ws ->
    failed_ws_id in ws.dependencies && ws.status not in [:completed, :failed]
  end)
end
```

**Summary of P0#3 Fix**:
1. ✅ Identify affected workstreams in failure handler
2. ✅ Track cascade in workstream_failed event
3. ✅ Post blocker message with impact info
4. ✅ Request approval for recovery strategy (retry, skip, cancel, manual)

### 10. Add Communications Integration

**When to Post Messages**:

```elixir
# Update on workstream start
def spawn_workstream_agent(...) do
  # After successful spawn
  Ipa.Pod.CommunicationsManager.post_message(
    task_id,
    type: :update,
    content: "Started workstream: #{workstream.title}",
    author: "scheduler",
    workstream_id: workstream.workstream_id
  )
end

# Update on workstream completion
def handle_info({:workstream_agent_completed, workstream_id, ...}, state) do
  Ipa.Pod.CommunicationsManager.post_message(
    task_id,
    type: :update,
    content: "Completed workstream: #{workstream.title}",
    author: "scheduler",
    workstream_id: workstream_id
  )
end

# Blocker on workstream failure
def handle_info({:workstream_agent_failed, workstream_id, ...}, state) do
  Ipa.Pod.CommunicationsManager.post_message(
    task_id,
    type: :blocker,
    content: "Workstream #{workstream_id} failed: #{error}",
    author: "scheduler",
    workstream_id: workstream_id
  )
end

# Question if planning fails
def evaluate_planning(task_state, scheduler_state) do
  # If planning agent fails multiple times
  if has_multiple_planning_failures?(task_state) do
    Ipa.Pod.CommunicationsManager.post_message(
      task_state.task_id,
      type: :question,
      content: "Planning agent has failed multiple times. Should we try a different approach?",
      author: "scheduler"
    )
  end
end
```

### 11. Update State Machine Evaluation

**New `evaluate_state_machine/2`**:

```elixir
defp evaluate_state_machine(task_state, scheduler_state) do
  case task_state.phase do
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
  end
end
```

### 12. Update Action Execution

**New Actions**:

```elixir
defp execute_action(action, task_state, scheduler_state) do
  case action do
    {:spawn_planning_agent, prompt} ->
      spawn_planning_agent(prompt, task_state, scheduler_state)

    {:spawn_workstream_agent, workstream} ->
      spawn_workstream_agent(workstream, task_state, scheduler_state)

    {:create_workstreams} ->
      create_workstreams_from_plan(task_state.plan, task_state, scheduler_state)

    {:transition, to_phase, reason} ->
      request_transition(to_phase, reason, task_state, scheduler_state)

    {:wait, reason} ->
      Logger.info("Scheduler waiting", task_id: task_state.task_id, reason: reason)
      enter_cooldown(scheduler_state, :wait)

    {:approve_required, item} ->
      Logger.info("Approval required", task_id: task_state.task_id, item: item)
      enter_cooldown(scheduler_state, :approval)
  end
end
```

### 13. Update Configuration

**New Config Options**:

```elixir
# config/config.exs
config :ipa, Ipa.Pod.Scheduler,
  # Workstream settings
  max_workstream_concurrency: 3,          # Max concurrent workstreams
  max_workstream_runtime_minutes: 120,    # Max runtime per workstream

  # Cooldown durations (milliseconds)
  cooldown_after_workstream_spawn: 10_000,
  cooldown_after_workstream_complete: 15_000,
  cooldown_after_transition: 30_000,
  cooldown_default: 30_000,

  # Evaluation settings
  enable_auto_transitions: true,
  require_approval_for_transitions: true
```

### 14. Remove/Deprecate Old Functions

**Functions to Remove**:
- `evaluate_spec_clarification/2`
- `generate_spec_prompt/1`
- `generate_plan_prompt/1` (replace with planning agent prompt)
- `generate_dev_prompt/1` (replace with workstream agent prompt)
- `generate_fix_prompt/1` (handled at workstream level)
- `generate_test_fix_prompt/1` (handled at workstream level)
- `generate_pr_prompt/1` (simplify for review phase)
- `no_active_agents?/1` (replace with workstream-based checks)
- `max_agents_reached?/1` (replace with `max_workstreams_reached?/2`)
- Old state machine helper functions (implementation_complete?, tests_passing?, etc.)

**Functions to Keep (but simplify)**:
- `evaluate_review/2` - Simplify to just PR creation and merge detection
- `generate_pr_prompt/1` - Keep for review phase
- `generate_pr_comment_prompt/1` - Keep for PR comment resolution

### 15. Update Review Phase

**Simplified Review Logic**:

```elixir
defp evaluate_review(task_state, scheduler_state) do
  cond do
    # PR merged → transition to completed
    pr_merged?(task_state) ->
      {:transition, :completed, "PR merged"}

    # No PR created → spawn PR agent
    !pr_created?(task_state) && no_pr_agent_running?(scheduler_state) ->
      {:spawn_pr_agent, generate_pr_prompt(task_state)}

    # PR has unresolved comments → spawn comment resolver
    pr_has_comments?(task_state) && no_pr_agent_running?(scheduler_state) ->
      {:spawn_pr_comment_resolver, generate_pr_comment_prompt(task_state)}

    # Waiting for PR review → wait
    pr_created?(task_state) ->
      {:approve_required, :pr_review}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end
```

**Note**: Review phase still uses a single agent for PR operations, not workstream-based.

**FIX P0#6: PR Consolidation for Multi-Workstream Tasks**

**Issue**: When multiple workstreams complete, each has its own workspace with separate commits. The review phase must consolidate all changes into a single cohesive PR. The current spec doesn't explain this process.

**Consolidation Strategy**:

Option 1: **Workspace Merge Approach** (Recommended)
- Each workstream agent commits changes to its own workspace
- PR agent creates a new consolidated workspace
- PR agent cherry-picks or merges commits from all workstream workspaces
- PR agent creates single PR with all changes

Option 2: **Shared Branch Approach**
- All workstream agents work on the same shared branch (via git config)
- Each workstream commits with workstream-specific commit messages
- PR agent simply creates PR from the shared branch

**Recommended Implementation (Option 1)**:

```elixir
defp evaluate_review(task_state, scheduler_state) do
  cond do
    # PR merged → transition to completed
    pr_merged?(task_state) ->
      {:transition, :completed, "PR merged"}

    # FIX P0#6: No PR created → spawn PR consolidation agent
    !pr_created?(task_state) && no_pr_agent_running?(scheduler_state) ->
      {:spawn_pr_agent, generate_pr_consolidation_prompt(task_state)}

    # PR has unresolved comments → spawn comment resolver
    pr_has_comments?(task_state) && no_pr_agent_running?(scheduler_state) ->
      {:spawn_pr_comment_resolver, generate_pr_comment_prompt(task_state)}

    # Waiting for PR review → wait
    pr_created?(task_state) ->
      {:approve_required, :pr_review}

    # Default → wait
    true ->
      {:wait, :no_action_needed}
  end
end

# FIX P0#6: Generate PR consolidation prompt
defp generate_pr_consolidation_prompt(task_state) do
  workstream_summaries = task_state.workstreams
    |> Map.values()
    |> Enum.filter(fn ws -> ws.status == :completed end)
    |> Enum.map(fn ws ->
      """
      ## Workstream: #{ws.workstream_id}
      **Title**: #{ws.title || "Untitled"}
      **Workspace**: #{ws.workspace}
      **Agent**: #{ws.agent_id}
      **Spec**: #{ws.spec}
      **Result**: #{inspect(ws.result)}
      """
    end)
    |> Enum.join("\n\n")

  """
  # Task: #{task_state.title}

  ## Your Role
  You are the PR consolidation agent. Your job is to:
  1. Review changes from all completed workstreams
  2. Consolidate all changes into a single coherent PR
  3. Write a comprehensive PR description
  4. Create the PR on GitHub

  ## Task Spec
  #{task_state.spec}

  ## Completed Workstreams
  #{workstream_summaries}

  ## Instructions

  ### Step 1: Set up consolidated workspace
  ```bash
  cd ./work
  git checkout main
  git pull origin main
  git checkout -b task-#{task_state.task_id}
  ```

  ### Step 2: Review and merge workstream changes
  For each workstream workspace above:
  1. Navigate to the workstream workspace directory
  2. Review the commits: `git log`
  3. Review the changes: `git diff main`
  4. Cherry-pick or merge the commits into your consolidated branch:
     ```bash
     # Option A: Cherry-pick specific commits
     git cherry-pick <commit-hash>

     # Option B: Merge all changes
     git merge <workstream-branch>
     ```
  5. Resolve any merge conflicts if they arise
  6. Ensure tests pass after each merge

  ### Step 3: Consolidate commit history
  Consider squashing or organizing commits into logical groups:
  ```bash
  git rebase -i main
  ```

  ### Step 4: Run full test suite
  ```bash
  # Run all tests to ensure nothing broke
  mix test
  ```

  ### Step 5: Create PR
  Write a comprehensive PR description that:
  - Summarizes the overall task goal
  - Lists all workstreams and what each accomplished
  - Notes any important architectural decisions
  - Includes testing instructions

  ```bash
  gh pr create --title "#{task_state.title}" --body "$(cat pr_description.md)"
  ```

  ### Step 6: Record PR URL
  Update the tracker with the PR URL so the scheduler knows the PR was created.

  ## Important Notes
  - Work in the `./work` directory (the main project repository)
  - Workstream workspaces are at: `./workstreams/<workstream_id>/work`
  - Resolve conflicts carefully - workstreams may have touched overlapping code
  - The PR should be a single cohesive change, not just a dump of commits
  - Ensure commit messages follow project conventions
  - Tag the PR with relevant labels

  Begin consolidating the workstreams now.
  """
end
```

**Workspace Structure**:
```
/ipa/workspaces/
  task-123/                          # Pod-level workspace
    workstreams/
      ws-1/                          # Workstream 1 workspace
        work/                        # Git repo with ws-1 changes
      ws-2/                          # Workstream 2 workspace
        work/                        # Git repo with ws-2 changes
    pr-agent/                        # PR consolidation workspace
      work/                          # Git repo for consolidation
```

**Workstream Agent Git Workflow**:
Each workstream agent should:
1. Work in its own workspace: `./work`
2. Create feature branch: `git checkout -b ws-<workstream_id>`
3. Make commits as it works
4. Tracker records final commit hash when complete

**PR Agent Git Workflow**:
1. Create consolidated workspace
2. Check out main branch
3. Create task branch: `task-<task_id>`
4. For each workstream:
   - Add workstream workspace as remote: `git remote add ws-1 ../workstreams/ws-1/work`
   - Fetch: `git fetch ws-1`
   - Cherry-pick or merge: `git cherry-pick ws-1/ws-1` or `git merge ws-1/ws-1`
5. Resolve conflicts
6. Run tests
7. Create PR

**Alternative: Shared Repository Approach**:
If workspace management is complex, use a simpler shared repository approach:
- All workstream agents work on the same git repository
- Each creates its own feature branch: `ws-1`, `ws-2`, etc.
- PR agent merges all branches into a single `task-<id>` branch
- Creates PR from `task-<id>` branch

**Summary of P0#6 Fix**:
1. ✅ Defined PR consolidation strategy (workspace merge approach)
2. ✅ Created `generate_pr_consolidation_prompt/1` with detailed instructions
3. ✅ Documented workspace structure for multi-workstream tasks
4. ✅ Specified git workflow for workstream agents and PR agent
5. ✅ Provided alternative shared repository approach
6. ✅ Clarified that review phase uses single agent to consolidate all changes

**Note**: Review phase still uses a single agent for PR operations, not workstream-based.

## Testing Updates

### New Unit Tests Required

1. **Workstream Planning Tests**:
   - Test planning agent spawning
   - Test workstream creation from plan
   - Test plan approval workflow

2. **Workstream Orchestration Tests**:
   - Test workstream agent spawning
   - Test dependency resolution (blocking_on logic)
   - Test concurrency limits (max_workstream_concurrency)
   - Test workstream completion updates blocking_on for dependents
   - Test all workstreams completed → transition to review

3. **CLAUDE.md Generation Tests**:
   - Test CLAUDE.md generation before workspace creation
   - Test workspace creation with CLAUDE.md injection

4. **Communications Integration Tests**:
   - Test update messages on workstream start/complete
   - Test blocker messages on workstream failure
   - Test question messages on planning issues

5. **Multi-Workstream Tests**:
   - Test 3 workstreams running concurrently
   - Test workstream waiting for dependency
   - Test workstream priority (dependency count)

### Integration Tests

1. Test full workstream lifecycle:
   - planning → workstream creation → workstream execution → all complete → review
2. Test parallel workstream execution (3 concurrent)
3. Test dependent workstream unblocking
4. Test workstream failure and blocker reporting
5. Test communications integration (messages, approvals)

## Migration Notes

**Breaking Changes**:
1. State machine logic completely rewritten
2. GenServer state structure changed (active_workstream_agents)
3. Different phases: spec_clarification removed, workstream_execution added
4. Different events: workstream_agent_started, workstream_completed, etc.
5. Requires Components 2.7 (Communications) and 2.8 (CLAUDE.md Templates)

**Backward Compatibility**: None. This is a complete rewrite of the orchestration logic.

## Implementation Checklist

### Phase 1: Planning Logic (Week 1)
- [ ] Remove old spec_clarification phase logic
- [ ] Implement new `evaluate_planning/2` with workstream breakdown
- [ ] Implement `generate_planning_agent_prompt/1`
- [ ] Implement `create_workstreams_from_plan/2`
- [ ] Write unit tests for planning logic
- [ ] Integration test: planning → workstream creation

### Phase 2: Workstream Orchestration (Week 2)
- [ ] Implement `evaluate_workstream_execution/2`
- [ ] Implement `spawn_workstream_agent/3`
- [ ] Implement `generate_workstream_agent_prompt/2`
- [ ] Implement dependency helpers (`find_ready_workstream/2`, etc.)
- [ ] Update GenServer state structure
- [ ] Implement workstream agent lifecycle handlers
- [ ] Write unit tests for orchestration logic
- [ ] Integration test: workstream spawn → complete

### Phase 3: Integration (Week 3)
- [ ] Integrate with Component 2.8 (CLAUDE.md generation)
- [ ] Integrate with Component 2.7 (Communications)
- [ ] Update `execute_action/3` with new action types
- [ ] Update configuration options
- [ ] Write integration tests (multi-workstream, dependencies)

### Phase 4: Review & Testing (Week 4)
- [ ] Simplify review phase logic
- [ ] Remove deprecated functions
- [ ] Write comprehensive test suite
- [ ] Performance testing (3+ concurrent workstreams)
- [ ] Update tracker.md with progress
- [ ] Get spec review from architecture-strategist

## Estimated Effort

**Original**: 1 week
**Additional**: 3 weeks (complete orchestration rewrite)
**Total**: 4 weeks

**Breakdown**:
- Week 1: Planning logic and workstream creation
- Week 2: Workstream orchestration and agent lifecycle
- Week 3: Integration with 2.7 and 2.8
- Week 4: Testing and polish

## Dependencies

**Blocks**:
- Cannot implement until 2.2 (Pod State Manager) is refactored with workstream projections
- Cannot implement until 2.7 (Communications Manager) is complete
- Cannot implement until 2.8 (CLAUDE.md Templates) is complete

**Used By**:
- Pod LiveView UI (2.6) - displays workstream progress
- External Sync (2.5) - reports workstream completion to GitHub/JIRA

## Architecture Rationale

### Why Workstream Orchestration?

**Problems with Single-Agent Model**:
- Sequential execution is slow (spec → plan → dev → review)
- One agent can't handle complex tasks efficiently
- No parallelization of independent work
- Agent gets stuck context-switching between subtasks

**Benefits of Workstream Model**:
- **Parallel Execution**: Multiple workstreams run concurrently
- **Clear Boundaries**: Each workstream has focused scope
- **Better Context**: Each agent has specific CLAUDE.md for their workstream
- **Dependency Management**: Explicit dependencies ensure correct order
- **Easier Debugging**: Isolate failures to specific workstream
- **Human Oversight**: Can monitor/approve individual workstreams

### Why Scheduler as Orchestrator?

The Scheduler is the perfect place for orchestration because:
1. It already has state machine logic
2. It already manages agent lifecycle
3. It already subscribes to state changes
4. It can react to workstream completion and spawn next workstream
5. It has access to all task state and can make global decisions

## Examples

### Example: Workstream Plan for "Implement User Authentication"

```json
{
  "workstreams": [
    {
      "id": "ws-1",
      "title": "Set up database schema",
      "description": "Create users table with email, password_hash, created_at columns. Write migration.",
      "dependencies": [],
      "estimated_hours": 4
    },
    {
      "id": "ws-2",
      "title": "Implement authentication service",
      "description": "Create auth service with signup, login, logout functions. Use bcrypt for password hashing.",
      "dependencies": ["ws-1"],
      "estimated_hours": 8
    },
    {
      "id": "ws-3",
      "title": "Create API endpoints",
      "description": "Implement /signup, /login, /logout endpoints. Add authentication middleware.",
      "dependencies": ["ws-2"],
      "estimated_hours": 6
    },
    {
      "id": "ws-4",
      "title": "Add frontend components",
      "description": "Create signup and login forms. Add session management to frontend.",
      "dependencies": ["ws-3"],
      "estimated_hours": 10
    },
    {
      "id": "ws-5",
      "title": "Write tests",
      "description": "Unit tests for auth service, integration tests for API, E2E tests for login flow.",
      "dependencies": ["ws-2", "ws-3", "ws-4"],
      "estimated_hours": 8
    }
  ]
}
```

**Execution Order**:
1. Start ws-1 immediately (no dependencies)
2. Start ws-2 after ws-1 completes
3. Start ws-3 after ws-2 completes
4. Start ws-4 after ws-3 completes
5. Start ws-5 after ws-2, ws-3, ws-4 all complete

**Parallelization Opportunity**: Limited in this example due to linear dependencies. But with max_concurrency=3, as soon as ws-1 completes, ws-2 can start while ws-1's agent is being cleaned up.

### Example: More Parallel Workstreams

```json
{
  "workstreams": [
    {
      "id": "ws-1",
      "title": "Set up database schema",
      "dependencies": [],
      "estimated_hours": 4
    },
    {
      "id": "ws-2",
      "title": "Create API documentation",
      "dependencies": [],
      "estimated_hours": 3
    },
    {
      "id": "ws-3",
      "title": "Set up CI/CD pipeline",
      "dependencies": [],
      "estimated_hours": 5
    },
    {
      "id": "ws-4",
      "title": "Implement core business logic",
      "dependencies": ["ws-1"],
      "estimated_hours": 12
    },
    {
      "id": "ws-5",
      "title": "Create API endpoints",
      "dependencies": ["ws-1", "ws-4"],
      "estimated_hours": 8
    }
  ]
}
```

**Execution with max_concurrency=3**:
- Time 0: Start ws-1, ws-2, ws-3 (all 3 slots used)
- Time 3h: ws-2 completes → wait (no ready workstreams)
- Time 4h: ws-1 completes → start ws-4 (3 slots used: ws-3, ws-4, empty slot)
- Time 5h: ws-3 completes → wait (no ready workstreams)
- Time 16h: ws-4 completes → start ws-5
- Time 24h: ws-5 completes → all done

## Notes

- This is the **most complex** component in the entire system
- Orchestration engine must be **robust** and **well-tested**
- Dependency resolution is **critical** - bugs here will block entire tasks
- Communications integration is **essential** for human oversight
- CLAUDE.md generation ensures agents have proper context
- Concurrency limits prevent resource exhaustion
- The Scheduler is **reactive**, not proactive - responds to state changes
- All orchestration decisions are **deterministic** - same state → same action
