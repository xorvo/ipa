defmodule Ipa.Pod.WorkspaceManagerTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.WorkspaceManager
  alias Ipa.EventStore

  describe "path validation (unit tests - no aw CLI required)" do
    setup do
      # These tests use internal validation functions via file operations
      task_id = "task-#{UUID.uuid4()}"
      agent_id = "agent-#{UUID.uuid4()}"

      # Create task stream
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      # Create a temporary workspace directory manually for testing
      workspace_path = Path.join(System.tmp_dir!(), "ipa_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_path)

      # Add workspace_created event to simulate existing workspace
      {:ok, _} = EventStore.append(
        task_id,
        "workspace_created",
        %{
          agent_id: agent_id,
          workspace_path: workspace_path,
          config: %{}
        },
        actor_id: "system"
      )

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(workspace_path)
      end)

      %{task_id: task_id, agent_id: agent_id, workspace_path: workspace_path, pid: pid}
    end

    test "rejects path traversal with ..", %{task_id: task_id, agent_id: agent_id} do
      assert {:error, :path_traversal_attempt} =
               WorkspaceManager.read_file(task_id, agent_id, "../../../etc/passwd")
    end

    test "rejects absolute paths", %{task_id: task_id, agent_id: agent_id} do
      assert {:error, :absolute_path_not_allowed} =
               WorkspaceManager.read_file(task_id, agent_id, "/etc/passwd")
    end

    test "rejects paths with null bytes", %{task_id: task_id, agent_id: agent_id} do
      assert {:error, :invalid_path_null_byte} =
               WorkspaceManager.read_file(task_id, agent_id, "file\0.txt")
    end

    test "rejects paths exceeding max length", %{task_id: task_id, agent_id: agent_id} do
      long_path = String.duplicate("a", 5000)

      assert {:error, :path_too_long} =
               WorkspaceManager.read_file(task_id, agent_id, long_path)
    end

    test "allows valid relative paths", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      # Create a test file
      test_file = Path.join(workspace_path, "test.txt")
      File.write!(test_file, "test content")

      assert {:ok, "test content"} = WorkspaceManager.read_file(task_id, agent_id, "test.txt")
    end

    test "allows paths in subdirectories", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      # Create subdirectory and file
      subdir = Path.join(workspace_path, "work")
      File.mkdir_p!(subdir)
      test_file = Path.join(subdir, "output.txt")
      File.write!(test_file, "output content")

      assert {:ok, "output content"} =
               WorkspaceManager.read_file(task_id, agent_id, "work/output.txt")
    end
  end

  describe "file operations (unit tests - no aw CLI required)" do
    setup do
      task_id = "task-#{UUID.uuid4()}"
      agent_id = "agent-#{UUID.uuid4()}"

      # Create task stream
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      # Create a temporary workspace directory manually
      workspace_path = Path.join(System.tmp_dir!(), "ipa_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_path)

      # Add workspace_created event
      {:ok, _} = EventStore.append(
        task_id,
        "workspace_created",
        %{
          agent_id: agent_id,
          workspace_path: workspace_path,
          config: %{}
        },
        actor_id: "system"
      )

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(workspace_path)
      end)

      %{task_id: task_id, agent_id: agent_id, workspace_path: workspace_path, pid: pid}
    end

    test "read_file/3 reads file content", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      test_file = Path.join(workspace_path, "data.txt")
      File.write!(test_file, "file content")

      assert {:ok, "file content"} = WorkspaceManager.read_file(task_id, agent_id, "data.txt")
    end

    test "read_file/3 returns error for non-existent file", %{
      task_id: task_id,
      agent_id: agent_id
    } do
      assert {:error, :file_not_found} =
               WorkspaceManager.read_file(task_id, agent_id, "nonexistent.txt")
    end

    test "write_file/4 writes file content", %{task_id: task_id, agent_id: agent_id} do
      assert :ok =
               WorkspaceManager.write_file(task_id, agent_id, "output.txt", "new content")

      assert {:ok, "new content"} = WorkspaceManager.read_file(task_id, agent_id, "output.txt")
    end

    test "write_file/4 creates parent directories", %{task_id: task_id, agent_id: agent_id} do
      assert :ok =
               WorkspaceManager.write_file(
                 task_id,
                 agent_id,
                 "nested/dir/file.txt",
                 "nested content"
               )

      assert {:ok, "nested content"} =
               WorkspaceManager.read_file(task_id, agent_id, "nested/dir/file.txt")
    end

    test "list_files/2 returns file tree", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      # Create test file structure
      File.write!(Path.join(workspace_path, "root.txt"), "root")
      File.mkdir_p!(Path.join(workspace_path, "dir1"))
      File.write!(Path.join(workspace_path, "dir1/file1.txt"), "file1")
      File.mkdir_p!(Path.join(workspace_path, "dir2/subdir"))
      File.write!(Path.join(workspace_path, "dir2/subdir/file2.txt"), "file2")

      assert {:ok, tree} = WorkspaceManager.list_files(task_id, agent_id)

      assert tree["root.txt"] == :file
      assert is_map(tree["dir1"])
      assert tree["dir1"]["file1.txt"] == :file
      assert is_map(tree["dir2"])
      assert is_map(tree["dir2"]["subdir"])
      assert tree["dir2"]["subdir"]["file2.txt"] == :file
    end

    test "get_workspace_path/2 returns workspace path", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      assert {:ok, ^workspace_path} = WorkspaceManager.get_workspace_path(task_id, agent_id)
    end

    test "get_workspace_path/2 returns error for non-existent workspace", %{task_id: task_id} do
      non_existent_agent = "agent-nonexistent"

      assert {:error, :workspace_not_found} =
               WorkspaceManager.get_workspace_path(task_id, non_existent_agent)
    end

    test "workspace_exists?/2 returns true when workspace exists", %{
      task_id: task_id,
      agent_id: agent_id
    } do
      assert WorkspaceManager.workspace_exists?(task_id, agent_id)
    end

    test "workspace_exists?/2 returns false when workspace doesn't exist", %{task_id: task_id} do
      non_existent_agent = "agent-nonexistent"

      refute WorkspaceManager.workspace_exists?(task_id, non_existent_agent)
    end
  end

  describe "event sourcing (unit tests)" do
    test "rebuilds state from workspace events on initialization" do
      task_id = "task-#{UUID.uuid4()}"
      agent_id = "agent-#{UUID.uuid4()}"

      # Create task stream and add workspace_created event
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} = EventStore.append(
        task_id,
        "workspace_created",
        %{
          agent_id: agent_id,
          workspace_path: "/ipa/workspaces/#{task_id}/#{agent_id}",
          config: %{max_size_mb: 500}
        },
        actor_id: "system"
      )

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      # Verify workspace is in state
      assert {:ok, _path} = WorkspaceManager.get_workspace_path(task_id, agent_id)

      GenServer.stop(pid)
    end

    test "applies workspace_created and workspace_cleanup events correctly" do
      task_id = "task-#{UUID.uuid4()}"
      agent_id_1 = "agent-1"
      agent_id_2 = "agent-2"

      # Create task stream
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      # Add workspace_created events
      {:ok, _} = EventStore.append(
        task_id,
        "workspace_created",
        %{
          agent_id: agent_id_1,
          workspace_path: "/ipa/workspaces/#{task_id}/#{agent_id_1}",
          config: %{}
        },
        actor_id: "system"
      )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workspace_created",
          %{
            agent_id: agent_id_2,
            workspace_path: "/ipa/workspaces/#{task_id}/#{agent_id_2}",
            config: %{}
          },
          actor_id: "system"
        )

      # Add workspace_cleanup event for agent_id_1
      {:ok, _} = EventStore.append(
        task_id,
        "workspace_cleanup",
        %{
          agent_id: agent_id_1,
          workspace_path: "/ipa/workspaces/#{task_id}/#{agent_id_1}",
          cleanup_reason: "test"
        },
        actor_id: "system"
      )

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      # agent_id_1 should not exist (cleaned up)
      assert {:error, :workspace_not_found} =
               WorkspaceManager.get_workspace_path(task_id, agent_id_1)

      # agent_id_2 should exist
      assert {:ok, _path} = WorkspaceManager.get_workspace_path(task_id, agent_id_2)

      GenServer.stop(pid)
    end
  end

  describe "create_workspace/3 (integration tests)" do
    setup do
      task_id = "task-#{UUID.uuid4()}"
      agent_id = "agent-#{UUID.uuid4()}"

      # Use a temporary directory for workspace base path
      temp_base = Path.join(System.tmp_dir!(), "ipa_ws_create_#{System.unique_integer([:positive])}")
      File.mkdir_p!(temp_base)

      # Configure the temp base path for this test
      original_config = Application.get_env(:ipa, WorkspaceManager, [])
      Application.put_env(:ipa, WorkspaceManager, Keyword.put(original_config, :base_path, temp_base))

      # Create task stream
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      on_exit(fn ->
        # Cleanup: try to destroy workspace if it was created
        try do
          WorkspaceManager.cleanup_workspace(task_id, agent_id)
        catch
          _, _ -> :ok
        end

        if Process.alive?(pid), do: GenServer.stop(pid)
        # Restore original config
        Application.put_env(:ipa, WorkspaceManager, original_config)
        # Cleanup temp directory
        File.rm_rf(temp_base)
      end)

      %{task_id: task_id, agent_id: agent_id, pid: pid}
    end

    test "creates workspace with directory structure", %{task_id: task_id, agent_id: agent_id} do
      assert {:ok, workspace_path} =
               WorkspaceManager.create_workspace(task_id, agent_id, %{})

      assert String.contains?(workspace_path, task_id)
      assert String.contains?(workspace_path, agent_id)

      # Verify workspace path exists
      assert File.exists?(workspace_path)

      # Verify directory structure
      assert File.dir?(Path.join(workspace_path, ".ipa"))
      assert File.dir?(Path.join(workspace_path, "work"))
      assert File.dir?(Path.join(workspace_path, "output"))

      # Verify metadata files
      assert File.exists?(Path.join([workspace_path, ".ipa", "task_spec.json"]))
      assert File.exists?(Path.join([workspace_path, ".ipa", "workspace_config.json"]))
      assert File.exists?(Path.join([workspace_path, ".ipa", "context.json"]))
    end

    test "injects CLAUDE.md when provided", %{task_id: task_id, agent_id: agent_id} do
      claude_md = "# Task Context\n\nThis is test CLAUDE.md content"

      assert {:ok, workspace_path} =
               WorkspaceManager.create_workspace(task_id, agent_id, %{claude_md: claude_md})

      # Verify CLAUDE.md was written
      claude_md_path = Path.join(workspace_path, "CLAUDE.md")
      assert File.exists?(claude_md_path)
      assert File.read!(claude_md_path) == claude_md
    end

    test "returns error when workspace already exists", %{task_id: task_id, agent_id: agent_id} do
      assert {:ok, _workspace_path} =
               WorkspaceManager.create_workspace(task_id, agent_id, %{})

      # Second creation should fail
      assert {:error, :workspace_exists} =
               WorkspaceManager.create_workspace(task_id, agent_id, %{})
    end

    test "appends workspace_created event", %{task_id: task_id, agent_id: agent_id} do
      assert {:ok, workspace_path} =
               WorkspaceManager.create_workspace(task_id, agent_id, %{})

      # Verify event was appended
      {:ok, events} = EventStore.read_stream(task_id, event_types: ["workspace_created"])
      assert length(events) == 1

      event = List.first(events)
      assert event.event_type == "workspace_created"
      assert event.data[:agent_id] == agent_id
      assert event.data[:workspace_path] == workspace_path
    end
  end

  describe "cleanup_workspace/2 (integration tests)" do
    setup do
      task_id = "task-#{UUID.uuid4()}"
      agent_id = "agent-#{UUID.uuid4()}"

      # Use a temporary directory for workspace base path
      temp_base = Path.join(System.tmp_dir!(), "ipa_ws_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(temp_base)

      # Configure the temp base path for this test
      original_config = Application.get_env(:ipa, WorkspaceManager, [])
      Application.put_env(:ipa, WorkspaceManager, Keyword.put(original_config, :base_path, temp_base))

      # Create task stream
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, pid} = WorkspaceManager.start_link(task_id: task_id)

      # Create workspace
      {:ok, workspace_path} = WorkspaceManager.create_workspace(task_id, agent_id, %{})

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        # Restore original config
        Application.put_env(:ipa, WorkspaceManager, original_config)
        # Cleanup temp directory
        File.rm_rf(temp_base)
      end)

      %{task_id: task_id, agent_id: agent_id, workspace_path: workspace_path, pid: pid}
    end

    test "destroys workspace directory", %{
      task_id: task_id,
      agent_id: agent_id,
      workspace_path: workspace_path
    } do
      assert :ok = WorkspaceManager.cleanup_workspace(task_id, agent_id)

      # Verify workspace no longer exists
      refute File.exists?(workspace_path)
    end

    test "appends workspace_cleanup event", %{task_id: task_id, agent_id: agent_id} do
      assert :ok = WorkspaceManager.cleanup_workspace(task_id, agent_id)

      # Verify event was appended
      {:ok, events} = EventStore.read_stream(task_id, event_types: ["workspace_cleanup"])
      assert length(events) == 1

      event = List.first(events)
      assert event.event_type == "workspace_cleanup"
      assert event.data[:agent_id] == agent_id
    end

    test "removes workspace from state after cleanup", %{task_id: task_id, agent_id: agent_id} do
      assert :ok = WorkspaceManager.cleanup_workspace(task_id, agent_id)

      # Verify workspace no longer exists in state
      assert {:error, :workspace_not_found} =
               WorkspaceManager.get_workspace_path(task_id, agent_id)
    end
  end
end
