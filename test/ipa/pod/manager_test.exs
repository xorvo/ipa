defmodule Ipa.Pod.ManagerTest do
  @moduledoc """
  Tests for the Ipa.Pod.Manager module.

  These tests focus on verifying correct context building for agents,
  particularly the workstream context structure.
  """

  use ExUnit.Case, async: true

  alias Ipa.Agent.Types.Workstream

  describe "workstream agent context" do
    test "Workstream.generate_prompt/1 receives proper context structure from manager" do
      # This context structure matches what manager.ex builds in execute_action/2
      # when starting a workstream agent (see manager.ex lines 349-374)
      context = %{
        task_id: "task-123",
        workstream_id: "ws-1",
        workstream: %{
          workstream_id: "ws-1",
          title: "Implement Authentication",
          spec: "Build JWT-based authentication system with refresh tokens",
          dependencies: ["ws-0"]
        },
        task: %{
          task_id: "task-123",
          title: "Build User Management System",
          spec: %{description: "Full user management with auth"}
        }
      }

      prompt = Workstream.generate_prompt(context)

      # Verify the spec is properly included (not "No spec provided")
      assert prompt =~ "Build JWT-based authentication system"
      refute prompt =~ "No spec provided"

      # Verify workstream ID is included
      assert prompt =~ "ws-1"

      # Verify dependencies are mentioned
      assert prompt =~ "ws-0"

      # Verify task title is included
      assert prompt =~ "Build User Management System"
    end

    test "Workstream.generate_prompt/1 handles missing nested workstream gracefully" do
      # Test with old/incorrect context structure (flat workstream_spec)
      # This was the bug: manager was using %{workstream_spec: ws.spec}
      # instead of %{workstream: %{spec: ws.spec}}
      context = %{
        task_id: "task-123",
        workstream_id: "ws-1",
        workstream_spec: "This should NOT work",
        task: %{title: "Main Task"}
      }

      prompt = Workstream.generate_prompt(context)

      # Should show "No spec provided" because workstream: %{spec: ...} is missing
      assert prompt =~ "No spec provided"
    end

    test "Workstream.generate_prompt/1 extracts title from task context" do
      context = %{
        task_id: "task-123",
        workstream_id: "ws-1",
        workstream: %{
          workstream_id: "ws-1",
          spec: "Do something",
          dependencies: []
        },
        task: %{
          title: "My Custom Task Title"
        }
      }

      prompt = Workstream.generate_prompt(context)

      assert prompt =~ "My Custom Task Title"
    end

    test "Workstream.generate_prompt/1 shows 'start immediately' for empty dependencies" do
      context = %{
        task_id: "task-123",
        workstream_id: "ws-1",
        workstream: %{
          workstream_id: "ws-1",
          spec: "First workstream",
          dependencies: []
        },
        task: %{title: "Main Task"}
      }

      prompt = Workstream.generate_prompt(context)

      assert prompt =~ "start immediately"
    end

    test "Workstream.generate_prompt/1 shows dependencies when present" do
      context = %{
        task_id: "task-123",
        workstream_id: "ws-3",
        workstream: %{
          workstream_id: "ws-3",
          spec: "Final integration",
          dependencies: ["ws-1", "ws-2"]
        },
        task: %{title: "Main Task"}
      }

      prompt = Workstream.generate_prompt(context)

      assert prompt =~ "ws-1"
      assert prompt =~ "ws-2"
      assert prompt =~ "dependencies are complete"
    end
  end

  describe "context structure validation" do
    test "context must have nested workstream map with spec key" do
      # Correct structure
      correct_context = %{
        workstream: %{spec: "Do the work"},
        task: %{title: "Task"}
      }

      prompt = Workstream.generate_prompt(correct_context)
      assert prompt =~ "Do the work"
      refute prompt =~ "No spec provided"
    end

    test "flat workstream_spec key is not recognized" do
      # Wrong structure (what the old code was doing)
      wrong_context = %{
        workstream_spec: "Do the work",
        task: %{title: "Task"}
      }

      prompt = Workstream.generate_prompt(wrong_context)
      # Spec should NOT be found
      assert prompt =~ "No spec provided"
    end
  end
end
