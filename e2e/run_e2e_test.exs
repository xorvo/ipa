# E2E Test Script: Task Lifecycle
#
# This script tests the complete task lifecycle from creation to planning phase.
# It uses the IPA API directly (not browser) for automated testing.
#
# Run with: mix run e2e/run_e2e_test.exs
#
# Prerequisites:
#   - PostgreSQL running
#   - Application started (or use --no-start for just API tests)

defmodule E2ETest.TaskLifecycle do
  @moduledoc """
  End-to-end test for the complete task lifecycle.
  """

  require Logger

  def run do
    Logger.info("=" |> String.duplicate(60))
    Logger.info("E2E TEST: Task Lifecycle")
    Logger.info("=" |> String.duplicate(60))

    # Ensure Ecto is started
    {:ok, _} = Application.ensure_all_started(:ecto)

    # Test phases
    results = [
      test_task_creation(),
      test_spec_workflow(),
      test_transition_to_planning(),
      test_pod_start_stop()
    ]

    # Summary
    Logger.info("")
    Logger.info("=" |> String.duplicate(60))
    Logger.info("TEST SUMMARY")
    Logger.info("=" |> String.duplicate(60))

    passed = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)

    Enum.each(results, fn {status, name} ->
      icon = if status == :ok, do: "[PASS]", else: "[FAIL]"
      Logger.info("#{icon} #{name}")
    end)

    Logger.info("")
    Logger.info("Results: #{passed} passed, #{failed} failed")
    Logger.info("=" |> String.duplicate(60))

    if failed > 0 do
      System.halt(1)
    end
  end

  # ==========================================================================
  # Test: Task Creation
  # ==========================================================================

  defp test_task_creation do
    name = "Task Creation"
    Logger.info("")
    Logger.info("[TEST] #{name}")
    Logger.info("-" |> String.duplicate(40))

    try do
      # Create a new task
      title = "E2E Test Task #{System.system_time(:second)}"
      Logger.info("Creating task: #{title}")

      case Ipa.CentralManager.create_task(title, "e2e_test") do
        {:ok, task_id} ->
          Logger.info("  Task created: #{task_id}")

          # Verify task exists
          tasks = Ipa.CentralManager.list_tasks(include_completed: false)
          found = Enum.find(tasks, fn t -> t.task_id == task_id end)

          if found do
            Logger.info("  Task found in list: #{found.title}")
            Logger.info("  Phase: #{found.phase}")

            # Store task_id for subsequent tests
            Application.put_env(:e2e_test, :task_id, task_id)
            {:ok, name}
          else
            Logger.error("  Task not found in list!")
            {:error, name}
          end

        {:error, reason} ->
          Logger.error("  Failed to create task: #{inspect(reason)}")
          {:error, name}
      end
    rescue
      e ->
        Logger.error("  Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Test: Spec Workflow
  # ==========================================================================

  defp test_spec_workflow do
    name = "Spec Workflow"
    Logger.info("")
    Logger.info("[TEST] #{name}")
    Logger.info("-" |> String.duplicate(40))

    try do
      task_id = Application.get_env(:e2e_test, :task_id)

      if is_nil(task_id) do
        Logger.error("  No task_id from previous test")
        {:error, name}
      else
        # Update spec
        spec_description = "E2E test spec: Create a simple hello world program"
        Logger.info("  Updating spec...")

        case Ipa.EventStore.append(
               task_id,
               "spec_updated",
               %{spec: %{description: spec_description}},
               actor_id: "e2e_test"
             ) do
          {:ok, _version} ->
            Logger.info("  Spec updated successfully")

            # Approve spec
            Logger.info("  Approving spec...")

            case Ipa.EventStore.append(
                   task_id,
                   "spec_approved",
                   %{approved_by: "e2e_test", approved_at: System.system_time(:second)},
                   actor_id: "e2e_test"
                 ) do
              {:ok, _version} ->
                Logger.info("  Spec approved successfully")

                # Verify state
                {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
                spec_approved = state.spec[:approved?] || state.spec["approved?"] || false

                if spec_approved do
                  Logger.info("  Verified: spec.approved? = true")
                  {:ok, name}
                else
                  Logger.error("  Spec not marked as approved in state")
                  {:error, name}
                end

              {:error, reason} ->
                Logger.error("  Failed to approve spec: #{inspect(reason)}")
                {:error, name}
            end

          {:error, reason} ->
            Logger.error("  Failed to update spec: #{inspect(reason)}")
            {:error, name}
        end
      end
    rescue
      e ->
        Logger.error("  Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Test: Transition to Planning
  # ==========================================================================

  defp test_transition_to_planning do
    name = "Transition to Planning"
    Logger.info("")
    Logger.info("[TEST] #{name}")
    Logger.info("-" |> String.duplicate(40))

    try do
      task_id = Application.get_env(:e2e_test, :task_id)

      if is_nil(task_id) do
        Logger.error("  No task_id from previous test")
        {:error, name}
      else
        # Request transition to planning
        Logger.info("  Requesting transition to planning...")

        case Ipa.EventStore.append(
               task_id,
               "transition_requested",
               %{
                 from_phase: "spec_clarification",
                 to_phase: "planning",
                 reason: "E2E test transition"
               },
               actor_id: "e2e_test"
             ) do
          {:ok, _version} ->
            Logger.info("  Transition requested")

            # Approve transition
            Logger.info("  Approving transition...")

            case Ipa.EventStore.append(
                   task_id,
                   "transition_approved",
                   %{
                     from_phase: "spec_clarification",
                     to_phase: "planning",
                     approved_by: "e2e_test"
                   },
                   actor_id: "e2e_test"
                 ) do
              {:ok, _version} ->
                Logger.info("  Transition approved")

                # Verify state
                {:ok, state} = Ipa.Pod.State.get_state_from_events(task_id)
                phase = state.phase

                if phase == :planning do
                  Logger.info("  Verified: phase = :planning")
                  {:ok, name}
                else
                  Logger.error("  Phase is #{inspect(phase)}, expected :planning")
                  {:error, name}
                end

              {:error, reason} ->
                Logger.error("  Failed to approve transition: #{inspect(reason)}")
                {:error, name}
            end

          {:error, reason} ->
            Logger.error("  Failed to request transition: #{inspect(reason)}")
            {:error, name}
        end
      end
    rescue
      e ->
        Logger.error("  Exception: #{inspect(e)}")
        {:error, name}
    end
  end

  # ==========================================================================
  # Test: Pod Start/Stop
  # ==========================================================================

  defp test_pod_start_stop do
    name = "Pod Start/Stop"
    Logger.info("")
    Logger.info("[TEST] #{name}")
    Logger.info("-" |> String.duplicate(40))

    try do
      task_id = Application.get_env(:e2e_test, :task_id)

      if is_nil(task_id) do
        Logger.error("  No task_id from previous test")
        {:error, name}
      else
        # Start pod
        Logger.info("  Starting pod...")

        case Ipa.CentralManager.start_pod(task_id) do
          {:ok, _pid} ->
            Logger.info("  Pod started successfully")

            # Verify pod is running
            if Ipa.PodSupervisor.pod_running?(task_id) do
              Logger.info("  Verified: pod is running")

              # Stop pod
              Logger.info("  Stopping pod...")

              case Ipa.CentralManager.stop_pod(task_id) do
                :ok ->
                  Logger.info("  Pod stopped successfully")

                  # Verify pod is stopped
                  Process.sleep(100)

                  if not Ipa.PodSupervisor.pod_running?(task_id) do
                    Logger.info("  Verified: pod is stopped")
                    {:ok, name}
                  else
                    Logger.error("  Pod still running after stop")
                    {:error, name}
                  end

                {:error, reason} ->
                  Logger.error("  Failed to stop pod: #{inspect(reason)}")
                  {:error, name}
              end
            else
              Logger.error("  Pod not running after start")
              {:error, name}
            end

          {:error, reason} ->
            Logger.error("  Failed to start pod: #{inspect(reason)}")
            {:error, name}
        end
      end
    rescue
      e ->
        Logger.error("  Exception: #{inspect(e)}")
        {:error, name}
    end
  end
end

# Run the tests
E2ETest.TaskLifecycle.run()
