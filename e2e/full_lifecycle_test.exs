# Full E2E Test Script: Complete Task Lifecycle
#
# This script tests the COMPLETE task lifecycle from creation through completion.
# It includes all phases: spec_clarification -> planning -> workstream_execution -> review -> completed
#
# Run with: mix run e2e/full_lifecycle_test.exs
#
# Prerequisites:
#   - PostgreSQL running with ipa_dev database
#   - Application started

defmodule E2ETest.FullLifecycle do
  @moduledoc """
  Comprehensive end-to-end test covering the full task lifecycle.
  Tests all phases and transitions without requiring Claude Code SDK (mock agent execution).
  """

  require Logger

  @task_title "E2E Full Lifecycle Test"
  @task_description "Create a simple Python hello world script with tests"

  def run do
    print_header("E2E TEST: Full Task Lifecycle")

    # Run all test phases
    results = [
      test_phase_1_task_creation(),
      test_phase_2_spec_clarification(),
      test_phase_3_planning(),
      test_phase_4_workstream_execution(),
      test_phase_5_review(),
      test_phase_6_completion(),
      test_phase_7_cleanup()
    ]

    # Print summary
    print_summary(results)

    # Return exit code
    failed = Enum.count(results, fn {status, _} -> status == :error end)
    if failed > 0, do: System.halt(1)
  end

  # ==========================================================================
  # Phase 1: Task Creation
  # ==========================================================================

  defp test_phase_1_task_creation do
    name = "Phase 1: Task Creation"
    print_phase(name)

    try do
      title = "#{@task_title} #{System.system_time(:millisecond)}"
      Logger.info("Creating task: #{title}")

      case Ipa.CentralManager.create_task(title, "e2e_test") do
        {:ok, task_id} ->
          Logger.info("  ✓ Task created: #{task_id}")
          Application.put_env(:e2e_test, :task_id, task_id)

          # Verify task in list
          tasks = Ipa.CentralManager.list_tasks(include_completed: false)
          found = Enum.find(tasks, fn t -> t.task_id == task_id end)

          if found do
            Logger.info("  ✓ Task found in list")
            Logger.info("  ✓ Initial phase: #{found.phase}")
            {:ok, name}
          else
            Logger.error("  ✗ Task not found in list")
            {:error, name}
          end

        {:error, reason} ->
          Logger.error("  ✗ Failed to create task: #{inspect(reason)}")
          {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 2: Spec Clarification
  # ==========================================================================

  defp test_phase_2_spec_clarification do
    name = "Phase 2: Spec Clarification"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 2.1 Update spec
      Logger.info("  Updating spec...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "spec_updated",
        %{
          spec: %{
            description: @task_description,
            requirements: [
              "Python 3.x installed",
              "Create hello.py file",
              "Include greeting function",
              "Add unit tests"
            ],
            acceptance_criteria: [
              "Running `python hello.py` prints 'Hello World'",
              "All unit tests pass"
            ]
          }
        },
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Spec updated")

      # 2.2 Approve spec
      Logger.info("  Approving spec...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "spec_approved",
        %{approved_by: "e2e_test", approved_at: System.system_time(:second)},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Spec approved")

      # 2.3 Verify state
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
      if state.spec[:approved?] || state.spec["approved?"] do
        Logger.info("  ✓ State shows spec approved")
        {:ok, name}
      else
        Logger.error("  ✗ Spec not marked as approved in state")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 3: Planning
  # ==========================================================================

  defp test_phase_3_planning do
    name = "Phase 3: Planning"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 3.1 Transition to planning
      Logger.info("  Requesting transition to planning...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_requested",
        %{from_phase: "spec_clarification", to_phase: "planning", reason: "E2E test"},
        actor_id: "e2e_test"
      )

      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_approved",
        %{from_phase: "spec_clarification", to_phase: "planning", approved_by: "e2e_test"},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Transitioned to planning")

      # 3.2 Create plan with workstreams
      Logger.info("  Creating plan with workstreams...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "plan_updated",
        %{
          plan: %{
            steps: [
              %{description: "Create hello.py with greeting function", order: 1},
              %{description: "Add error handling", order: 2},
              %{description: "Create unit tests", order: 3}
            ],
            workstreams: [
              %{id: "ws-1", title: "Core Implementation", description: "Create hello.py with greeting function", dependencies: []},
              %{id: "ws-2", title: "Error Handling", description: "Add input validation and error handling", dependencies: ["ws-1"]},
              %{id: "ws-3", title: "Unit Tests", description: "Create test_hello.py with pytest tests", dependencies: ["ws-1"]}
            ],
            total_estimated_hours: 2
          }
        },
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Plan created")

      # 3.3 Approve plan
      Logger.info("  Approving plan...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "plan_approved",
        %{approved_by: "e2e_test"},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Plan approved")

      # 3.4 Create workstreams
      Logger.info("  Creating workstreams...")
      for {ws_id, spec, deps} <- [
        {"ws-1", "Create hello.py with greeting function", []},
        {"ws-2", "Add input validation and error handling", ["ws-1"]},
        {"ws-3", "Create test_hello.py with pytest tests", ["ws-1"]}
      ] do
        {:ok, _} = Ipa.EventStore.append(
          task_id,
          "workstream_created",
          %{workstream_id: ws_id, spec: spec, dependencies: deps},
          actor_id: "scheduler"
        )
        Logger.info("    ✓ Created #{ws_id}")
      end

      # 3.5 Transition to workstream_execution
      Logger.info("  Requesting transition to workstream_execution...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_requested",
        %{from_phase: "planning", to_phase: "workstream_execution", reason: "All workstreams created"},
        actor_id: "scheduler"
      )

      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_approved",
        %{from_phase: "planning", to_phase: "workstream_execution", approved_by: "e2e_test"},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Transitioned to workstream_execution")

      # Verify state
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
      ws_count = map_size(state.workstreams)

      if state.phase == :workstream_execution && ws_count == 3 do
        Logger.info("  ✓ Phase: #{state.phase}, Workstreams: #{ws_count}")
        {:ok, name}
      else
        Logger.error("  ✗ Expected workstream_execution with 3 workstreams, got #{state.phase} with #{ws_count}")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 4: Workstream Execution
  # ==========================================================================

  defp test_phase_4_workstream_execution do
    name = "Phase 4: Workstream Execution"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 4.1 Start ws-1 (no dependencies)
      Logger.info("  Starting ws-1 (no dependencies)...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "workstream_started",
        %{workstream_id: "ws-1"},
        actor_id: "scheduler"
      )

      # 4.2 Spawn agent for ws-1
      Logger.info("  Spawning agent for ws-1...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "agent_spawned",
        %{
          agent_id: "agent-ws-1-001",
          workstream_id: "ws-1",
          spawned_at: System.system_time(:second)
        },
        actor_id: "scheduler"
      )
      Logger.info("  ✓ Agent spawned for ws-1")

      # 4.3 Simulate work: workspace created
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "workspace_created",
        %{
          workstream_id: "ws-1",
          workspace_path: "/ipa/workspaces/#{task_id}/ws-1"
        },
        actor_id: "workspace_manager"
      )

      # 4.4 Complete ws-1
      Logger.info("  Completing ws-1...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "workstream_completed",
        %{
          workstream_id: "ws-1",
          result: %{
            files_created: ["hello.py"],
            commit_hash: "abc123"
          }
        },
        actor_id: "agent-ws-1-001"
      )
      Logger.info("  ✓ ws-1 completed")

      # 4.5 Check dependencies unblocked
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
      ws1_status = state.workstreams["ws-1"][:status]
      Logger.info("  ws-1 status: #{ws1_status}")

      # 4.6 Start and complete ws-2 and ws-3 (now unblocked)
      for ws_id <- ["ws-2", "ws-3"] do
        Logger.info("  Starting #{ws_id}...")
        {:ok, _} = Ipa.EventStore.append(
          task_id,
          "workstream_started",
          %{workstream_id: ws_id},
          actor_id: "scheduler"
        )

        {:ok, _} = Ipa.EventStore.append(
          task_id,
          "agent_spawned",
          %{
            agent_id: "agent-#{ws_id}-001",
            workstream_id: ws_id,
            spawned_at: System.system_time(:second)
          },
          actor_id: "scheduler"
        )

        Logger.info("  Completing #{ws_id}...")
        {:ok, _} = Ipa.EventStore.append(
          task_id,
          "workstream_completed",
          %{
            workstream_id: ws_id,
            result: %{
              files_created: [if(ws_id == "ws-2", do: "hello.py", else: "test_hello.py")],
              commit_hash: "def#{ws_id}"
            }
          },
          actor_id: "agent-#{ws_id}-001"
        )
        Logger.info("  ✓ #{ws_id} completed")
      end

      # 4.7 Verify all workstreams completed
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
      all_completed = Enum.all?(state.workstreams, fn {_id, ws} ->
        ws[:status] == :completed || ws["status"] == "completed"
      end)

      if all_completed do
        Logger.info("  ✓ All workstreams completed")
        {:ok, name}
      else
        statuses = Enum.map(state.workstreams, fn {id, ws} -> "#{id}=#{ws[:status]}" end) |> Enum.join(", ")
        Logger.error("  ✗ Not all workstreams completed: #{statuses}")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 5: Review
  # ==========================================================================

  defp test_phase_5_review do
    name = "Phase 5: Review"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 5.1 Transition to review
      Logger.info("  Requesting transition to review...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_requested",
        %{from_phase: "workstream_execution", to_phase: "review", reason: "All workstreams completed"},
        actor_id: "scheduler"
      )

      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_approved",
        %{from_phase: "workstream_execution", to_phase: "review", approved_by: "e2e_test"},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Transitioned to review")

      # 5.2 Simulate PR creation
      Logger.info("  Creating consolidated PR...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "pr_created",
        %{
          pr_url: "https://github.com/xorvo/ipa/pull/123",
          pr_number: 123,
          title: "[IPA] #{@task_title}",
          workstreams_included: ["ws-1", "ws-2", "ws-3"]
        },
        actor_id: "review_agent"
      )
      Logger.info("  ✓ PR created")

      # 5.3 Simulate PR review
      Logger.info("  Approving PR...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "pr_approved",
        %{
          pr_url: "https://github.com/xorvo/ipa/pull/123",
          approved_by: "e2e_test",
          approved_at: System.system_time(:second)
        },
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ PR approved")

      # 5.4 Simulate PR merge
      Logger.info("  Merging PR...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "pr_merged",
        %{
          pr_url: "https://github.com/xorvo/ipa/pull/123",
          merge_commit: "merge123abc",
          merged_by: "e2e_test",
          merged_at: System.system_time(:second)
        },
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ PR merged")

      # Verify state
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
      if state.phase == :review do
        Logger.info("  ✓ Phase: #{state.phase}")
        {:ok, name}
      else
        Logger.error("  ✗ Expected review phase, got #{state.phase}")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 6: Completion
  # ==========================================================================

  defp test_phase_6_completion do
    name = "Phase 6: Completion"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 6.1 Transition to completed
      Logger.info("  Requesting transition to completed...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_requested",
        %{from_phase: "review", to_phase: "completed", reason: "PR merged successfully"},
        actor_id: "scheduler"
      )

      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "transition_approved",
        %{from_phase: "review", to_phase: "completed", approved_by: "e2e_test"},
        actor_id: "e2e_test"
      )
      Logger.info("  ✓ Transitioned to completed")

      # 6.2 Mark task completed
      Logger.info("  Marking task as completed...")
      {:ok, _} = Ipa.EventStore.append(
        task_id,
        "task_completed",
        %{
          completed_at: System.system_time(:second),
          summary: "Successfully created Python hello world script with tests",
          pr_url: "https://github.com/xorvo/ipa/pull/123"
        },
        actor_id: "scheduler"
      )
      Logger.info("  ✓ Task marked as completed")

      # Verify final state
      {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)

      if state.phase == :completed do
        Logger.info("  ✓ Final phase: #{state.phase}")
        Logger.info("  ✓ Event count: #{state.version}")

        # Log summary
        Logger.info("")
        Logger.info("  === Task Lifecycle Complete ===")
        Logger.info("  Task ID: #{task_id}")
        Logger.info("  Workstreams: #{map_size(state.workstreams)}")
        Logger.info("  Messages: #{length(state.messages)}")
        Logger.info("  Agents: #{length(state.agents)}")
        {:ok, name}
      else
        Logger.error("  ✗ Expected completed phase, got #{state.phase}")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Phase 7: Cleanup
  # ==========================================================================

  defp test_phase_7_cleanup do
    name = "Phase 7: Cleanup & Verification"
    print_phase(name)

    try do
      task_id = get_task_id!()

      # 7.1 Verify task appears in completed list
      Logger.info("  Verifying task in completed list...")
      tasks = Ipa.CentralManager.list_tasks(include_completed: true)
      found = Enum.find(tasks, fn t -> t.task_id == task_id end)

      if found && found.phase == :completed do
        Logger.info("  ✓ Task found in completed list")
      else
        Logger.warning("  ! Task not found or not completed in list")
      end

      # 7.2 Verify event count
      {:ok, events} = Ipa.EventStore.read_stream(task_id)
      event_count = length(events)
      Logger.info("  ✓ Total events in stream: #{event_count}")

      # 7.3 List event types
      event_types = events |> Enum.map(& &1.event_type) |> Enum.uniq()
      Logger.info("  ✓ Event types: #{Enum.join(event_types, ", ")}")

      # 7.4 Verify state reconstruction
      {:ok, state1} = Ipa.Pod.State.get_state_from_events(task_id)
      {:ok, state2} = Ipa.Pod.State.get_state_from_events(task_id)

      if state1.version == state2.version do
        Logger.info("  ✓ State reconstruction is deterministic")
        {:ok, name}
      else
        Logger.error("  ✗ State reconstruction is NOT deterministic")
        {:error, name}
      end
    rescue
      e ->
        Logger.error("  ✗ Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp get_task_id! do
    case Application.get_env(:e2e_test, :task_id) do
      nil -> raise "No task_id set from previous test"
      task_id -> task_id
    end
  end

  defp print_header(title) do
    Logger.info("")
    Logger.info(String.duplicate("=", 70))
    Logger.info(title)
    Logger.info(String.duplicate("=", 70))
  end

  defp print_phase(name) do
    Logger.info("")
    Logger.info("[TEST] #{name}")
    Logger.info(String.duplicate("-", 50))
  end

  defp print_summary(results) do
    Logger.info("")
    Logger.info(String.duplicate("=", 70))
    Logger.info("TEST SUMMARY")
    Logger.info(String.duplicate("=", 70))

    passed = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)

    Enum.each(results, fn {status, name} ->
      icon = if status == :ok, do: "[PASS]", else: "[FAIL]"
      Logger.info("#{icon} #{name}")
    end)

    Logger.info("")
    Logger.info("Results: #{passed} passed, #{failed} failed")
    Logger.info(String.duplicate("=", 70))
  end
end

# Run the tests
E2ETest.FullLifecycle.run()
