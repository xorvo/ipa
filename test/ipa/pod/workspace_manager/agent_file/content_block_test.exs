defmodule Ipa.Pod.WorkspaceManager.AgentFile.ContentBlockTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.WorkspaceManager.AgentFile.ContentBlock

  describe "available_blocks/0" do
    test "returns list of block IDs" do
      blocks = ContentBlock.available_blocks()
      assert is_list(blocks)
      assert :workspace_rules in blocks
      assert :project_context in blocks
      assert :task_context in blocks
      assert :workstream_context in blocks
      assert :code_guidelines in blocks
      assert :testing_guidelines in blocks
      assert :git_workflow in blocks
    end
  end

  describe "get_block/1" do
    test "returns content for workspace_rules" do
      content = ContentBlock.get_block(:workspace_rules)
      assert is_binary(content)
      assert String.contains?(content, "Workspace Rules")
      assert String.contains?(content, "{{workspace_path}}")
      assert String.contains?(content, "NEVER write to `/tmp/`")
      assert String.contains?(content, "CRITICAL")
    end

    test "returns content for project_context" do
      content = ContentBlock.get_block(:project_context)
      assert is_binary(content)
      assert String.contains?(content, "IPA Project Context")
      assert String.contains?(content, "Elixir")
      assert String.contains?(content, "Phoenix")
    end

    test "returns content for task_context with placeholders" do
      content = ContentBlock.get_block(:task_context)
      assert String.contains?(content, "{{task_id}}")
      assert String.contains?(content, "{{task_title}}")
      assert String.contains?(content, "{{task_spec}}")
    end

    test "returns content for workstream_context with placeholders" do
      content = ContentBlock.get_block(:workstream_context)
      assert String.contains?(content, "{{workstream_id}}")
      assert String.contains?(content, "{{workstream_title}}")
      assert String.contains?(content, "{{workstream_spec}}")
      assert String.contains?(content, "{{workstream_dependencies}}")
    end

    test "returns content for code_guidelines" do
      content = ContentBlock.get_block(:code_guidelines)
      assert String.contains?(content, "Code Guidelines")
      assert String.contains?(content, "pattern matching")
    end

    test "returns content for testing_guidelines" do
      content = ContentBlock.get_block(:testing_guidelines)
      assert String.contains?(content, "Testing Guidelines")
      assert String.contains?(content, "mix test")
    end

    test "returns content for git_workflow" do
      content = ContentBlock.get_block(:git_workflow)
      assert String.contains?(content, "Git Workflow")
      assert String.contains?(content, "Branch Naming")
    end

    test "returns empty string for unknown block" do
      assert ContentBlock.get_block(:unknown_block) == ""
    end
  end

  describe "compose/2" do
    test "concatenates multiple blocks with separators" do
      content = ContentBlock.compose([:project_context, :code_guidelines])
      assert String.contains?(content, "IPA Project Context")
      assert String.contains?(content, "Code Guidelines")
      assert String.contains?(content, "---")
    end

    test "interpolates variables into content" do
      content = ContentBlock.compose([:task_context], %{
        task_id: "task-123",
        task_title: "My Task",
        task_spec: "Build something awesome"
      })

      assert String.contains?(content, "task-123")
      assert String.contains?(content, "My Task")
      assert String.contains?(content, "Build something awesome")
      refute String.contains?(content, "{{task_id}}")
      refute String.contains?(content, "{{task_title}}")
      refute String.contains?(content, "{{task_spec}}")
    end

    test "handles nil values by using N/A" do
      content = ContentBlock.compose([:task_context], %{
        task_id: "task-123",
        task_title: nil,
        task_spec: nil
      })

      assert String.contains?(content, "task-123")
      assert String.contains?(content, "N/A")
    end

    test "formats list values as comma-separated" do
      content = ContentBlock.compose([:workstream_context], %{
        workstream_id: "ws-1",
        workstream_title: "Setup",
        workstream_spec: "Setup the project",
        workstream_dependencies: ["ws-0", "ws-prep"]
      })

      assert String.contains?(content, "ws-0, ws-prep")
    end

    test "skips unknown blocks" do
      content = ContentBlock.compose([:project_context, :unknown, :code_guidelines])
      assert String.contains?(content, "IPA Project Context")
      assert String.contains?(content, "Code Guidelines")
      # Should only have one separator between the two valid blocks
    end
  end

  describe "compose_for_base_workspace/1" do
    test "includes workspace_rules, project_context, task_context, and code_guidelines" do
      content = ContentBlock.compose_for_base_workspace(%{
        task_id: "task-abc",
        task_title: "Base Task",
        task_spec: "Do the thing",
        workspace_path: "/workspaces/task-abc"
      })

      assert String.contains?(content, "Workspace Rules")
      assert String.contains?(content, "/workspaces/task-abc")
      assert String.contains?(content, "NEVER write to `/tmp/`")
      assert String.contains?(content, "IPA Project Context")
      assert String.contains?(content, "Task Context")
      assert String.contains?(content, "Code Guidelines")
      assert String.contains?(content, "task-abc")
      assert String.contains?(content, "Base Task")
    end
  end

  describe "compose_for_sub_workspace/1" do
    test "includes all relevant blocks for workstream context" do
      content = ContentBlock.compose_for_sub_workspace(%{
        task_id: "task-xyz",
        task_title: "Parent Task",
        task_spec: "Parent spec",
        workstream_id: "ws-1",
        workstream_title: "Sub Work",
        workstream_spec: "Sub spec",
        workstream_dependencies: [],
        workspace_path: "/workspaces/task-xyz/sub-workspaces/ws-1"
      })

      assert String.contains?(content, "Workspace Rules")
      assert String.contains?(content, "/workspaces/task-xyz/sub-workspaces/ws-1")
      assert String.contains?(content, "NEVER write to `/tmp/`")
      assert String.contains?(content, "IPA Project Context")
      assert String.contains?(content, "Task Context")
      assert String.contains?(content, "Workstream Context")
      assert String.contains?(content, "Code Guidelines")
      assert String.contains?(content, "Git Workflow")
      assert String.contains?(content, "task-xyz")
      assert String.contains?(content, "ws-1")
      assert String.contains?(content, "Sub Work")
    end
  end
end
