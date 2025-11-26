defmodule Ipa.CentralManagerTest do
  use Ipa.DataCase, async: false

  alias Ipa.CentralManager
  alias Ipa.EventStore

  setup do
    # Clean up any pods that might be running
    on_exit(fn ->
      CentralManager.get_active_pods()
      |> Enum.each(fn task_id ->
        CentralManager.stop_pod(task_id)
        Process.sleep(50)
      end)
    end)

    :ok
  end

  describe "create_task/2" do
    test "creates a new task with event stream" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")

      assert is_binary(task_id)
      assert String.starts_with?(task_id, "task-")

      # Verify stream was created
      assert EventStore.stream_exists?(task_id)

      # Verify task_created event was appended
      {:ok, events} = EventStore.read_stream(task_id)
      assert length(events) == 1

      event = hd(events)
      assert event.event_type == "task_created"
      assert event.data["title"] == "Test Task" || event.data[:title] == "Test Task"
    end

    test "creates unique task IDs for each task" do
      {:ok, task_id1} = CentralManager.create_task("Task 1", "user-123")
      {:ok, task_id2} = CentralManager.create_task("Task 2", "user-123")

      refute task_id1 == task_id2
    end
  end

  describe "start_pod/1" do
    test "starts a pod for an existing task" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, pid} = CentralManager.start_pod(task_id)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert CentralManager.pod_running?(task_id)
    end

    test "returns error if pod already running" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, _pid} = CentralManager.start_pod(task_id)

      assert {:error, :already_started} = CentralManager.start_pod(task_id)
    end

    test "returns error if task doesn't exist" do
      assert {:error, :stream_not_found} = CentralManager.start_pod("nonexistent-task")
    end
  end

  describe "stop_pod/1" do
    test "stops a running pod" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, pid} = CentralManager.start_pod(task_id)

      assert Process.alive?(pid)
      assert :ok = CentralManager.stop_pod(task_id)

      Process.sleep(100)
      refute Process.alive?(pid)
      refute CentralManager.pod_running?(task_id)
    end

    test "returns error if pod not running" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      assert {:error, :not_running} = CentralManager.stop_pod(task_id)
    end
  end

  describe "restart_pod/1" do
    test "restarts a running pod" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, old_pid} = CentralManager.start_pod(task_id)

      Process.sleep(100)

      {:ok, new_pid} = CentralManager.restart_pod(task_id)

      assert old_pid != new_pid
      assert Process.alive?(new_pid)
      assert CentralManager.pod_running?(task_id)
    end

    test "starts pod if not running" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, pid} = CentralManager.restart_pod(task_id)

      assert is_pid(pid)
      assert CentralManager.pod_running?(task_id)
    end
  end

  describe "get_active_pods/0" do
    test "returns list of active pod task IDs" do
      {:ok, task_id1} = CentralManager.create_task("Task 1", "user-123")
      {:ok, task_id2} = CentralManager.create_task("Task 2", "user-123")

      {:ok, _} = CentralManager.start_pod(task_id1)
      {:ok, _} = CentralManager.start_pod(task_id2)

      active_pods = CentralManager.get_active_pods()

      assert task_id1 in active_pods
      assert task_id2 in active_pods
    end

    test "returns empty list when no pods running" do
      # Clear any running pods first
      CentralManager.get_active_pods()
      |> Enum.each(&CentralManager.stop_pod/1)

      Process.sleep(100)

      assert CentralManager.get_active_pods() == []
    end
  end

  describe "pod_running?/1" do
    test "returns true for running pod" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      {:ok, _pid} = CentralManager.start_pod(task_id)

      assert CentralManager.pod_running?(task_id)
    end

    test "returns false for non-running pod" do
      {:ok, task_id} = CentralManager.create_task("Test Task", "user-123")
      refute CentralManager.pod_running?(task_id)
    end

    test "returns false for nonexistent task" do
      refute CentralManager.pod_running?("nonexistent-task")
    end
  end

  describe "list_tasks/1" do
    test "returns list of tasks with summary info" do
      {:ok, task_id} = CentralManager.create_task("My Test Task", "user-123")

      tasks = CentralManager.list_tasks()

      task = Enum.find(tasks, &(&1.task_id == task_id))
      assert task != nil
      assert task.title == "My Test Task"
      assert task.phase == :spec_clarification
      assert task.pod_running == false
      assert task.workstream_count == 0
      assert task.unread_count == 0
    end

    test "shows pod_running status correctly" do
      {:ok, task_id} = CentralManager.create_task("Running Task", "user-123")
      {:ok, _pid} = CentralManager.start_pod(task_id)

      tasks = CentralManager.list_tasks()
      task = Enum.find(tasks, &(&1.task_id == task_id))

      assert task.pod_running == true
    end

    test "tracks workstream count" do
      {:ok, task_id} = CentralManager.create_task("Task with Workstreams", "user-123")

      # Add workstream events
      {:ok, _} = EventStore.append(
        task_id,
        "workstream_created",
        %{workstream_id: "ws-1", title: "Workstream 1"},
        actor_id: "scheduler"
      )

      {:ok, _} = EventStore.append(
        task_id,
        "workstream_created",
        %{workstream_id: "ws-2", title: "Workstream 2"},
        actor_id: "scheduler"
      )

      tasks = CentralManager.list_tasks()
      task = Enum.find(tasks, &(&1.task_id == task_id))

      assert task.workstream_count == 2
    end

    test "filters out completed tasks by default" do
      {:ok, task_id} = CentralManager.create_task("Completed Task", "user-123")

      # Mark task as completed
      {:ok, _} = EventStore.append(
        task_id,
        "task_completed",
        %{completed_at: System.system_time(:second)},
        actor_id: "user-123"
      )

      tasks = CentralManager.list_tasks()
      task = Enum.find(tasks, &(&1.task_id == task_id))

      assert task == nil
    end

    test "includes completed tasks when option set" do
      {:ok, task_id} = CentralManager.create_task("Completed Task", "user-123")

      {:ok, _} = EventStore.append(
        task_id,
        "task_completed",
        %{completed_at: System.system_time(:second)},
        actor_id: "user-123"
      )

      tasks = CentralManager.list_tasks(include_completed: true)
      task = Enum.find(tasks, &(&1.task_id == task_id))

      assert task != nil
      assert task.phase == :completed
    end

    test "respects limit option" do
      # Create multiple tasks
      for i <- 1..5 do
        CentralManager.create_task("Task #{i}", "user-123")
      end

      tasks = CentralManager.list_tasks(limit: 3)
      assert length(tasks) <= 3
    end
  end

  describe "get_task/1" do
    test "returns task info for existing task" do
      {:ok, task_id} = CentralManager.create_task("Get Task Test", "user-123")

      {:ok, task} = CentralManager.get_task(task_id)

      assert task.task_id == task_id
      assert task.title == "Get Task Test"
      assert task.phase == :spec_clarification
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = CentralManager.get_task("nonexistent-task")
    end
  end

  describe "count_active_pods/0" do
    test "returns count of running pods" do
      initial_count = CentralManager.count_active_pods()

      {:ok, task_id1} = CentralManager.create_task("Task 1", "user-123")
      {:ok, task_id2} = CentralManager.create_task("Task 2", "user-123")

      {:ok, _} = CentralManager.start_pod(task_id1)
      {:ok, _} = CentralManager.start_pod(task_id2)

      assert CentralManager.count_active_pods() >= initial_count + 2
    end
  end

  describe "phase transitions" do
    test "list_tasks reflects phase changes" do
      {:ok, task_id} = CentralManager.create_task("Phase Test", "user-123")

      # Transition to planning
      {:ok, _} = EventStore.append(
        task_id,
        "transition_approved",
        %{from_phase: "spec_clarification", to_phase: "planning", approved_by: "user-123"},
        actor_id: "user-123"
      )

      tasks = CentralManager.list_tasks()
      task = Enum.find(tasks, &(&1.task_id == task_id))

      assert task.phase == :planning
    end
  end
end
