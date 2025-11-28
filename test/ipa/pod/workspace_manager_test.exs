defmodule Ipa.Pod.WorkspaceManagerTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.WorkspaceManager

  @moduletag :tmp_dir

  describe "path helpers" do
    test "task_workspace_path/1 returns correct path" do
      task_id = "task-123"
      base = WorkspaceManager.base_path()
      assert WorkspaceManager.task_workspace_path(task_id) == Path.join(base, task_id)
    end

    test "sub_workspaces_dir/1 returns correct path" do
      task_id = "task-123"
      expected = Path.join([WorkspaceManager.base_path(), task_id, "sub-workspaces"])
      assert WorkspaceManager.sub_workspaces_dir(task_id) == expected
    end

    test "sub_workspace_path/2 returns correct path" do
      task_id = "task-123"
      workspace_name = "planning-abc123"
      expected = Path.join([WorkspaceManager.base_path(), task_id, "sub-workspaces", workspace_name])
      assert WorkspaceManager.sub_workspace_path(task_id, workspace_name) == expected
    end
  end

  describe "generate_workspace_name/2" do
    test "generates name with prefix and short suffix" do
      name = WorkspaceManager.generate_workspace_name("planning", "task-abc-123-def")
      # The suffix is extracted from the unique_suffix (first 8 chars after removing dashes)
      assert String.starts_with?(name, "planning-")
      assert String.length(name) > String.length("planning-")
    end

    test "sanitizes prefix with special characters" do
      name = WorkspaceManager.generate_workspace_name("Setup Database!", "ws-123")
      # Prefix is sanitized (lowercase, dashes for special chars)
      assert String.starts_with?(name, "setup-database-")
    end

    test "generates ws- prefix when nil" do
      name = WorkspaceManager.generate_workspace_name(nil, "random-id-123")
      assert String.starts_with?(name, "ws-")
    end

    test "truncates long prefixes" do
      long_prefix = String.duplicate("a", 100)
      name = WorkspaceManager.generate_workspace_name(long_prefix, "id-123")
      # Prefix should be truncated to 50 chars + "-" + 8 char suffix
      assert String.length(name) <= 60
    end
  end

  describe "sanitize_name/1" do
    test "converts to lowercase" do
      assert WorkspaceManager.sanitize_name("HELLO") == "hello"
    end

    test "replaces special characters with dashes" do
      assert WorkspaceManager.sanitize_name("hello world!") == "hello-world"
    end

    test "removes leading and trailing dashes" do
      assert WorkspaceManager.sanitize_name("--hello--") == "hello"
    end

    test "truncates to 50 characters" do
      long_name = String.duplicate("a", 100)
      assert String.length(WorkspaceManager.sanitize_name(long_name)) == 50
    end
  end

  describe "base workspace operations" do
    setup %{tmp_dir: tmp_dir} do
      # Override the base path for testing
      original_config = Application.get_env(:ipa, :workspace_base_path)
      Application.put_env(:ipa, :workspace_base_path, tmp_dir)

      on_exit(fn ->
        if original_config do
          Application.put_env(:ipa, :workspace_base_path, original_config)
        else
          Application.delete_env(:ipa, :workspace_base_path)
        end
      end)

      task_id = "task-#{:rand.uniform(100_000)}"
      %{task_id: task_id, tmp_dir: tmp_dir}
    end

    test "create_base_workspace/2 creates directory structure", %{task_id: task_id, tmp_dir: _tmp_dir} do
      assert {:ok, workspace_path} = WorkspaceManager.create_base_workspace(task_id)

      assert File.exists?(workspace_path)
      assert File.dir?(Path.join(workspace_path, ".ipa"))
      assert File.dir?(Path.join(workspace_path, "sub-workspaces"))
      assert File.dir?(Path.join(workspace_path, "work"))
      assert File.dir?(Path.join(workspace_path, "output"))
      assert File.exists?(Path.join([workspace_path, ".ipa", "task_spec.json"]))
      assert File.exists?(Path.join([workspace_path, ".ipa", "workspace_config.json"]))
      assert File.exists?(Path.join(workspace_path, "CLAUDE.md"))
      assert File.exists?(Path.join(workspace_path, "AGENT.md"))

      # CLAUDE.md and AGENT.md should have identical content
      claude_content = File.read!(Path.join(workspace_path, "CLAUDE.md"))
      agent_content = File.read!(Path.join(workspace_path, "AGENT.md"))
      assert claude_content == agent_content
    end

    test "create_base_workspace/2 returns error if already exists", %{task_id: task_id} do
      {:ok, _} = WorkspaceManager.create_base_workspace(task_id)
      assert {:error, :already_exists} = WorkspaceManager.create_base_workspace(task_id)
    end

    test "ensure_base_workspace/2 creates workspace if not exists", %{task_id: task_id} do
      assert {:ok, path} = WorkspaceManager.ensure_base_workspace(task_id)
      assert File.exists?(path)
    end

    test "ensure_base_workspace/2 returns existing path if exists", %{task_id: task_id} do
      {:ok, path1} = WorkspaceManager.create_base_workspace(task_id)
      {:ok, path2} = WorkspaceManager.ensure_base_workspace(task_id)
      assert path1 == path2
    end

    test "cleanup_base_workspace/1 removes workspace", %{task_id: task_id} do
      {:ok, workspace_path} = WorkspaceManager.create_base_workspace(task_id)
      assert File.exists?(workspace_path)

      assert :ok = WorkspaceManager.cleanup_base_workspace(task_id)
      refute File.exists?(workspace_path)
    end

    test "cleanup_base_workspace/1 returns ok for non-existent workspace", %{task_id: task_id} do
      assert :ok = WorkspaceManager.cleanup_base_workspace(task_id)
    end

    test "base_workspace_exists?/1 returns correct status", %{task_id: task_id} do
      refute WorkspaceManager.base_workspace_exists?(task_id)
      {:ok, _} = WorkspaceManager.create_base_workspace(task_id)
      assert WorkspaceManager.base_workspace_exists?(task_id)
    end
  end

  describe "sub-workspace operations" do
    setup %{tmp_dir: tmp_dir} do
      original_config = Application.get_env(:ipa, :workspace_base_path)
      Application.put_env(:ipa, :workspace_base_path, tmp_dir)

      on_exit(fn ->
        if original_config do
          Application.put_env(:ipa, :workspace_base_path, original_config)
        else
          Application.delete_env(:ipa, :workspace_base_path)
        end
      end)

      task_id = "task-#{:rand.uniform(100_000)}"
      # Create base workspace first
      {:ok, _} = WorkspaceManager.create_base_workspace(task_id)

      %{task_id: task_id, tmp_dir: tmp_dir}
    end

    test "create_sub_workspace/3 creates directory structure", %{task_id: task_id} do
      workspace_name = "planning-abc123"
      assert {:ok, workspace_path} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)

      assert File.exists?(workspace_path)
      assert File.dir?(Path.join(workspace_path, ".ipa"))
      assert File.dir?(Path.join(workspace_path, "work"))
      assert File.dir?(Path.join(workspace_path, "output"))
      assert File.exists?(Path.join([workspace_path, ".ipa", "workspace_config.json"]))
      assert File.exists?(Path.join(workspace_path, "CLAUDE.md"))
      assert File.exists?(Path.join(workspace_path, "AGENT.md"))
    end

    test "create_sub_workspace/3 stores workstream_id in config", %{task_id: task_id} do
      workspace_name = "ws-abc123"
      workstream_id = "workstream-456"
      {:ok, workspace_path} = WorkspaceManager.create_sub_workspace(task_id, workspace_name, %{
        workstream_id: workstream_id,
        purpose: :workstream
      })

      config_path = Path.join([workspace_path, ".ipa", "workspace_config.json"])
      config = config_path |> File.read!() |> Jason.decode!()

      assert config["workstream_id"] == workstream_id
      assert config["purpose"] == "workstream"
    end

    test "create_sub_workspace/3 returns error if base workspace doesn't exist" do
      non_existent_task = "task-nonexistent-#{:rand.uniform(100_000)}"
      assert {:error, :base_workspace_not_exists} =
        WorkspaceManager.create_sub_workspace(non_existent_task, "planning-123")
    end

    test "create_sub_workspace/3 returns error if already exists", %{task_id: task_id} do
      workspace_name = "planning-abc123"
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)
      assert {:error, :already_exists} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)
    end

    test "cleanup_sub_workspace/2 removes workspace", %{task_id: task_id} do
      workspace_name = "planning-abc123"
      {:ok, workspace_path} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)
      assert File.exists?(workspace_path)

      assert :ok = WorkspaceManager.cleanup_sub_workspace(task_id, workspace_name)
      refute File.exists?(workspace_path)
    end

    test "cleanup_sub_workspace/2 returns error for non-existent workspace", %{task_id: task_id} do
      assert {:error, :not_found} =
        WorkspaceManager.cleanup_sub_workspace(task_id, "nonexistent-ws")
    end

    test "list_sub_workspaces/1 returns all sub-workspaces", %{task_id: task_id} do
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, "planning-abc")
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, "ws-def")
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, "ws-ghi")

      {:ok, workspaces} = WorkspaceManager.list_sub_workspaces(task_id)
      assert length(workspaces) == 3
      assert "planning-abc" in workspaces
      assert "ws-def" in workspaces
      assert "ws-ghi" in workspaces
    end

    test "list_sub_workspaces/1 returns empty list when none exist", %{task_id: task_id} do
      {:ok, workspaces} = WorkspaceManager.list_sub_workspaces(task_id)
      assert workspaces == []
    end

    test "sub_workspace_exists?/2 returns correct status", %{task_id: task_id} do
      workspace_name = "planning-abc"
      refute WorkspaceManager.sub_workspace_exists?(task_id, workspace_name)
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)
      assert WorkspaceManager.sub_workspace_exists?(task_id, workspace_name)
    end

    test "get_sub_workspace_path/2 returns path if exists", %{task_id: task_id} do
      workspace_name = "planning-abc"
      {:ok, created_path} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)
      {:ok, retrieved_path} = WorkspaceManager.get_sub_workspace_path(task_id, workspace_name)
      assert created_path == retrieved_path
    end

    test "get_sub_workspace_path/2 returns error if not exists", %{task_id: task_id} do
      assert {:error, :not_found} = WorkspaceManager.get_sub_workspace_path(task_id, "nonexistent")
    end
  end

  describe "file operations" do
    setup %{tmp_dir: tmp_dir} do
      original_config = Application.get_env(:ipa, :workspace_base_path)
      Application.put_env(:ipa, :workspace_base_path, tmp_dir)

      on_exit(fn ->
        if original_config do
          Application.put_env(:ipa, :workspace_base_path, original_config)
        else
          Application.delete_env(:ipa, :workspace_base_path)
        end
      end)

      task_id = "task-#{:rand.uniform(100_000)}"
      workspace_name = "ws-test"

      {:ok, _} = WorkspaceManager.create_base_workspace(task_id)
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)

      %{task_id: task_id, workspace_name: workspace_name}
    end

    test "read_file/3 reads file content", %{task_id: task_id, workspace_name: ws_name} do
      # Write a file to read
      :ok = WorkspaceManager.write_file(task_id, ws_name, "test.txt", "hello world")
      assert {:ok, "hello world"} = WorkspaceManager.read_file(task_id, ws_name, "test.txt")
    end

    test "read_file/3 returns error for non-existent file", %{task_id: task_id, workspace_name: ws_name} do
      assert {:error, :file_not_found} = WorkspaceManager.read_file(task_id, ws_name, "nonexistent.txt")
    end

    test "write_file/4 writes file content", %{task_id: task_id, workspace_name: ws_name} do
      assert :ok = WorkspaceManager.write_file(task_id, ws_name, "output.txt", "content")
      assert {:ok, "content"} = WorkspaceManager.read_file(task_id, ws_name, "output.txt")
    end

    test "write_file/4 creates parent directories", %{task_id: task_id, workspace_name: ws_name} do
      assert :ok = WorkspaceManager.write_file(task_id, ws_name, "nested/dir/file.txt", "nested content")
      assert {:ok, "nested content"} = WorkspaceManager.read_file(task_id, ws_name, "nested/dir/file.txt")
    end

    test "list_files/2 returns file tree", %{task_id: task_id, workspace_name: ws_name} do
      # Create test file structure
      :ok = WorkspaceManager.write_file(task_id, ws_name, "root.txt", "root")
      :ok = WorkspaceManager.write_file(task_id, ws_name, "work/file1.txt", "file1")
      :ok = WorkspaceManager.write_file(task_id, ws_name, "output/subdir/file2.txt", "file2")

      {:ok, tree} = WorkspaceManager.list_files(task_id, ws_name)

      assert tree["root.txt"] == :file
      assert is_map(tree["work"])
      assert tree["work"]["file1.txt"] == :file
      assert is_map(tree["output"])
      assert is_map(tree["output"]["subdir"])
      assert tree["output"]["subdir"]["file2.txt"] == :file
    end
  end

  describe "path validation" do
    setup %{tmp_dir: tmp_dir} do
      original_config = Application.get_env(:ipa, :workspace_base_path)
      Application.put_env(:ipa, :workspace_base_path, tmp_dir)

      on_exit(fn ->
        if original_config do
          Application.put_env(:ipa, :workspace_base_path, original_config)
        else
          Application.delete_env(:ipa, :workspace_base_path)
        end
      end)

      task_id = "task-#{:rand.uniform(100_000)}"
      workspace_name = "ws-test"

      {:ok, _} = WorkspaceManager.create_base_workspace(task_id)
      {:ok, _} = WorkspaceManager.create_sub_workspace(task_id, workspace_name)

      %{task_id: task_id, workspace_name: workspace_name}
    end

    test "rejects path traversal with ..", %{task_id: task_id, workspace_name: ws_name} do
      assert {:error, :path_traversal_attempt} =
        WorkspaceManager.read_file(task_id, ws_name, "../../../etc/passwd")
    end

    test "rejects absolute paths", %{task_id: task_id, workspace_name: ws_name} do
      assert {:error, :absolute_path_not_allowed} =
        WorkspaceManager.read_file(task_id, ws_name, "/etc/passwd")
    end

    test "rejects paths with null bytes", %{task_id: task_id, workspace_name: ws_name} do
      assert {:error, :invalid_path_null_byte} =
        WorkspaceManager.read_file(task_id, ws_name, "file\0.txt")
    end

    test "rejects paths exceeding max length", %{task_id: task_id, workspace_name: ws_name} do
      long_path = String.duplicate("a", 5000)
      assert {:error, :path_too_long} =
        WorkspaceManager.read_file(task_id, ws_name, long_path)
    end
  end
end
