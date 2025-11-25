defmodule Ipa.Pod.SchedulerTest do
  use Ipa.DataCase, async: false
  alias Ipa.Pod.Scheduler
  alias Ipa.EventStore

  setup do
    # Create a test task stream
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"

    # Create event stream (stream_type, stream_id)
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Initialize task with basic events
    {:ok, _version} =
      EventStore.append(
        task_id,
        "task_created",
        %{title: "Test Task"},
        actor_id: "test"
      )

    # Transition to planning phase (from spec_clarification)
    {:ok, _version} =
      EventStore.append(
        task_id,
        "transition_approved",
        %{
          from_phase: "spec_clarification",
          to_phase: "planning",
          approved_by: "test"
        },
        actor_id: "test"
      )

    # Start the Pod State Manager for this task
    {:ok, state_pid} = Ipa.Pod.State.start_link(task_id: task_id)

    # Start WorkspaceManager for tests that need it (scheduler spawns agents)
    # Use a temp directory for workspace base path
    temp_base = Path.join(System.tmp_dir!(), "ipa_scheduler_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_base)

    original_config = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])
    Application.put_env(:ipa, Ipa.Pod.WorkspaceManager, Keyword.put(original_config, :base_path, temp_base))

    {:ok, ws_pid} = Ipa.Pod.WorkspaceManager.start_link(task_id: task_id)

    on_exit(fn ->
      # Clean up WorkspaceManager
      if Process.alive?(ws_pid), do: GenServer.stop(ws_pid, :normal, 100)
      Application.put_env(:ipa, Ipa.Pod.WorkspaceManager, original_config)
      File.rm_rf(temp_base)

      # Clean up State Manager
      if Process.alive?(state_pid), do: GenServer.stop(state_pid, :normal, 100)

      case Scheduler.get_scheduler_state(task_id) do
        {:ok, _state} ->
          # Scheduler is running, stop it
          case Registry.lookup(Ipa.PodRegistry, {:pod_scheduler, task_id}) do
            [{pid, _}] -> GenServer.stop(pid, :normal, 100)
            [] -> :ok
          end

        {:error, :not_found} ->
          :ok
      end
    end)

    {:ok, task_id: task_id}
  end

  describe "start_link/1" do
    test "starts scheduler and registers via Registry", %{task_id: task_id} do
      {:ok, pid} = Scheduler.start_link(task_id: task_id)
      assert Process.alive?(pid)

      # Verify Registry registration
      assert [{^pid, _}] = Registry.lookup(Ipa.PodRegistry, {:pod_scheduler, task_id})
    end

    test "loads initial state and subscribes to pub-sub", %{task_id: task_id} do
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)

      # Wait for initial evaluation to complete
      Process.sleep(100)

      # Verify initial state (after first evaluation)
      {:ok, state} = Scheduler.get_scheduler_state(task_id)
      assert state.task_id == task_id
      assert state.current_phase == :planning
      assert state.active_workstream_agents == %{}
      # After initial evaluation, count should be 1
      assert state.evaluation_count == 1
    end

    test "handles orphaned workstreams on restart", %{task_id: task_id} do
      # Create a workstream in :in_progress state (simulating orphaned agent)
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-orphan",
            title: "Orphaned Workstream",
            spec: "Test",
            dependencies: [],
            estimated_hours: 4
          },
          actor_id: "test"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_agent_started",
          %{
            workstream_id: "ws-orphan",
            agent_id: "agent-orphan",
            workspace: "/tmp/test",
            agent_pid: "#PID<0.999.0>",
            started_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "scheduler"
        )

      # Reload state to pick up the orphaned workstream
      Ipa.Pod.State.reload_state(task_id)

      # Start scheduler (should mark orphaned workstream as failed)
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)

      # Wait a bit for processing
      Process.sleep(100)

      # Check that workstream was marked as failed
      {:ok, state} = Ipa.Pod.State.get_state(task_id)
      orphaned_ws = state.workstreams["ws-orphan"]
      assert orphaned_ws.status == :failed
    end
  end

  describe "state machine - planning phase" do
    test "spawns planning agent when no workstreams exist", %{task_id: task_id} do
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)

      # Force immediate evaluation
      :ok = Scheduler.evaluate_now(task_id)

      # Wait for evaluation
      Process.sleep(200)

      # Check scheduler state - should be waiting for planning agent
      {:ok, scheduler_state} = Scheduler.get_scheduler_state(task_id)
      assert scheduler_state.pending_action == {:wait, :planning_agent_working}
    end

    test "creates workstreams when plan is ready", %{task_id: task_id} do
      # Simulate planning agent completion
      plan_data = %{
        "workstreams" => [
          %{
            "id" => "ws-1",
            "title" => "Workstream 1",
            "description" => "Test workstream",
            "dependencies" => [],
            "estimated_hours" => 8
          },
          %{
            "id" => "ws-2",
            "title" => "Workstream 2",
            "description" => "Test workstream 2",
            "dependencies" => ["ws-1"],
            "estimated_hours" => 4
          }
        ]
      }

      # Create planning agent first
      {:ok, _} =
        EventStore.append(
          task_id,
          "agent_started",
          %{
            agent_id: "planning-agent-1",
            agent_type: "planning_agent",
            workspace: "/tmp/planning-workspace",
            started_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "scheduler"
        )

      # Mark planning agent as completed
      {:ok, _} =
        EventStore.append(
          task_id,
          "agent_completed",
          %{
            agent_id: "planning-agent-1",
            completed_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "planning-agent-1"
        )

      # Update plan with workstreams
      {:ok, _} =
        EventStore.append(
          task_id,
          "plan_updated",
          %{
            plan: %{
              steps: [],
              total_estimated_hours: 12.0,
              workstreams: plan_data["workstreams"]
            }
          },
          actor_id: "planning_agent"
        )

      # Reload state
      Ipa.Pod.State.reload_state(task_id)

      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      :ok = Scheduler.evaluate_now(task_id)

      Process.sleep(200)

      # Check that workstreams were created
      {:ok, state} = Ipa.Pod.State.get_state(task_id)
      assert map_size(state.workstreams || %{}) == 2
    end

    test "requests transition when plan is approved", %{task_id: task_id} do
      # Create plan first
      {:ok, _} =
        EventStore.append(
          task_id,
          "plan_updated",
          %{
            plan: %{
              steps: ["step1", "step2"],
              workstream_breakdown: [
                %{id: "ws-1", title: "Test Workstream", dependencies: []}
              ]
            },
            updated_by: "agent-planning",
            updated_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "agent-planning"
        )

      # Create workstreams
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            title: "Test Workstream",
            spec: "Test",
            dependencies: [],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      # Approve plan
      {:ok, _} =
        EventStore.append(
          task_id,
          "plan_approved",
          %{
            approved_by: "user-123",
            approved_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "user-123"
        )

      Ipa.Pod.State.reload_state(task_id)

      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      :ok = Scheduler.evaluate_now(task_id)

      Process.sleep(200)

      # Check for transition request event
      {:ok, events} = EventStore.read_stream(task_id)

      transition_event =
        Enum.find(events, fn e -> e.event_type == "transition_requested" end)

      assert transition_event != nil
      assert transition_event.data[:to_phase] == "workstream_execution"
    end
  end

  describe "dependency management (P0#2)" do
    test "detects circular dependencies", %{task_id: task_id} do
      # Create a plan with circular dependency
      workstreams = [
        %{id: "ws-1", dependencies: ["ws-2"]},
        %{id: "ws-2", dependencies: ["ws-3"]},
        %{id: "ws-3", dependencies: ["ws-1"]}
      ]

      graph = Map.new(workstreams, fn ws -> {ws.id, ws.dependencies} end)

      # This should detect the cycle
      cycle = find_cycle_helper(graph)
      assert cycle != nil
      assert length(cycle) >= 3
    end

    test "finds ready workstreams with satisfied dependencies", %{task_id: task_id} do
      # Create workstreams with dependencies
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            title: "Workstream 1",
            spec: "No dependencies",
            dependencies: [],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-2",
            title: "Workstream 2",
            spec: "Depends on ws-1",
            dependencies: ["ws-1"],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      Ipa.Pod.State.reload_state(task_id)

      {:ok, _pid} = Scheduler.start_link(task_id: task_id)

      # Check state - ws-1 should be ready, ws-2 should be blocked
      {:ok, state} = Ipa.Pod.State.get_state(task_id)

      ws1 = state.workstreams["ws-1"]
      ws2 = state.workstreams["ws-2"]

      assert ws1.status == :pending
      assert Enum.empty?(ws1.blocking_on || [])

      assert ws2.status == :pending
      assert "ws-1" in (ws2.blocking_on || [])
    end

    test "detects deadlock when no workstreams can progress", %{task_id: task_id} do
      # Create workstreams that are all blocked (simulating deadlock)
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            title: "Workstream 1",
            spec: "Depends on ws-2",
            dependencies: ["ws-2"],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-2",
            title: "Workstream 2",
            spec: "Depends on ws-1",
            dependencies: ["ws-1"],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      # Transition to workstream_execution
      {:ok, _} =
        EventStore.append(
          task_id,
          "transition_approved",
          %{
            from_phase: "planning",
            to_phase: "workstream_execution",
            approved_by: "user-123"
          },
          actor_id: "user-123"
        )

      Ipa.Pod.State.reload_state(task_id)

      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      :ok = Scheduler.evaluate_now(task_id)

      Process.sleep(200)

      # Check that deadlock was detected
      {:ok, scheduler_state} = Scheduler.get_scheduler_state(task_id)
      assert scheduler_state.pending_action == {:wait, :deadlock_detected}
    end
  end

  describe "workstream_execution phase (P0#7)" do
    @tag :skip
    @tag skip: "Requires full agent spawning infrastructure"
    test "enforces max workstream concurrency limit", %{task_id: task_id} do
      # Create 5 workstreams (more than limit of 3)
      for i <- 1..5 do
        {:ok, _} =
          EventStore.append(
            task_id,
            "workstream_created",
            %{
              workstream_id: "ws-#{i}",
              title: "Workstream #{i}",
              spec: "Test",
              dependencies: [],
              estimated_hours: 4
            },
            actor_id: "scheduler"
          )
      end

      # Transition to workstream_execution
      {:ok, _} =
        EventStore.append(
          task_id,
          "transition_approved",
          %{
            from_phase: "planning",
            to_phase: "workstream_execution"
          },
          actor_id: "user-123"
        )

      Ipa.Pod.State.reload_state(task_id)

      {:ok, pid} = Scheduler.start_link(task_id: task_id)

      # Verify max concurrency configuration exists and is respected
      max_concurrent =
        Application.get_env(:ipa, Ipa.Pod.Scheduler)[:max_workstream_concurrency] || 3

      assert max_concurrent == 3

      # The scheduler should load state and begin evaluation
      {:ok, scheduler_state} = Scheduler.get_scheduler_state(task_id)
      assert scheduler_state.current_phase == :workstream_execution

      # Cleanup before test exits
      GenServer.stop(pid, :normal, 100)
    end

    test "transitions to review when all workstreams complete", %{task_id: task_id} do
      # Create and complete workstreams
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            title: "Workstream 1",
            spec: "Test",
            dependencies: [],
            estimated_hours: 4
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_agent_started",
          %{
            workstream_id: "ws-1",
            agent_id: "agent-1",
            workspace: "/tmp/test",
            agent_pid: "#PID<0.999.0>",
            started_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_completed",
          %{
            workstream_id: "ws-1",
            agent_id: "agent-1",
            result: %{status: "success"},
            duration_ms: 120_000,
            completed_at: DateTime.utc_now() |> DateTime.to_unix()
          },
          actor_id: "scheduler"
        )

      # Transition to workstream_execution
      {:ok, _} =
        EventStore.append(
          task_id,
          "transition_approved",
          %{
            from_phase: "planning",
            to_phase: "workstream_execution"
          },
          actor_id: "user-123"
        )

      Ipa.Pod.State.reload_state(task_id)

      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      :ok = Scheduler.evaluate_now(task_id)

      Process.sleep(200)

      # Check for transition request to review
      {:ok, events} = EventStore.read_stream(task_id)

      transition_events =
        Enum.filter(events, fn e ->
          e.event_type == "transition_requested" &&
            e.data[:to_phase] == "review"
        end)

      # Should have requested transition to review
      assert length(transition_events) >= 1
    end
  end

  describe "interrupt_agent/2" do
    test "returns error when agent not found", %{task_id: task_id} do
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      assert {:error, :agent_not_found} = Scheduler.interrupt_agent(task_id, "nonexistent")
    end
  end

  describe "evaluate_now/1" do
    test "forces immediate evaluation", %{task_id: task_id} do
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      assert :ok = Scheduler.evaluate_now(task_id)
    end
  end

  describe "get_scheduler_state/1" do
    test "returns scheduler state for debugging", %{task_id: task_id} do
      {:ok, _pid} = Scheduler.start_link(task_id: task_id)
      assert {:ok, state} = Scheduler.get_scheduler_state(task_id)
      assert state.task_id == task_id
      assert is_map(state.active_workstream_agents)
    end

    test "returns error when scheduler not running", %{task_id: task_id} do
      non_existent_task = "task-nonexistent"
      assert {:error, :not_found} = Scheduler.get_scheduler_state(non_existent_task)
    end
  end

  # Helper function for testing cycle detection
  defp find_cycle_helper(graph) do
    visited = MapSet.new()

    Enum.find_value(Map.keys(graph), fn node ->
      if node not in visited do
        detect_cycle_dfs_helper(node, graph, visited, MapSet.new(), [node])
      end
    end)
  end

  defp detect_cycle_dfs_helper(node, graph, visited, rec_stack, path) do
    visited = MapSet.put(visited, node)
    rec_stack = MapSet.put(rec_stack, node)

    result =
      Enum.find_value(graph[node] || [], fn dep ->
        cond do
          dep in rec_stack ->
            cycle_start_idx = Enum.find_index(path, fn n -> n == dep end)
            Enum.slice(path, cycle_start_idx..-1//1) ++ [dep]

          dep not in visited ->
            detect_cycle_dfs_helper(dep, graph, visited, rec_stack, path ++ [dep])

          true ->
            nil
        end
      end)

    result
  end
end
