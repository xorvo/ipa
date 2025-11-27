defmodule Ipa.PodSupervisorTest do
  use ExUnit.Case, async: false
  alias Ipa.{PodSupervisor, PodRegistry, EventStore}

  setup do
    # Set sandbox mode to shared for this test since pods spawn separate processes
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ipa.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Ipa.Repo, {:shared, self()})

    # Create a test stream for each test with timestamp and random component for uniqueness
    task_id = "test-#{System.system_time(:millisecond)}-#{:rand.uniform(1_000_000_000)}"
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Append initial task_created event (required by Pod.Manager)
    {:ok, _} = EventStore.append(task_id, "task_created", %{title: "Test Task"}, actor_id: "system")

    # Ensure pod is stopped after each test
    on_exit(fn ->
      if PodSupervisor.pod_running?(task_id) do
        PodSupervisor.stop_pod(task_id)
      end

      # Wait for cleanup to complete
      Process.sleep(50)
    end)

    {:ok, task_id: task_id}
  end

  describe "Pod Registry" do
    test "registers and looks up pods", %{task_id: task_id} do
      metadata = %{status: :starting, started_at: System.system_time(:second)}

      {:ok, _} = PodRegistry.register(task_id, metadata)
      assert {:ok, _pid, ^metadata} = PodRegistry.lookup(task_id)
    end

    test "prevents duplicate registration", %{task_id: task_id} do
      metadata = %{status: :starting, started_at: System.system_time(:second)}

      {:ok, _} = PodRegistry.register(task_id, metadata)
      {:error, {:already_registered, _pid}} = PodRegistry.register(task_id, metadata)
    end

    test "unregisters pods", %{task_id: task_id} do
      metadata = %{status: :starting, started_at: System.system_time(:second)}

      {:ok, _} = PodRegistry.register(task_id, metadata)
      :ok = PodRegistry.unregister(task_id)
      assert {:error, :not_found} = PodRegistry.lookup(task_id)
    end

    test "lists all registered pods" do
      task_id1 = "test-list-1-#{:rand.uniform(1_000_000)}"
      task_id2 = "test-list-2-#{:rand.uniform(1_000_000)}"

      {:ok, _} = PodRegistry.register(task_id1, %{status: :active})
      {:ok, _} = PodRegistry.register(task_id2, %{status: :active})

      all_pods = PodRegistry.list_all()

      # Filter for only :pod keys (registry may contain other types like :communications)
      task_ids =
        all_pods
        |> Enum.filter(fn
          {{:pod, _id}, _pid, _meta} -> true
          _ -> false
        end)
        |> Enum.map(fn {{:pod, id}, _pid, _meta} -> id end)

      assert task_id1 in task_ids
      assert task_id2 in task_ids

      # Cleanup
      PodRegistry.unregister(task_id1)
      PodRegistry.unregister(task_id2)
    end

    test "counts registered pods" do
      initial_count = PodRegistry.count()

      task_id1 = "test-count-1-#{:rand.uniform(1_000_000)}"
      task_id2 = "test-count-2-#{:rand.uniform(1_000_000)}"

      {:ok, _} = PodRegistry.register(task_id1, %{})
      {:ok, _} = PodRegistry.register(task_id2, %{})

      assert PodRegistry.count() == initial_count + 2

      # Cleanup
      PodRegistry.unregister(task_id1)
      PodRegistry.unregister(task_id2)
    end

    test "updates pod metadata", %{task_id: task_id} do
      {:ok, _} = PodRegistry.register(task_id, %{status: :starting})
      :ok = PodRegistry.update_meta(task_id, %{status: :active, updated: true})

      {:ok, _pid, metadata} = PodRegistry.lookup(task_id)
      assert metadata.status == :active
      assert metadata.updated == true

      PodRegistry.unregister(task_id)
    end
  end

  describe "PodSupervisor.start_pod/1" do
    test "starts a pod successfully", %{task_id: task_id} do
      {:ok, pid} = PodSupervisor.start_pod(task_id)
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert PodSupervisor.pod_running?(task_id)
    end

    test "returns error if pod already running", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      assert {:error, :already_started} = PodSupervisor.start_pod(task_id)
    end

    test "returns error if stream doesn't exist" do
      nonexistent_task = "nonexistent-task-#{:rand.uniform(1_000_000)}"
      assert {:error, :stream_not_found} = PodSupervisor.start_pod(nonexistent_task)
    end

    test "registers pod in registry", %{task_id: task_id} do
      {:ok, pid} = PodSupervisor.start_pod(task_id)
      {:ok, registered_pid, metadata} = PodRegistry.lookup(task_id)

      assert registered_pid == pid
      assert metadata[:started_at]
      assert metadata[:status] in [:starting, :active]
    end
  end

  describe "PodSupervisor.stop_pod/1" do
    test "stops a running pod", %{task_id: task_id} do
      {:ok, pid} = PodSupervisor.start_pod(task_id)
      assert Process.alive?(pid)

      :ok = PodSupervisor.stop_pod(task_id)

      # Wait for shutdown to complete
      Process.sleep(200)

      refute Process.alive?(pid)
      refute PodSupervisor.pod_running?(task_id)
    end

    test "returns error if pod not running", %{task_id: task_id} do
      assert {:error, :not_running} = PodSupervisor.stop_pod(task_id)
    end

    test "unregisters pod from registry", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      :ok = PodSupervisor.stop_pod(task_id)

      Process.sleep(200)
      assert {:error, :not_found} = PodRegistry.lookup(task_id)
    end
  end

  describe "PodSupervisor.restart_pod/1" do
    test "restarts a running pod", %{task_id: task_id} do
      {:ok, old_pid} = PodSupervisor.start_pod(task_id)

      # Wait a bit for pod to fully start
      Process.sleep(100)

      {:ok, new_pid} = PodSupervisor.restart_pod(task_id)

      assert old_pid != new_pid
      assert Process.alive?(new_pid)
      assert PodSupervisor.pod_running?(task_id)
    end

    test "starts pod if not running", %{task_id: task_id} do
      {:ok, pid} = PodSupervisor.restart_pod(task_id)
      assert is_pid(pid)
      assert PodSupervisor.pod_running?(task_id)
    end
  end

  describe "PodSupervisor.get_pod_pid/1" do
    test "returns pid of running pod", %{task_id: task_id} do
      {:ok, started_pid} = PodSupervisor.start_pod(task_id)
      {:ok, found_pid} = PodSupervisor.get_pod_pid(task_id)

      assert started_pid == found_pid
    end

    test "returns error for non-existent pod", %{task_id: task_id} do
      assert {:error, :not_found} = PodSupervisor.get_pod_pid(task_id)
    end
  end

  describe "PodSupervisor.pod_running?/1" do
    test "returns true for running pod", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      assert PodSupervisor.pod_running?(task_id)
    end

    test "returns false for non-existent pod", %{task_id: task_id} do
      refute PodSupervisor.pod_running?(task_id)
    end

    test "returns false after pod stops", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      :ok = PodSupervisor.stop_pod(task_id)

      Process.sleep(200)
      refute PodSupervisor.pod_running?(task_id)
    end
  end

  describe "PodSupervisor.list_pods/0" do
    test "lists all running pods" do
      task_id1 = "test-list-pods-1-#{:rand.uniform(1_000_000)}"
      task_id2 = "test-list-pods-2-#{:rand.uniform(1_000_000)}"

      {:ok, task_id1} = EventStore.start_stream("task", task_id1)
      {:ok, task_id2} = EventStore.start_stream("task", task_id2)
      {:ok, _} = EventStore.append(task_id1, "task_created", %{title: "List 1"}, actor_id: "system")
      {:ok, _} = EventStore.append(task_id2, "task_created", %{title: "List 2"}, actor_id: "system")

      {:ok, _} = PodSupervisor.start_pod(task_id1)
      {:ok, _} = PodSupervisor.start_pod(task_id2)

      pods = PodSupervisor.list_pods()
      task_ids = Enum.map(pods, & &1.task_id)

      assert task_id1 in task_ids
      assert task_id2 in task_ids

      # Cleanup
      PodSupervisor.stop_pod(task_id1)
      PodSupervisor.stop_pod(task_id2)
    end

    test "returns pod metadata" do
      task_id = "test-metadata-#{:rand.uniform(1_000_000)}"
      {:ok, task_id} = EventStore.start_stream("task", task_id)
      {:ok, _} = EventStore.append(task_id, "task_created", %{title: "Metadata Test"}, actor_id: "system")
      {:ok, _} = PodSupervisor.start_pod(task_id)

      pods = PodSupervisor.list_pods()
      pod = Enum.find(pods, &(&1.task_id == task_id))

      assert pod.task_id == task_id
      assert is_pid(pod.pid)
      assert pod.status in [:starting, :active]
      assert is_integer(pod.started_at)

      PodSupervisor.stop_pod(task_id)
    end
  end

  describe "PodSupervisor.count_pods/0" do
    test "counts running pods" do
      initial_count = PodSupervisor.count_pods()

      task_id1 = "test-count-pods-1-#{:rand.uniform(1_000_000)}"
      task_id2 = "test-count-pods-2-#{:rand.uniform(1_000_000)}"

      {:ok, task_id1} = EventStore.start_stream("task", task_id1)
      {:ok, task_id2} = EventStore.start_stream("task", task_id2)
      {:ok, _} = EventStore.append(task_id1, "task_created", %{title: "Count 1"}, actor_id: "system")
      {:ok, _} = EventStore.append(task_id2, "task_created", %{title: "Count 2"}, actor_id: "system")

      {:ok, _} = PodSupervisor.start_pod(task_id1)
      {:ok, _} = PodSupervisor.start_pod(task_id2)

      # Use >= instead of == since other tests may have left pods running
      # (async: false doesn't guarantee cleanup order)
      assert PodSupervisor.count_pods() >= initial_count + 2

      # Cleanup
      PodSupervisor.stop_pod(task_id1)
      PodSupervisor.stop_pod(task_id2)
      Process.sleep(200)
    end
  end

  describe "Multiple Pods" do
    test "can run multiple pods simultaneously" do
      task_ids =
        Enum.map(1..5, fn i ->
          task_id = "test-multi-#{i}-#{:rand.uniform(1_000_000)}"
          {:ok, task_id} = EventStore.start_stream("task", task_id)
          {:ok, _} = EventStore.append(task_id, "task_created", %{title: "Multi #{i}"}, actor_id: "system")
          task_id
        end)

      # Start all pods
      pids =
        Enum.map(task_ids, fn task_id ->
          {:ok, pid} = PodSupervisor.start_pod(task_id)
          pid
        end)

      # All pods should be running
      assert Enum.all?(pids, &Process.alive?/1)
      assert Enum.all?(task_ids, &PodSupervisor.pod_running?/1)

      # Stop all pods
      Enum.each(task_ids, &PodSupervisor.stop_pod/1)
    end

    test "pods are isolated - stopping one doesn't affect others" do
      task_id1 = "test-isolated-1-#{:rand.uniform(1_000_000)}"
      task_id2 = "test-isolated-2-#{:rand.uniform(1_000_000)}"

      {:ok, task_id1} = EventStore.start_stream("task", task_id1)
      {:ok, task_id2} = EventStore.start_stream("task", task_id2)

      # Append task_created events (required by Pod.Manager)
      {:ok, _} = EventStore.append(task_id1, "task_created", %{title: "Test 1"}, actor_id: "system")
      {:ok, _} = EventStore.append(task_id2, "task_created", %{title: "Test 2"}, actor_id: "system")

      {:ok, _pid1} = PodSupervisor.start_pod(task_id1)
      {:ok, pid2} = PodSupervisor.start_pod(task_id2)

      # Stop first pod
      :ok = PodSupervisor.stop_pod(task_id1)
      Process.sleep(100)

      # Second pod should still be running
      assert Process.alive?(pid2)
      assert PodSupervisor.pod_running?(task_id2)

      # Cleanup
      PodSupervisor.stop_pod(task_id2)
    end
  end

  describe "Race Conditions" do
    test "prevents duplicate pods from concurrent starts" do
      task_id = "test-race-#{:rand.uniform(1_000_000)}"
      {:ok, task_id} = EventStore.start_stream("task", task_id)
      {:ok, _} = EventStore.append(task_id, "task_created", %{title: "Race Test"}, actor_id: "system")

      # Try to start the same pod concurrently
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            PodSupervisor.start_pod(task_id)
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      # Exactly one should succeed
      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, :already_started}, &1))

      assert successes == 1
      assert failures == 9

      # Cleanup
      PodSupervisor.stop_pod(task_id)
    end
  end

  describe "Graceful Shutdown" do
    test "pod terminates cleanly" do
      task_id = "test-shutdown-#{:rand.uniform(1_000_000)}"
      {:ok, task_id} = EventStore.start_stream("task", task_id)
      {:ok, _} = EventStore.append(task_id, "task_created", %{title: "Shutdown Test"}, actor_id: "system")

      {:ok, pid} = PodSupervisor.start_pod(task_id)
      ref = Process.monitor(pid)

      :ok = PodSupervisor.stop_pod(task_id)

      # Wait for termination message
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

      refute Process.alive?(pid)
    end
  end
end
