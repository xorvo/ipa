defmodule Ipa.Pod.Commands.AgentCommandsTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.Commands.AgentCommands
  alias Ipa.Pod.Events.{AgentStarted, AgentCompleted, AgentFailed}

  describe "start_agent/2" do
    test "creates AgentStarted event" do
      state = %State{
        task_id: "task-123",
        agents: []
      }

      params = %{
        agent_id: "agent-1",
        agent_type: :workstream,
        workstream_id: "ws-1",
        workspace_path: "/workspace/task-123/ws-1"
      }

      assert {:ok, [event]} = AgentCommands.start_agent(state, params)
      assert %AgentStarted{} = event
      assert event.agent_id == "agent-1"
      assert event.agent_type == :workstream
      assert event.workstream_id == "ws-1"
      assert event.workspace_path == "/workspace/task-123/ws-1"
    end

    test "generates agent_id if not provided" do
      state = %State{task_id: "task-123", agents: []}

      params = %{agent_type: :planning}

      assert {:ok, [event]} = AgentCommands.start_agent(state, params)
      assert is_binary(event.agent_id)
    end

    test "accepts string agent_type" do
      state = %State{task_id: "task-123", agents: []}

      params = %{agent_type: "workstream"}

      assert {:ok, [event]} = AgentCommands.start_agent(state, params)
      assert event.agent_type == :workstream
    end

    test "fails with invalid agent_type" do
      state = %State{task_id: "task-123", agents: []}

      params = %{agent_type: :invalid}

      assert {:error, :invalid_agent_type} = AgentCommands.start_agent(state, params)
    end
  end

  describe "complete_agent/3" do
    test "creates AgentCompleted event" do
      state = %State{
        task_id: "task-123",
        agents: [
          %State.Agent{agent_id: "agent-1", status: :running}
        ]
      }

      assert {:ok, [event]} =
               AgentCommands.complete_agent(state, "agent-1", "Task completed successfully")

      assert %AgentCompleted{} = event
      assert event.agent_id == "agent-1"
      assert event.result_summary == "Task completed successfully"
    end

    test "allows nil result_summary" do
      state = %State{
        task_id: "task-123",
        agents: [
          %State.Agent{agent_id: "agent-1", status: :running}
        ]
      }

      assert {:ok, [event]} = AgentCommands.complete_agent(state, "agent-1")
      assert %AgentCompleted{} = event
      assert event.result_summary == nil
    end

    test "fails if agent not found" do
      state = %State{task_id: "task-123", agents: []}

      assert {:error, :agent_not_found} =
               AgentCommands.complete_agent(state, "nonexistent")
    end

    test "fails if agent not running" do
      state = %State{
        task_id: "task-123",
        agents: [
          %State.Agent{agent_id: "agent-1", status: :completed}
        ]
      }

      assert {:error, :agent_not_running} =
               AgentCommands.complete_agent(state, "agent-1")
    end
  end

  describe "fail_agent/3" do
    test "creates AgentFailed event" do
      state = %State{
        task_id: "task-123",
        agents: [
          %State.Agent{agent_id: "agent-1", status: :running}
        ]
      }

      assert {:ok, [event]} =
               AgentCommands.fail_agent(state, "agent-1", "Out of memory")

      assert %AgentFailed{} = event
      assert event.agent_id == "agent-1"
      assert event.error == "Out of memory"
    end

    test "fails if agent not found" do
      state = %State{task_id: "task-123", agents: []}

      assert {:error, :agent_not_found} =
               AgentCommands.fail_agent(state, "nonexistent", "error")
    end

    test "fails if agent not running" do
      state = %State{
        task_id: "task-123",
        agents: [
          %State.Agent{agent_id: "agent-1", status: :failed}
        ]
      }

      assert {:error, :agent_not_running} =
               AgentCommands.fail_agent(state, "agent-1", "error")
    end
  end
end
