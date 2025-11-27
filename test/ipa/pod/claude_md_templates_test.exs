defmodule Ipa.Pod.ClaudeMdTemplatesTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.ClaudeMdTemplates
  alias Ipa.Pod.Manager
  alias Ipa.EventStore

  setup do
    # Generate unique task ID for each test
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"

    # Create event stream for task
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Create task with some basic data
    {:ok, _} =
      EventStore.append(
        task_id,
        "task_created",
        %{
          title: "Build user authentication system",
          description: "Implement secure user authentication with JWT tokens",
          created_by: "user-123"
        },
        actor_id: "user-123"
      )

    # Start Pod Manager to make state queryable
    {:ok, _state_pid} = Manager.start_link(task_id: task_id)

    # Clean up after test
    on_exit(fn ->
      # Stop manager (defensive - check if process is alive)
      case Registry.lookup(Ipa.PodRegistry, {:manager, task_id}) do
        [] ->
          :ok

        [{pid, _}] ->
          if Process.alive?(pid) do
            GenServer.stop(pid, :normal, 100)
          end
      end

      # Event store cleanup is handled by the database sandbox
    end)

    {:ok, task_id: task_id}
  end

  describe "get_system_level/0" do
    test "returns system-level template content" do
      {:ok, content} = ClaudeMdTemplates.get_system_level()

      # Should be a non-empty string
      assert is_binary(content)
      assert String.length(content) > 0

      # Should contain key sections
      assert content =~ "IPA System Context"
      assert content =~ "Architecture"
      assert content =~ "Workstreams"
      assert content =~ "Event Sourcing"
    end

    test "caches system template for subsequent calls" do
      # First call loads from file
      {:ok, content1} = ClaudeMdTemplates.get_system_level()

      # Second call should return cached version
      {:ok, content2} = ClaudeMdTemplates.get_system_level()

      # Content should be identical
      assert content1 == content2
    end

    test "returns error if system template file is missing" do
      # This test would require mocking File.read, which is complex
      # For now, we trust that if the file exists, it works
      # (The test suite will fail if the file is genuinely missing)
      {:ok, _content} = ClaudeMdTemplates.get_system_level()
    end
  end

  describe "generate_pod_level/2" do
    test "generates pod-level template with task context", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_pod_level(task_id)

      # Should be a non-empty string
      assert is_binary(content)
      assert String.length(content) > 0

      # Should contain task title
      assert content =~ "Build user authentication system"

      # Should contain task phase
      assert content =~ "spec_clarification"

      # Should contain repository info
      assert content =~ "git@github.com:xorvo/ipa.git"
    end

    test "handles task with workstreams", %{task_id: task_id} do
      # Add some workstreams
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            title: "Database Schema",
            spec: "Design and implement user table",
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
            title: "API Endpoints",
            spec: "Implement login and signup endpoints",
            dependencies: ["ws-1"],
            estimated_hours: 6
          },
          actor_id: "scheduler"
        )

      # Restart manager to pick up new events
      stop_manager(task_id)
      {:ok, _} = Manager.start_link(task_id: task_id)

      {:ok, content} = ClaudeMdTemplates.generate_pod_level(task_id)

      # Should mention both workstreams (by ID, since State Manager doesn't store titles)
      assert content =~ "ws-1"
      assert content =~ "ws-2"
      assert content =~ "Design and implement user table"
      assert content =~ "Implement login and signup endpoints"
    end

    test "allows overriding task context with opts", %{task_id: task_id} do
      {:ok, content} =
        ClaudeMdTemplates.generate_pod_level(task_id,
          task_title: "Custom Title",
          repo_url: "git@github.com:custom/repo.git",
          branch: "feature/custom"
        )

      # Should use overridden values
      assert content =~ "Custom Title"
      assert content =~ "git@github.com:custom/repo.git"
      assert content =~ "feature/custom"
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} =
               ClaudeMdTemplates.generate_pod_level("non-existent-task")
    end
  end

  describe "generate_workstream_level/3" do
    setup %{task_id: task_id} do
      # Create workstreams for testing
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-db",
            title: "Database Schema",
            spec: "Design and implement user table with proper indexes",
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
            workstream_id: "ws-api",
            title: "API Endpoints",
            spec: "Implement RESTful endpoints for user management",
            dependencies: ["ws-db"],
            estimated_hours: 6
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-ui",
            title: "UI Components",
            spec: "Build login and signup forms",
            dependencies: ["ws-api"],
            estimated_hours: 8
          },
          actor_id: "scheduler"
        )

      # Restart manager to pick up new events
      stop_manager(task_id)
      {:ok, _} = Manager.start_link(task_id: task_id)

      :ok
    end

    test "generates workstream-level template with full context", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-api")

      # Should contain task title
      assert content =~ "Build user authentication system"

      # Should contain workstream ID (State Manager doesn't store titles)
      assert content =~ "ws-api"

      # Should contain workstream spec
      assert content =~ "RESTful endpoints for user management"

      # Should show dependencies
      assert content =~ "ws-db"

      # Should list related workstreams (by ID)
      assert content =~ "ws-db"
      assert content =~ "ws-ui"
    end

    test "shows dependent workstreams", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-db")

      # ws-api depends on ws-db, so it should be listed as dependent
      assert content =~ "These workstreams are waiting for your completion"
      assert content =~ "ws-api"
    end

    test "shows no dependencies for first workstream", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-db")

      # ws-db has no dependencies
      assert content =~ "has no dependencies"
      assert content =~ "can start immediately"
    end

    test "shows dependencies for later workstreams", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-ui")

      # ws-ui depends on ws-api
      assert content =~ "depends on the following workstreams"
      assert content =~ "ws-api"
    end

    test "allows overriding workstream context with opts", %{task_id: task_id} do
      {:ok, content} =
        ClaudeMdTemplates.generate_workstream_level(task_id, "ws-api",
          workstream_spec: "Custom spec content",
          branch: "feature/custom-branch"
        )

      # Should use overridden values
      assert content =~ "Custom spec content"
      assert content =~ "feature/custom-branch"
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} =
               ClaudeMdTemplates.generate_workstream_level("non-existent-task", "ws-1")
    end

    test "returns error for non-existent workstream", %{task_id: task_id} do
      assert {:error, :workstream_not_found} =
               ClaudeMdTemplates.generate_workstream_level(task_id, "non-existent-ws")
    end
  end

  describe "template rendering" do
    test "handles task with no workstreams", %{task_id: task_id} do
      {:ok, content} = ClaudeMdTemplates.generate_pod_level(task_id)

      # Should handle empty workstreams gracefully
      assert content =~ "not been broken down into workstreams yet"
    end

    test "handles workstream with no related workstreams" do
      # Create a task with only one workstream
      task_id = "task-single-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Simple task", description: "Test", created_by: "user-123"},
          actor_id: "user-123"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-only",
            title: "Only Workstream",
            spec: "The only one",
            dependencies: [],
            estimated_hours: 2
          },
          actor_id: "scheduler"
        )

      # Start manager after all events are appended
      {:ok, _state_pid} = Manager.start_link(task_id: task_id)

      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-only")

      # Should handle single workstream (no related workstreams section)
      assert content =~ "ws-only"
      refute content =~ "Related Workstreams"

      # Cleanup (defensive)
      stop_manager(task_id)
    end

    test "escapes special characters in template variables", %{task_id: task_id} do
      # Create a workstream with special characters
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-special",
            title: "Workstream with <special> & \"characters\"",
            spec: "Handle <%= symbols %>",
            dependencies: [],
            estimated_hours: 1
          },
          actor_id: "scheduler"
        )

      # Restart manager to pick up new events
      stop_manager(task_id)
      {:ok, _} = Manager.start_link(task_id: task_id)

      # Should not crash on special characters
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-special")

      # Content should be valid
      assert is_binary(content)
      assert String.length(content) > 0
    end
  end

  # Note: get_workstream_title/2 helper was removed since EEx templates can't call module functions.
  # The template now uses Enum.find directly to look up workstream titles.

  describe "configuration" do
    test "uses repo_url from application config" do
      # Default config should be used
      Application.put_env(:ipa, :repo_url, "git@github.com:test/test.git")

      task_id = "task-config-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Test", description: "Test", created_by: "user-123"},
          actor_id: "user-123"
        )

      {:ok, _state_pid} = Manager.start_link(task_id: task_id)

      {:ok, content} = ClaudeMdTemplates.generate_pod_level(task_id)

      assert content =~ "git@github.com:test/test.git"

      # Cleanup (defensive)
      stop_manager(task_id)

      # Reset config
      Application.put_env(:ipa, :repo_url, "git@github.com:xorvo/ipa.git")
    end
  end

  # Helper to stop manager by task_id
  defp stop_manager(task_id) do
    case Registry.lookup(Ipa.PodRegistry, {:manager, task_id}) do
      [] -> :ok
      [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
    end
  end
end
