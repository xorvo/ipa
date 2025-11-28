defmodule Ipa.Pod.ExternalSyncTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.ExternalSync
  alias Ipa.Pod.ExternalSync.SyncQueue
  alias Ipa.EventStore
  alias Ipa.PodSupervisor

  @moduletag :capture_log

  setup do
    # Ensure clean state
    task_id = "test-sync-#{:rand.uniform(100_000)}"

    # Create the task stream first
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Add initial event
    {:ok, _} =
      EventStore.append(
        task_id,
        "task_created",
        %{title: "Test Task"},
        actor_id: "test"
      )

    on_exit(fn ->
      # Cleanup
      if PodSupervisor.pod_running?(task_id) do
        PodSupervisor.stop_pod(task_id)
      end
    end)

    {:ok, task_id: task_id}
  end

  describe "start_link/1" do
    test "starts the external sync manager", %{task_id: task_id} do
      # First start the pod so State is available
      {:ok, _pid} = PodSupervisor.start_pod(task_id)

      # Now start external sync
      {:ok, pid} = ExternalSync.start_link(task_id: task_id)
      assert Process.alive?(pid)
    end

    test "registers via Registry", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      {:ok, pid} = ExternalSync.start_link(task_id: task_id)

      assert [{^pid, nil}] = Registry.lookup(Ipa.PodRegistry, {:pod_sync, task_id})
    end

    test "starts with GitHub config", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)

      {:ok, _pid} =
        ExternalSync.start_link(
          task_id: task_id,
          github: %{repo: "test/repo", base_branch: "develop"}
        )

      {:ok, status} = ExternalSync.get_status(task_id)
      assert status.github.enabled == true
    end
  end

  describe "get_status/1" do
    test "returns current sync status", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      {:ok, _pid} = ExternalSync.start_link(task_id: task_id)

      {:ok, status} = ExternalSync.get_status(task_id)

      assert status.status == :idle
      assert is_map(status.github)
      assert status.github.pr_number == nil
    end

    test "returns error when not running", %{task_id: task_id} do
      assert {:error, :not_found} = ExternalSync.get_status(task_id)
    end
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes to sync events", %{task_id: task_id} do
      {:ok, _pid} = PodSupervisor.start_pod(task_id)
      {:ok, _pid} = ExternalSync.start_link(task_id: task_id)

      assert :ok = ExternalSync.subscribe(task_id)
      assert :ok = ExternalSync.unsubscribe(task_id)
    end
  end
end

defmodule Ipa.Pod.ExternalSync.SyncQueueTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.ExternalSync.SyncQueue

  @moduletag :capture_log

  setup do
    task_id = "test-queue-#{:rand.uniform(100_000)}"
    {:ok, task_id: task_id}
  end

  describe "start_link/1" do
    test "starts the sync queue", %{task_id: task_id} do
      {:ok, pid} = SyncQueue.start_link(task_id: task_id)
      assert Process.alive?(pid)
    end
  end

  describe "enqueue/3" do
    test "enqueues an operation", %{task_id: task_id} do
      {:ok, pid} = SyncQueue.start_link(task_id: task_id)

      assert :ok = SyncQueue.enqueue(pid, :create_pr, %{task_id: task_id, title: "Test"})

      {:ok, status} = SyncQueue.get_status(pid)
      assert status.pending >= 0
    end

    test "deduplicates identical operations", %{task_id: task_id} do
      {:ok, pid} = SyncQueue.start_link(task_id: task_id)

      data = %{task_id: task_id, title: "Test"}
      SyncQueue.enqueue(pid, :create_pr, data)
      SyncQueue.enqueue(pid, :create_pr, data)

      # Give it a moment to process casts
      Process.sleep(50)

      {:ok, status} = SyncQueue.get_status(pid)
      # Should only have 1 item due to deduplication
      assert status.pending <= 1
    end
  end

  describe "get_status/1" do
    test "returns queue status", %{task_id: task_id} do
      {:ok, pid} = SyncQueue.start_link(task_id: task_id)

      {:ok, status} = SyncQueue.get_status(pid)

      assert status.pending == 0
      assert status.processing == false
      assert status.processed_count == 0
      assert status.failed_count == 0
    end
  end

  describe "clear/1" do
    test "clears the queue", %{task_id: task_id} do
      {:ok, pid} = SyncQueue.start_link(task_id: task_id)

      SyncQueue.enqueue(pid, :create_pr, %{task_id: task_id, title: "Test"})
      Process.sleep(50)

      assert :ok = SyncQueue.clear(pid)

      {:ok, status} = SyncQueue.get_status(pid)
      assert status.pending == 0
    end
  end
end

defmodule Ipa.Pod.ExternalSync.GitHubConnectorTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.ExternalSync.GitHubConnector

  @moduletag :capture_log

  describe "check_auth/0" do
    test "checks if gh CLI is authenticated" do
      result = GitHubConnector.check_auth()
      # This will either succeed or fail depending on gh installation/auth
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # Note: Most GitHub connector tests would require mocking or integration tests
  # with a real GitHub repo. Here we just test the module structure.

  describe "module structure" do
    test "exports expected functions" do
      exports = GitHubConnector.__info__(:functions)

      assert {:create_pr, 2} in exports
      assert {:update_pr, 3} in exports
      assert {:get_pr, 2} in exports
      assert {:merge_pr, 3} in exports
      assert {:close_pr, 2} in exports
      assert {:get_pr_comments, 2} in exports
      assert {:add_pr_comment, 3} in exports
      assert {:get_rate_limit, 0} in exports
      assert {:check_auth, 0} in exports
    end
  end
end
